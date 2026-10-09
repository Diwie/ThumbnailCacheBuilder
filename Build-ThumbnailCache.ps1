#Requires -Version 5.1
<#
.SYNOPSIS
  Warms the Windows Explorer thumbnail cache using registered shell providers.
.DESCRIPTION
  Scans fixed local disks by default, requests missing thumbnails and streams
  CSV results to disk while displaying each result in the console. The scan
  extension set combines a built-in media list, PDF/Office formats and file
  extensions discovered from registered Windows thumbnail handlers.

  The normal path uses IShellItemImageFactory. If that path fails, the script
  falls back to the shared Windows IThumbnailCache API. As a final document
  fallback it asks IShellItem::BindToHandler for the registered thumbnail
  handler and tries IThumbnailProvider, then legacy IExtractImage.
.EXAMPLE
  .\Build-ThumbnailCache.ps1
.EXAMPLE
  .\Build-ThumbnailCache.ps1 -Paths 'D:\Fotos','E:\Videos' -Size 256 -LogFile 'C:\Temp\thumbnails.csv'
.EXAMPLE
  .\Build-ThumbnailCache.ps1 -Paths 'C:\Temp' -ForceRefresh -Verbose
.EXAMPLE
  .\Build-ThumbnailCache.ps1 -Paths 'C:\Temp' -ShowDetectedExtensions
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
    [int] $ProgressEvery = 250,
    [ValidateRange(0,60000)] [int] $DelayMs = 75,
    [ValidateRange(0,1000000)] [int] $BatchSize = 100,
    [ValidateRange(0,600000)] [int] $BatchPauseMs = 3000,
    [ValidateRange(0,600000)] [int] $DrivePauseMs = 30000
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

$extensionText = @'
264;265;3g2;3gp;3gp2;3gpp;ai;aiff;amv;ape;asf;avi;av1;avif;bik;bmp;cb7;cbr;cbz;dds;divx;dpg;dv;dvr-ms;eps;epub;evo;exr;f4v;flac;flv;gif;h264;h265;hdmov;hdr;heic;heif;hevc;hif;indd;jpg;k3g;m1v;m2p;m2t;m2ts;m2v;m4a;m4b;m4p;m4v;mk3d;mka;mkv;mod;mov;mp2;mp2v;mp3;mp4;mp4v;mpc;mpe;mpeg;mpg;mpv2;mpv4;mqv;mts;mxf;nsv;odp;ods;odt;ofr;ofs;ogg;ogm;ogv;opus;png;psd;psxprj;px;qt;ram;rm;rmm;rmvb;skm;spx;svg;swf;tak;tga;tif;tiff;tp;tpr;trp;ts;tta;vob;wav;webm;webp;wm;wmv;wtv;wv;xvid
'@
$documentExtensionText = 'pdf;doc;docx;xls;xlsx;ppt;pptx'
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
                    $progIdCache[$progId]=$progIdHasHandler; $hasHandler=$progIdHasHandler
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

$staticExtensions=@($extensionText.Trim().Split(';')|ForEach-Object{'.'+$_.Trim().ToLowerInvariant()})
$documentExtensions=@($documentExtensionText.Split(';')|ForEach-Object{'.'+$_.Trim().ToLowerInvariant()})
$detectedExtensions=if($SkipExtensionDiscovery){@()}else{@(Get-RegisteredThumbnailExtensions)}
$allowed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($ext in @($staticExtensions+$documentExtensions+$detectedExtensions)){if(-not [string]::IsNullOrWhiteSpace($ext)){[void]$allowed.Add($ext)}}
$staticSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($ext in @($staticExtensions+$documentExtensions)){[void]$staticSet.Add($ext)}
$detectedAdditional=@($detectedExtensions|Where-Object{-not $staticSet.Contains($_)})

Write-Host 'Extension sources:' -ForegroundColor Cyan
Write-Host ('  Built-in media candidates : {0}' -f $staticExtensions.Count)
Write-Host ('  PDF/Office candidates     : {0}' -f $documentExtensions.Count)
Write-Host ('  Registered handler types  : {0}' -f $detectedExtensions.Count)
Write-Host ('  Newly discovered types    : {0}' -f $detectedAdditional.Count)
Write-Host ('  Total unique scan types   : {0}' -f $allowed.Count)
if($SkipExtensionDiscovery){Write-Host '  Dynamic discovery         : skipped' -ForegroundColor DarkYellow}
if($ShowDetectedExtensions){
    Write-Host 'Registered thumbnail-capable extensions:' -ForegroundColor Cyan
    if($detectedExtensions.Count -gt 0){Write-Host ('  '+($detectedExtensions -join ';'))}else{Write-Host '  (none detected)'}
    Write-Host 'Additional extensions not in the built-in/document lists:' -ForegroundColor Cyan
    if($detectedAdditional.Count -gt 0){Write-Host ('  '+($detectedAdditional -join ';'))}else{Write-Host '  (none)'}
}

if(-not $PSBoundParameters.ContainsKey('Paths')){$Paths=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|ForEach-Object{$_.DeviceID+'\'})}
if(-not $Paths -or $Paths.Count -eq 0){throw 'No scan paths found.'}
Write-Host 'Detected scan locations:' -ForegroundColor Cyan
foreach($scanPath in $Paths){Write-Host ('  '+$scanPath)}
Write-Host ('CSV log: '+[IO.Path]::GetFullPath($LogFile))
Write-Host ('Throttle: {0} ms/file, {1} ms per {2} files, {3} ms between drives' -f $DelayMs,$BatchPauseMs,$BatchSize,$DrivePauseMs)

if(-not ('ThumbnailCacheBuilder.Native' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace ThumbnailCacheBuilder {
 [StructLayout(LayoutKind.Sequential)] public struct NativeSize { public int Width; public int Height; }
 [ComImport,Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IShellItemImageFactory { [PreserveSig] int GetImage(NativeSize size,int flags,out IntPtr bitmap); }
 [ComImport,Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IShellItem { [PreserveSig] int BindToHandler(IntPtr pbc,ref Guid bhid,ref Guid riid,out IntPtr ppv); }
 [ComImport,Guid("F676C15D-596A-4CE2-8234-33996F445DB1"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IThumbnailCache { [PreserveSig] int GetThumbnail([MarshalAs(UnmanagedType.Interface)] IShellItem shellItem,uint requestedSize,uint flags,IntPtr sharedBitmap,IntPtr outFlags,IntPtr thumbnailId); }
 [ComImport,Guid("E357FCCD-A995-4576-B01F-234630154E96"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IThumbnailProvider { [PreserveSig] int GetThumbnail(uint cx,out IntPtr bitmap,out uint alphaType); }
 [ComImport,Guid("BB2E617C-0920-11D1-9A0B-00C04FC2D6C1"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IExtractImage {
   [PreserveSig] int GetLocation([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder pathBuffer,uint cch,out uint priority,ref NativeSize requestedSize,uint recColorDepth,ref uint flags);
   [PreserveSig] int Extract(out IntPtr bitmap);
 }
 public static class Native {
   const uint WTS_INCACHEONLY=1, IEIFLAG_ASPECT=4, IEIFLAG_SCREEN=0x20, IEIFLAG_QUALITY=0x200;
   static readonly Guid CLSID_LocalThumbnailCache=new Guid("50EF4544-AC9F-4A8E-B21B-8A26180DB13F");
   static readonly Guid BHID_ThumbnailHandler=new Guid("7B2E650A-8E20-4F4A-B09E-6597AFC72FB0");
   static IThumbnailCache thumbnailCache;
   [DllImport("shell32.dll",CharSet=CharSet.Unicode,PreserveSig=false,EntryPoint="SHCreateItemFromParsingName")]
   static extern void SHCreateImageFactory(string path,IntPtr ctx,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);
   [DllImport("shell32.dll",CharSet=CharSet.Unicode,PreserveSig=true,EntryPoint="SHCreateItemFromParsingName")]
   static extern int SHCreateShellItem(string path,IntPtr ctx,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IShellItem item);
   [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
   static IThumbnailCache GetThumbnailCache(){ if(thumbnailCache==null){Type t=Type.GetTypeFromCLSID(CLSID_LocalThumbnailCache,true);thumbnailCache=(IThumbnailCache)Activator.CreateInstance(t);} return thumbnailCache; }
   public static int RequestImageFactory(string path,int size,bool cacheOnly){ IShellItemImageFactory f=null;IntPtr b=IntPtr.Zero;try{Guid iid=typeof(IShellItemImageFactory).GUID;SHCreateImageFactory(path,IntPtr.Zero,ref iid,out f);NativeSize s=new NativeSize{Width=size,Height=size};return f.GetImage(s,cacheOnly?0x18:0x8,out b);}catch(COMException ex){return ex.ErrorCode;}catch{return unchecked((int)0x80004005);}finally{if(b!=IntPtr.Zero)DeleteObject(b);if(f!=null)Marshal.ReleaseComObject(f);} }
   public static int RequestThumbnailCache(string path,int size,bool cacheOnly){ IShellItem item=null;try{Guid iid=typeof(IShellItem).GUID;int hr=SHCreateShellItem(path,IntPtr.Zero,ref iid,out item);if(hr<0)return hr;return GetThumbnailCache().GetThumbnail(item,(uint)size,cacheOnly?WTS_INCACHEONLY:0,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);}catch(COMException ex){return ex.ErrorCode;}catch{return unchecked((int)0x80004005);}finally{if(item!=null)Marshal.ReleaseComObject(item);} }
   public static int RequestBoundThumbnailProvider(string path,int size){IShellItem item=null;IThumbnailProvider p=null;IntPtr raw=IntPtr.Zero,b=IntPtr.Zero;try{Guid iid=typeof(IShellItem).GUID;int hr=SHCreateShellItem(path,IntPtr.Zero,ref iid,out item);if(hr<0)return hr;Guid bh=BHID_ThumbnailHandler;Guid piid=typeof(IThumbnailProvider).GUID;hr=item.BindToHandler(IntPtr.Zero,ref bh,ref piid,out raw);if(hr<0||raw==IntPtr.Zero)return hr<0?hr:unchecked((int)0x80004005);p=(IThumbnailProvider)Marshal.GetTypedObjectForIUnknown(raw,typeof(IThumbnailProvider));uint a;return p.GetThumbnail((uint)size,out b,out a);}catch(COMException ex){return ex.ErrorCode;}catch{return unchecked((int)0x80004005);}finally{if(b!=IntPtr.Zero)DeleteObject(b);if(p!=null)Marshal.ReleaseComObject(p);if(raw!=IntPtr.Zero)Marshal.Release(raw);if(item!=null)Marshal.ReleaseComObject(item);} }
   public static int RequestBoundExtractImage(string path,int size){IShellItem item=null;IExtractImage e=null;IntPtr raw=IntPtr.Zero,b=IntPtr.Zero;try{Guid iid=typeof(IShellItem).GUID;int hr=SHCreateShellItem(path,IntPtr.Zero,ref iid,out item);if(hr<0)return hr;Guid bh=BHID_ThumbnailHandler;Guid eiid=typeof(IExtractImage).GUID;hr=item.BindToHandler(IntPtr.Zero,ref bh,ref eiid,out raw);if(hr<0||raw==IntPtr.Zero)return hr<0?hr:unchecked((int)0x80004005);e=(IExtractImage)Marshal.GetTypedObjectForIUnknown(raw,typeof(IExtractImage));NativeSize s=new NativeSize{Width=size,Height=size};uint pri;uint flags=IEIFLAG_ASPECT|IEIFLAG_SCREEN|IEIFLAG_QUALITY;StringBuilder loc=new StringBuilder(32768);hr=e.GetLocation(loc,(uint)loc.Capacity,out pri,ref s,32,ref flags);if(hr<0)return hr;return e.Extract(out b);}catch(COMException ex){return ex.ErrorCode;}catch{return unchecked((int)0x80004005);}finally{if(b!=IntPtr.Zero)DeleteObject(b);if(e!=null)Marshal.ReleaseComObject(e);if(raw!=IntPtr.Zero)Marshal.Release(raw);if(item!=null)Marshal.ReleaseComObject(item);} }
 }
}
'@
}

$writer=$null
if($LogFile){$fullLog=[IO.Path]::GetFullPath($LogFile);$logDir=[IO.Path]::GetDirectoryName($fullLog);if(-not [IO.Directory]::Exists($logDir)){[IO.Directory]::CreateDirectory($logDir)|Out-Null};$writer=New-Object IO.StreamWriter($fullLog,$false,(New-Object Text.UTF8Encoding($true)));$writer.WriteLine('"File","Status","Method","HRESULT"')}
function Write-Result([string]$file,[string]$status,[int]$hr,[string]$method){$hrText='0x'+([uint32]([int64]$hr -band 0xFFFFFFFFL)).ToString('X8');Write-Host ('[{0}] {1} ({2}, {3})' -f @($status,$file,$method,$hrText));if($null -eq $writer){return};$escapedFile=$file.Replace('"','""');$writer.WriteLine(('"{0}","{1}","{2}","{3}"' -f @($escapedFile,$status,$method,$hrText)))}

$excluded=@();if(-not $IncludeSystemFolders){foreach($p in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:LOCALAPPDATA)){if($p){$excluded+=([IO.Path]::GetFullPath($p).TrimEnd('\')+'\')}}}
$processed=0;$cached=0;$requested=0;$failed=0;$skippedDirs=0;$fallbackCached=0;$fallbackRequested=0;$boundFallbackRequested=0
$driveStatistics=New-Object 'System.Collections.Generic.List[object]';$watch=[Diagnostics.Stopwatch]::StartNew()
try{
for($driveIndex=0;$driveIndex -lt $Paths.Count;$driveIndex++){
 $root=$Paths[$driveIndex]
 if($driveIndex -gt 0 -and $DrivePauseMs -gt 0){Write-Host ('Waiting {0} seconds before next drive...' -f ($DrivePauseMs/1000)) -ForegroundColor Yellow;Start-Sleep -Milliseconds $DrivePauseMs}
 Write-Host ('Starting location {0}/{1}: {2}' -f ($driveIndex+1),$Paths.Count,$root) -ForegroundColor Cyan
 $driveProcessed=0;$driveCached=0;$driveRequested=0;$driveFailed=0;$driveSkipped=0;$driveFallbackCached=0;$driveFallbackRequested=0;$driveBoundFallbackRequested=0;$driveWatch=[Diagnostics.Stopwatch]::StartNew()
 if(-not [IO.Directory]::Exists($root)){Write-Warning "Path not found: $root";$driveWatch.Stop();continue}
 $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push([IO.Path]::GetFullPath($root))
 while($stack.Count -gt 0){
  $directory=$stack.Pop();$directoryPrefix=$directory.TrimEnd('\')+'\';$skip=$false
  foreach($prefix in $excluded){if($directoryPrefix.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$skip=$true;break}}
  if($skip){$skippedDirs++;$driveSkipped++;continue}
  try{$files=[IO.Directory]::EnumerateFiles($directory)}catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Cannot enumerate files in $directory : $_";$files=@()}
  foreach($file in $files){
   if(-not $allowed.Contains([IO.Path]::GetExtension($file))){continue}
   $processed++;$driveProcessed++
   try{
    $hr=-1;$method='ImageFactory'
    if(-not $ForceRefresh){$hr=[ThumbnailCacheBuilder.Native]::RequestImageFactory($file,$Size,$true);if($hr -ne 0){$hr=[ThumbnailCacheBuilder.Native]::RequestThumbnailCache($file,$Size,$true);if($hr -eq 0){$method='ThumbnailCache';$fallbackCached++;$driveFallbackCached++}}}
    if($hr -eq 0){$cached++;$driveCached++;Write-Result $file 'Cached' $hr $method}
    else{
      $method='ImageFactory';$hr=[ThumbnailCacheBuilder.Native]::RequestImageFactory($file,$Size,$false)
      if($hr -ne 0){$hr=[ThumbnailCacheBuilder.Native]::RequestThumbnailCache($file,$Size,$false);if($hr -eq 0){$method='ThumbnailCache';$fallbackRequested++;$driveFallbackRequested++}}
      if($hr -ne 0){$hr=[ThumbnailCacheBuilder.Native]::RequestBoundThumbnailProvider($file,$Size);if($hr -eq 0){$method='BoundThumbnailProvider';$boundFallbackRequested++;$driveBoundFallbackRequested++}}
      if($hr -ne 0){$hr=[ThumbnailCacheBuilder.Native]::RequestBoundExtractImage($file,$Size);if($hr -eq 0){$method='BoundExtractImage';$boundFallbackRequested++;$driveBoundFallbackRequested++}}
      if($hr -eq 0){$requested++;$driveRequested++;Write-Result $file 'Requested' $hr $method}else{$failed++;$driveFailed++;Write-Result $file 'Failed' $hr 'AllMethods';Write-Verbose ("Failed 0x{0}: {1}" -f @(([uint32]([int64]$hr -band 0xFFFFFFFFL)).ToString('X8'),$file))}
    }
   }catch{$failed++;$driveFailed++;Write-Warning "File processing error: $file : $_"}
   if($DelayMs -gt 0){Start-Sleep -Milliseconds $DelayMs}
   if($BatchSize -gt 0 -and $driveProcessed % $BatchSize -eq 0 -and $BatchPauseMs -gt 0){if($writer){$writer.Flush()};Write-Host ('Cooldown: {0} seconds after {1} files on {2}' -f ($BatchPauseMs/1000),$driveProcessed,$root) -ForegroundColor DarkYellow;Start-Sleep -Milliseconds $BatchPauseMs}
   if($ProgressEvery -gt 0 -and $processed % $ProgressEvery -eq 0){Write-Progress -Activity 'Building Windows thumbnail cache' -Status "$processed scanned | $cached cached | $requested requested | $failed failed";if($writer){$writer.Flush()}}
  }
  try{$subdirs=[IO.Directory]::EnumerateDirectories($directory)}catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Cannot enumerate subdirectories in $directory : $_";$subdirs=@()}
  foreach($subdir in $subdirs){try{$attributes=[IO.File]::GetAttributes($subdir);if(-not($attributes -band [IO.FileAttributes]::ReparsePoint)){$stack.Push($subdir)}}catch{$skippedDirs++;$driveSkipped++;Write-Verbose "Skipping $subdir : $_"}}
 }
 $driveWatch.Stop();$driveStatistics.Add([pscustomobject]@{Location=$root;Files=$driveProcessed;Cached=$driveCached;Requested=$driveRequested;Failed=$driveFailed;CacheFallback=($driveFallbackCached+$driveFallbackRequested);HandlerFallback=$driveBoundFallbackRequested;SkippedDirectories=$driveSkipped;Minutes=[math]::Round($driveWatch.Elapsed.TotalMinutes,1)})
 Write-Host ('Completed location: {0} | files: {1} | cached: {2} | requested: {3} | failed: {4} | cache fallback: {5} | handler fallback: {6} | skipped dirs: {7}' -f @($root,$driveProcessed,$driveCached,$driveRequested,$driveFailed,($driveFallbackCached+$driveFallbackRequested),$driveBoundFallbackRequested,$driveSkipped)) -ForegroundColor Green
 if($writer){$writer.Flush()}
}
}finally{if($writer){$writer.Dispose()};$watch.Stop();Write-Progress -Activity 'Building Windows thumbnail cache' -Completed}
Write-Host "`n=== Per-drive statistics ===" -ForegroundColor Cyan
$driveStatistics|Format-Table -AutoSize|Out-Host
Write-Host "`n=== Overall statistics ===" -ForegroundColor Cyan
Write-Host "Scanned: $processed | Cached: $cached | Requested: $requested | Failed: $failed | ThumbnailCache fallback: $($fallbackCached + $fallbackRequested) | Handler fallback: $boundFallbackRequested | Skipped directories: $skippedDirs"
Write-Host ('Duration: {0:n1} minutes' -f $watch.Elapsed.TotalMinutes)
if($LogFile){Write-Host "CSV log: $([IO.Path]::GetFullPath($LogFile))"}
