#Requires -Version 5.1
<#
.SYNOPSIS
  Warms the Windows Explorer thumbnail cache using registered shell providers.
.DESCRIPTION
  Scans fixed local disks by default, requests missing thumbnails and streams
  CSV results to disk while displaying each result in the console. Does not modify source files or shell associations.
.EXAMPLE
  .\Build-ThumbnailCache.ps1
.EXAMPLE
  .\Build-ThumbnailCache.ps1 -Paths 'D:\Fotos','E:\Videos' -Size 256 -LogFile 'C:\Temp\thumbnails.csv'
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
    [int] $ProgressEvery = 250,
    [ValidateRange(0,60000)] [int] $DelayMs = 75,
    [ValidateRange(0,1000000)] [int] $BatchSize = 100,
    [ValidateRange(0,600000)] [int] $BatchPauseMs = 3000,
    [ValidateRange(0,600000)] [int] $DrivePauseMs = 30000
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Resolve the default log path after parameter binding; $PSScriptRoot can be
# empty during evaluation of parameter default expressions.
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Split-Path -Parent $PSCommandPath
    } else {
        (Get-Location).ProviderPath
    }
    $LogFile = Join-Path $scriptDirectory 'ThumbnailScan.csv'
}

# Includes the original extension list plus Apple/web/HEVC additions.
$extensionText = @'
264;265;3g2;3gp;3gp2;3gpp;ai;aiff;amv;ape;asf;avi;av1;avif;bik;bmp;cb7;cbr;cbz;dds;divx;dpg;dv;dvr-ms;eps;epub;evo;exr;f4v;flac;flv;gif;h264;h265;hdmov;hdr;heic;heif;hevc;hif;indd;jpg;k3g;m1v;m2p;m2t;m2ts;m2v;m4a;m4b;m4p;m4v;mk3d;mka;mkv;mod;mov;mp2;mp2v;mp3;mp4;mp4v;mpc;mpe;mpeg;mpg;mpv2;mpv4;mqv;mts;mxf;nsv;odp;ods;odt;ofr;ofs;ogg;ogm;ogv;opus;png;psd;psxprj;px;qt;ram;rm;rmm;rmvb;skm;spx;svg;swf;tak;tga;tif;tiff;tp;tpr;trp;ts;tta;vob;wav;webm;webp;wm;wmv;wtv;wv;xvid
'@
$allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $extensionText.Trim().Split(';')) { [void]$allowed.Add('.' + $ext) }

if (-not $PSBoundParameters.ContainsKey('Paths')) {
    $Paths = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' })
}
if (-not $Paths -or $Paths.Count -eq 0) { throw 'No scan paths found.' }
Write-Host 'Detected scan locations:' -ForegroundColor Cyan
foreach ($scanPath in $Paths) { Write-Host ('  ' + $scanPath) }
Write-Host ('CSV log: ' + [IO.Path]::GetFullPath($LogFile))
Write-Host ('Throttle: {0} ms/file, {1} ms per {2} files, {3} ms between drives' -f $DelayMs, $BatchPauseMs, $BatchSize, $DrivePauseMs)

# In a fresh Windows PowerShell process this type is compiled once.
if (-not ('ThumbnailCacheBuilder.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ThumbnailCacheBuilder {
  [StructLayout(LayoutKind.Sequential)] public struct NativeSize { public int Width; public int Height; }
  [ComImport, Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IShellItemImageFactory {
    [PreserveSig] int GetImage(NativeSize size, int flags, out IntPtr bitmap);
  }
  public static class Native {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr ctx, ref Guid iid,
      [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
    // THUMBNAILONLY=0x8, INCACHEONLY=0x10. Do not accept icon fallback.
    public static int Request(string path, int size, bool cacheOnly) {
      IShellItemImageFactory factory = null;
      IntPtr bitmap = IntPtr.Zero;
      try {
        Guid iid = typeof(IShellItemImageFactory).GUID;
        SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory);
        NativeSize requested = new NativeSize { Width=size, Height=size };
        return factory.GetImage(requested, cacheOnly ? 0x18 : 0x8, out bitmap);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch (Exception) { return unchecked((int)0x80004005); }
      finally {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        if (factory != null) Marshal.ReleaseComObject(factory);
      }
    }
  }
}
'@
}

# Stream CSV directly to disk, without keeping an in-memory results array.
$writer = $null
if ($LogFile) {
    $fullLog = [IO.Path]::GetFullPath($LogFile)
    $logDir = [IO.Path]::GetDirectoryName($fullLog)
    if (-not [IO.Directory]::Exists($logDir)) { [IO.Directory]::CreateDirectory($logDir) | Out-Null }
    $writer = New-Object IO.StreamWriter($fullLog, $false, (New-Object Text.UTF8Encoding($true)))
    $writer.WriteLine('"File","Status","HRESULT"')
}
function Write-Result([string]$file, [string]$status, [int]$hr) {
    $hrText = '0x{0:X8}' -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))
    Write-Host ('[{0}] {1} ({2})' -f $status, $file, $hrText)
    if ($null -eq $writer) { return }
    $escapedFile = $file.Replace('"','""')
    $csvLine = '"{0}","{1}","{2}"' -f @($escapedFile, $status, $hrText)
    $writer.WriteLine($csvLine)
}

$excluded = @()
if (-not $IncludeSystemFolders) {
    foreach ($p in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA)) {
        if ($p) { $excluded += ([IO.Path]::GetFullPath($p).TrimEnd('\') + '\') }
    }
}
$processed = 0; $cached = 0; $requested = 0; $failed = 0; $skippedDirs = 0
$driveStatistics = New-Object 'System.Collections.Generic.List[object]'
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    for ($driveIndex = 0; $driveIndex -lt $Paths.Count; $driveIndex++) {
        $root = $Paths[$driveIndex]
        if ($driveIndex -gt 0 -and $DrivePauseMs -gt 0) {
            Write-Host ('Waiting {0} seconds before next drive...' -f ($DrivePauseMs / 1000)) -ForegroundColor Yellow
            Start-Sleep -Milliseconds $DrivePauseMs
        }
        Write-Host ('Starting location {0}/{1}: {2}' -f ($driveIndex + 1), $Paths.Count, $root) -ForegroundColor Cyan
        $driveProcessed = 0; $driveCached = 0; $driveRequested = 0; $driveFailed = 0; $driveSkipped = 0
        $driveWatch = [Diagnostics.Stopwatch]::StartNew()
        if (-not [IO.Directory]::Exists($root)) { Write-Warning "Path not found: $root"; $driveWatch.Stop(); continue }
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push([IO.Path]::GetFullPath($root))
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            $directoryPrefix = $directory.TrimEnd('\') + '\'
            $skip = $false
            foreach ($prefix in $excluded) {
                if ($directoryPrefix.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { $skippedDirs++; $driveSkipped++; continue }
            try {
                # Directory enumeration is lazy, avoiding Get-ChildItem -Recurse allocations.
                foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                    if (-not $allowed.Contains([IO.Path]::GetExtension($file))) { continue }
                    $processed++
                    $driveProcessed++
                    $hr = -1
                    if (-not $ForceRefresh) {
                        $hr = [ThumbnailCacheBuilder.Native]::Request($file, $Size, $true)
                    }
                    if ($hr -eq 0) {
                        $cached++; $driveCached++; Write-Result $file 'Cached' $hr
                    } else {
                        $hr = [ThumbnailCacheBuilder.Native]::Request($file, $Size, $false)
                        if ($hr -eq 0) { $requested++; $driveRequested++; Write-Result $file 'Requested' $hr }
                        else { $failed++; $driveFailed++; Write-Result $file 'Failed' $hr; Write-Verbose "Failed 0x$('{0:X8}' -f ([uint32]([int64]$hr -band 0xFFFFFFFFL))): $file" }
                    }
                    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
                    if ($BatchSize -gt 0 -and $driveProcessed % $BatchSize -eq 0 -and $BatchPauseMs -gt 0) {
                        if ($writer) { $writer.Flush() }
                        Write-Host ('Cooldown: {0} seconds after {1} files on {2}' -f ($BatchPauseMs / 1000), $driveProcessed, $root) -ForegroundColor DarkYellow
                        Start-Sleep -Milliseconds $BatchPauseMs
                    }
                    if ($ProgressEvery -gt 0 -and $processed % $ProgressEvery -eq 0) {
                        Write-Progress -Activity 'Building Windows thumbnail cache' -Status "$processed scanned | $cached cached | $requested requested | $failed failed"
                        if ($writer) { $writer.Flush() }
                    }
                }
                foreach ($subdir in [IO.Directory]::EnumerateDirectories($directory)) {
                    try {
                        $attributes = [IO.File]::GetAttributes($subdir)
                        if (-not ($attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($subdir) }
                    } catch { $skippedDirs++; $driveSkipped++; Write-Verbose "Skipping $subdir : $_" }
                }
            } catch {
                $skippedDirs++; $driveSkipped++
                Write-Verbose "Cannot enumerate $directory : $_"
            }
        }
        $driveWatch.Stop()
        $driveStatistics.Add([pscustomobject]@{
            Location = $root; Files = $driveProcessed; Cached = $driveCached
            Requested = $driveRequested; Failed = $driveFailed
            SkippedDirectories = $driveSkipped
            Minutes = [math]::Round($driveWatch.Elapsed.TotalMinutes, 1)
        })
        Write-Host ('Completed location: {0} | files: {1} | cached: {2} | requested: {3} | failed: {4} | skipped dirs: {5}' -f @($root, $driveProcessed, $driveCached, $driveRequested, $driveFailed, $driveSkipped)) -ForegroundColor Green
        if ($writer) { $writer.Flush() }
    }
} finally {
    if ($writer) { $writer.Dispose() }
    $watch.Stop()
    Write-Progress -Activity 'Building Windows thumbnail cache' -Completed
}
Write-Host '
=== Per-drive statistics ===' -ForegroundColor Cyan
$driveStatistics | Format-Table -AutoSize | Out-Host
Write-Host '
=== Overall statistics ===' -ForegroundColor Cyan
Write-Host "Scanned: $processed | Cached: $cached | Requested: $requested | Failed: $failed | Skipped directories: $skippedDirs"
Write-Host ('Duration: {0:n1} minutes' -f $watch.Elapsed.TotalMinutes)
if ($LogFile) { Write-Host "CSV log: $([IO.Path]::GetFullPath($LogFile))" }
