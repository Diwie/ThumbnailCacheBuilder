#Requires -Version 5.1
<#
.SYNOPSIS
  Warms the Windows Explorer thumbnail cache using registered shell providers.
.DESCRIPTION
  Scans fixed local disks by default, requests missing thumbnails and streams
  CSV results to disk while displaying each result in the console.

  Thumbnail extraction is performed in a separate worker process. If a shell
  extension or codec hangs, the worker is terminated after the configured
  timeout and the scan continues with the next file.
.EXAMPLE
  .\Build-ThumbnailCache.ps1
.EXAMPLE
  .\Build-ThumbnailCache.ps1 -Paths 'C:\Temp' -ForceRefresh -Verbose
#>
[CmdletBinding()]
param(
    [string[]] $Paths,
    [ValidateSet(64,128,256,512,1024)] [int] $Size = 256,
    [string] $LogFile = '',
    [switch] $ForceRefresh,
    [switch] $IncludeSystemFolders,
    [switch] $ShowDetectedExtensions,
    [switch] $SkipExtensionDiscovery,
    [ValidateRange(0,3600)] [int] $RequestTimeoutSeconds = 15,
    [int] $ProgressEvery = 250,
    [ValidateRange(0,60000)] [int] $DelayMs = 75,
    [ValidateRange(0,1000000)] [int] $BatchSize = 100,
    [ValidateRange(0,600000)] [int] $BatchPauseMs = 3000,
    [ValidateRange(0,600000)] [int] $DrivePauseMs = 30000
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.1'

$scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).ProviderPath
}

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $scriptDirectory 'ThumbnailScan.csv'
}

$workerScript = Join-Path $scriptDirectory 'ThumbnailWorker.ps1'
if (-not (Test-Path -LiteralPath $workerScript)) {
    throw "Thumbnail worker not found: $workerScript"
}

$extensionText = @'
264;265;3g2;3gp;3gp2;3gpp;ai;aiff;amv;ape;asf;avi;av1;avif;bik;bmp;cb7;cbr;cbz;dds;divx;dpg;dv;dvr-ms;eps;epub;evo;exr;f4v;flac;flv;gif;h264;h265;hdmov;hdr;heic;heif;hevc;hif;jpg;k3g;m1v;m2p;m2t;m2ts;m2v;m4a;m4b;m4p;m4v;mk3d;mka;mkv;mod;mov;mp2;mp2v;mp3;mp4;mp4v;mpc;mpe;mpeg;mpg;mpv2;mpv4;mqv;mts;mxf;nsv;odp;ods;odt;ofr;ofs;ogg;ogm;ogv;opus;png;psd;psxprj;px;qt;ram;rm;rmm;rmvb;skm;spx;svg;swf;tak;tga;tif;tiff;tp;tpr;trp;ts;tta;vob;wav;webm;webp;wm;wmv;wtv;wv;xvid
'@
$documentExtensionText = 'pdf;doc;docx;xls;xlsx;ppt;pptx'
$problemExtensionText = 'indd'
$thumbnailIID = '{E357FCCD-A995-4576-B01F-234630154E96}'
$extractIID   = '{BB2E617C-0920-11D1-9A0B-00C04FC2D6C1}'

function Test-FastRegisteredShellHandler {
    param([Microsoft.Win32.RegistryKey]$Root,[string]$Path,[hashtable]$ClsidCache)
    $handlerKey = $null
    try {
        $handlerKey = $Root.OpenSubKey($Path)
        if ($null -eq $handlerKey) { return $false }
        $clsid = [string]$handlerKey.GetValue($null)
        if ([string]::IsNullOrWhiteSpace($clsid)) { return $false }
        if ($ClsidCache.ContainsKey($clsid)) { return [bool]$ClsidCache[$clsid] }
        $clsidKey = $null
        try {
            $clsidKey = $Root.OpenSubKey('CLSID\' + $clsid)
            $registered = ($null -ne $clsidKey)
            $ClsidCache[$clsid] = $registered
            return $registered
        } finally { if ($null -ne $clsidKey) { $clsidKey.Dispose() } }
    } catch { return $false }
    finally { if ($null -ne $handlerKey) { $handlerKey.Dispose() } }
}

function Get-RegisteredThumbnailExtensions {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $root = [Microsoft.Win32.Registry]::ClassesRoot
    $clsidCache = @{}
    $progIdCache = @{}

    foreach ($ext in $root.GetSubKeyNames()) {
        if ([string]::IsNullOrWhiteSpace($ext) -or -not $ext.StartsWith('.') -or $ext.Length -lt 2) { continue }
        $hasHandler = $false
        foreach ($iid in @($thumbnailIID,$extractIID)) {
            if (Test-FastRegisteredShellHandler $root ($ext+'\shellex\'+$iid) $clsidCache) { $hasHandler=$true; break }
        }

        $progId=''
        if (-not $hasHandler) {
            $extKey=$null
            try { $extKey=$root.OpenSubKey($ext); if ($null -ne $extKey) { $progId=[string]$extKey.GetValue($null) } }
            catch { $progId='' }
            finally { if ($null -ne $extKey) { $extKey.Dispose() } }
            if (-not [string]::IsNullOrWhiteSpace($progId)) {
                if ($progIdCache.ContainsKey($progId)) { $hasHandler=[bool]$progIdCache[$progId] }
                else {
                    $progIdHasHandler=$false
                    foreach ($iid in @($thumbnailIID,$extractIID)) {
                        if (Test-FastRegisteredShellHandler $root ($progId+'\shellex\'+$iid) $clsidCache) { $progIdHasHandler=$true; break }
                    }
                    $progIdCache[$progId]=$progIdHasHandler
                    $hasHandler=$progIdHasHandler
                }
            }
        }

        if (-not $hasHandler) {
            foreach ($iid in @($thumbnailIID,$extractIID)) {
                if (Test-FastRegisteredShellHandler $root ('SystemFileAssociations\'+$ext+'\shellex\'+$iid) $clsidCache) { $hasHandler=$true; break }
            }
        }
        if ($hasHandler) { [void]$found.Add($ext.ToLowerInvariant()) }
    }

    $watch.Stop()
    Write-Host ('Thumbnail handler discovery: {0:n2} s' -f $watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    return @($found | Sort-Object)
}

$staticExtensions = @($extensionText.Trim().Split(';') | ForEach-Object { '.' + $_.Trim().ToLowerInvariant() })
$documentExtensions = @($documentExtensionText.Split(';') | ForEach-Object { '.' + $_.Trim().ToLowerInvariant() })
$problemExtensions = @($problemExtensionText.Split(';') | ForEach-Object { '.' + $_.Trim().ToLowerInvariant() })
$detectedExtensions = if ($SkipExtensionDiscovery) { @() } else { @(Get-RegisteredThumbnailExtensions) }

$allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($ext in @($staticExtensions + $documentExtensions + $detectedExtensions)) {
    if (-not [string]::IsNullOrWhiteSpace($ext)) { [void]$allowed.Add($ext) }
}
$problemSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $problemExtensions) {
    if (-not [string]::IsNullOrWhiteSpace($ext)) {
        [void]$problemSet.Add($ext)
        [void]$allowed.Remove($ext)
    }
}
$staticSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($ext in @($staticExtensions + $documentExtensions)) { [void]$staticSet.Add($ext) }
$detectedAdditional = @($detectedExtensions | Where-Object { -not $staticSet.Contains($_) -and -not $problemSet.Contains($_) })

Write-Host ('ThumbnailCacheBuilder {0}' -f $ScriptVersion) -ForegroundColor Cyan
Write-Host 'Extension sources:' -ForegroundColor Cyan
Write-Host ('  Built-in media candidates : {0}' -f $staticExtensions.Count)
Write-Host ('  PDF/Office candidates     : {0}' -f $documentExtensions.Count)
Write-Host ('  Registered handler types  : {0}' -f $detectedExtensions.Count)
Write-Host ('  Newly discovered types    : {0}' -f $detectedAdditional.Count)
Write-Host ('  Problem types excluded    : {0} ({1})' -f $problemExtensions.Count,($problemExtensions -join ';'))
Write-Host ('  Total unique scan types   : {0}' -f $allowed.Count)
if ($SkipExtensionDiscovery) { Write-Host '  Dynamic discovery         : skipped' -ForegroundColor DarkYellow }
if ($ShowDetectedExtensions) {
    Write-Host 'Registered thumbnail-capable extensions:' -ForegroundColor Cyan
    if ($detectedExtensions.Count -gt 0) { Write-Host ('  ' + ($detectedExtensions -join ';')) } else { Write-Host '  (none detected)' }
    Write-Host 'Additional extensions not in the built-in/document lists:' -ForegroundColor Cyan
    if ($detectedAdditional.Count -gt 0) { Write-Host ('  ' + ($detectedAdditional -join ';')) } else { Write-Host '  (none)' }
}

if (-not $PSBoundParameters.ContainsKey('Paths')) {
    $Paths = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' })
}
if (-not $Paths -or $Paths.Count -eq 0) { throw 'No scan paths found.' }
Write-Host 'Detected scan locations:' -ForegroundColor Cyan
foreach ($scanPath in $Paths) { Write-Host ('  ' + $scanPath) }
Write-Host ('CSV log: ' + [IO.Path]::GetFullPath($LogFile))
Write-Host ('Request timeout: {0}' -f $(if($RequestTimeoutSeconds -eq 0){'disabled'}else{"$RequestTimeoutSeconds s"}))
Write-Host ('Throttle: {0} ms/file, {1} ms per {2} files, {3} ms between drives' -f $DelayMs,$BatchPauseMs,$BatchSize,$DrivePauseMs)

$worker = $null

function Stop-ThumbnailWorker {
    if ($null -eq $script:worker) { return }
    try {
        if (-not $script:worker.HasExited) { $script:worker.Kill() }
    } catch {}
    try { $script:worker.Dispose() } catch {}
    $script:worker = $null
}

function Start-ThumbnailWorker {
    Stop-ThumbnailWorker
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $workerScript
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:worker = New-Object Diagnostics.Process
    $script:worker.StartInfo = $psi
    if (-not $script:worker.Start()) { throw 'Could not start thumbnail worker.' }
}

function Invoke-WorkerRequest {
    param([string]$File)

    if ($null -eq $script:worker -or $script:worker.HasExited) { Start-ThumbnailWorker }

    $id = [guid]::NewGuid().ToString('N')
    $payload = @{ id=$id; file=$File; size=$Size; forceRefresh=[bool]$ForceRefresh } | ConvertTo-Json -Compress
    try {
        $script:worker.StandardInput.WriteLine($payload)
        $script:worker.StandardInput.Flush()

        $task = $script:worker.StandardOutput.ReadLineAsync()
        if ($RequestTimeoutSeconds -gt 0) {
            $completed = $task.Wait($RequestTimeoutSeconds * 1000)
            if (-not $completed) {
                Stop-ThumbnailWorker
                return [pscustomobject]@{ status='Timeout'; method='WorkerTimeout'; hr=0; message=("No response within {0} s" -f $RequestTimeoutSeconds) }
            }
        } else {
            $task.Wait()
        }

        $line = $task.Result
        if ([string]::IsNullOrWhiteSpace($line)) {
            $stderr = ''
            try { $stderr = $script:worker.StandardError.ReadToEnd() } catch {}
            Stop-ThumbnailWorker
            return [pscustomobject]@{ status='Failed'; method='WorkerExited'; hr=[int]0x80004005; message=$stderr }
        }

        $result = $line | ConvertFrom-Json
        if ([string]$result.id -ne $id) {
            Stop-ThumbnailWorker
            return [pscustomobject]@{ status='Failed'; method='WorkerProtocol'; hr=[int]0x80004005; message='Unexpected worker response.' }
        }
        return $result
    } catch {
        $message = $_.Exception.Message
        Stop-ThumbnailWorker
        return [pscustomobject]@{ status='Failed'; method='WorkerError'; hr=[int]0x80004005; message=$message }
    }
}

$writer = $null
$fullLog = [IO.Path]::GetFullPath($LogFile)
$logDir = [IO.Path]::GetDirectoryName($fullLog)
if (-not [IO.Directory]::Exists($logDir)) { [IO.Directory]::CreateDirectory($logDir) | Out-Null }
$writer = New-Object IO.StreamWriter($fullLog,$false,(New-Object Text.UTF8Encoding($true)))
$writer.WriteLine('"File","Status","Method","HRESULT"')

function Write-Result([string]$file,[string]$status,[int]$hr,[string]$method) {
    $hrText = if ($status -eq 'Timeout') { 'TIMEOUT' } else { '0x' + ([uint32]([int64]$hr -band 0xFFFFFFFFL)).ToString('X8') }
    Write-Host ('[{0}] {1} ({2}, {3})' -f @($status,$file,$method,$hrText))
    $escapedFile=$file.Replace('"','""')
    $writer.WriteLine(('"{0}","{1}","{2}","{3}"' -f @($escapedFile,$status,$method,$hrText)))
}

$excluded=@()
if(-not $IncludeSystemFolders){
    foreach($p in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:LOCALAPPDATA)){
        if($p){$excluded+=([IO.Path]::GetFullPath($p).TrimEnd('\')+'\')}
    }
}

$processed=0;$cached=0;$requested=0;$failed=0;$timeouts=0;$skippedDirs=0
$driveStatistics=New-Object 'System.Collections.Generic.List[object]'
$watch=[Diagnostics.Stopwatch]::StartNew()

try {
    Start-ThumbnailWorker
    for($driveIndex=0;$driveIndex -lt $Paths.Count;$driveIndex++){
        $root=$Paths[$driveIndex]
        if($driveIndex -gt 0 -and $DrivePauseMs -gt 0){
            Write-Host ('Waiting {0} seconds before next drive...' -f ($DrivePauseMs/1000)) -ForegroundColor Yellow
            Start-Sleep -Milliseconds $DrivePauseMs
        }
        Write-Host ('Starting location {0}/{1}: {2}' -f ($driveIndex+1),$Paths.Count,$root) -ForegroundColor Cyan
        $driveProcessed=0;$driveCached=0;$driveRequested=0;$driveFailed=0;$driveTimeouts=0;$driveSkipped=0
        $driveWatch=[Diagnostics.Stopwatch]::StartNew()
        if(-not [IO.Directory]::Exists($root)){Write-Warning "Path not found: $root";$driveWatch.Stop();continue}

        $stack=New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push([IO.Path]::GetFullPath($root))
        while($stack.Count -gt 0){
            $directory=$stack.Pop();$directoryPrefix=$directory.TrimEnd('\')+'\';$skip=$false
            foreach($prefix in $excluded){if($directoryPrefix.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$skip=$true;break}}
            if($skip){$skippedDirs++;$driveSkipped++;continue}

            try{$files=[IO.Directory]::EnumerateFiles($directory)}catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Cannot enumerate files in $directory : $_";$files=@()}
            foreach($file in $files){
                if(-not $allowed.Contains([IO.Path]::GetExtension($file))){continue}
                $processed++;$driveProcessed++
                $result = Invoke-WorkerRequest -File $file
                $hr = [int]$result.hr
                switch ([string]$result.status) {
                    'Cached'    { $cached++;$driveCached++ }
                    'Requested' { $requested++;$driveRequested++ }
                    'Timeout'   { $timeouts++;$driveTimeouts++ }
                    default     { $failed++;$driveFailed++ }
                }
                Write-Result $file ([string]$result.status) $hr ([string]$result.method)
                if($DelayMs -gt 0){Start-Sleep -Milliseconds $DelayMs}
                if($BatchSize -gt 0 -and $driveProcessed % $BatchSize -eq 0 -and $BatchPauseMs -gt 0){
                    $writer.Flush();Write-Host ('Cooldown: {0} seconds after {1} files on {2}' -f ($BatchPauseMs/1000),$driveProcessed,$root) -ForegroundColor DarkYellow
                    Start-Sleep -Milliseconds $BatchPauseMs
                }
                if($ProgressEvery -gt 0 -and $processed % $ProgressEvery -eq 0){
                    Write-Progress -Activity 'Building Windows thumbnail cache' -Status "$processed scanned | $cached cached | $requested requested | $failed failed | $timeouts timeout"
                    $writer.Flush()
                }
            }

            try{$subdirs=[IO.Directory]::EnumerateDirectories($directory)}catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Cannot enumerate subdirectories in $directory : $_";$subdirs=@()}
            foreach($subdir in $subdirs){
                try{$attributes=[IO.File]::GetAttributes($subdir);if(-not($attributes -band [IO.FileAttributes]::ReparsePoint)){$stack.Push($subdir)}}
                catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Skipping $subdir : $_"}
            }
        }

        $driveWatch.Stop()
        $driveStatistics.Add([pscustomobject]@{
            Location=$root;Files=$driveProcessed;Cached=$driveCached;Requested=$driveRequested;Failed=$driveFailed;Timeouts=$driveTimeouts;SkippedDirectories=$driveSkipped;Minutes=[math]::Round($driveWatch.Elapsed.TotalMinutes,1)
        })
        Write-Host ('Completed location: {0} | files: {1} | cached: {2} | requested: {3} | failed: {4} | timeout: {5} | skipped dirs: {6}' -f @($root,$driveProcessed,$driveCached,$driveRequested,$driveFailed,$driveTimeouts,$driveSkipped)) -ForegroundColor Green
        $writer.Flush()
    }
} finally {
    Stop-ThumbnailWorker
    if($writer){$writer.Dispose()}
    $watch.Stop()
    Write-Progress -Activity 'Building Windows thumbnail cache' -Completed
}

Write-Host "`n=== Per-drive statistics ===" -ForegroundColor Cyan
$driveStatistics|Format-Table -AutoSize|Out-Host
Write-Host "`n=== Overall statistics ===" -ForegroundColor Cyan
Write-Host "Scanned: $processed | Cached: $cached | Requested: $requested | Failed: $failed | Timeout: $timeouts | Skipped directories: $skippedDirs"
Write-Host ('Duration: {0:n1} minutes' -f $watch.Elapsed.TotalMinutes)
Write-Host "CSV log: $([IO.Path]::GetFullPath($LogFile))"