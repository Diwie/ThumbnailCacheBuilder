#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$thumbnailProviderAssociationIid = '{E357FCCD-A995-4576-B01F-234630154E96}'
$extractImageAssociationIid = '{BB2E617C-0920-11D1-9A0B-00C04FC2D6C1}'

if (-not ('ThumbnailCacheBuilder.WorkerNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace ThumbnailCacheBuilder {
  [StructLayout(LayoutKind.Sequential)]
  public struct WorkerNativeSize { public int Width; public int Height; }

  [ComImport, Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerShellItemImageFactory {
    [PreserveSig] int GetImage(WorkerNativeSize size, int flags, out IntPtr bitmap);
  }

  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerShellItem {
    [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
  }

  [ComImport, Guid("F676C15D-596A-4CE2-8234-33996F445DB1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerThumbnailCache {
    [PreserveSig] int GetThumbnail(
      [MarshalAs(UnmanagedType.Interface)] IWorkerShellItem shellItem,
      uint requestedSize, uint flags, IntPtr sharedBitmap, IntPtr outFlags, IntPtr thumbnailId);
  }

  [ComImport, Guid("E357FCCD-A995-4576-B01F-234630154E96"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerThumbnailProvider {
    [PreserveSig] int GetThumbnail(uint cx, out IntPtr bitmap, out uint alphaType);
  }

  [ComImport, Guid("BB2E617C-0920-11D1-9A0B-00C04FC2D6C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerExtractImage {
    [PreserveSig] int GetLocation(
      [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pathBuffer,
      uint cch, out uint priority, ref WorkerNativeSize requestedSize,
      uint recColorDepth, ref uint flags);
    [PreserveSig] int Extract(out IntPtr bitmap);
  }

  [ComImport, Guid("B7D14566-0509-4CCE-A71F-0A554233BD9B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerInitializeWithFile {
    [PreserveSig] int Initialize([MarshalAs(UnmanagedType.LPWStr)] string filePath, uint mode);
  }

  [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IWorkerPersistFile {
    [PreserveSig] int GetClassID(out Guid classId);
    [PreserveSig] int IsDirty();
    [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
    [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, bool remember);
    [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
    [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
  }

  public static class WorkerNative {
    const uint WTS_INCACHEONLY = 1;
    const uint IEIFLAG_ASPECT = 4;
    const uint IEIFLAG_SCREEN = 0x20;
    const uint IEIFLAG_QUALITY = 0x200;
    const uint STGM_READ = 0;

    static readonly Guid CLSID_LocalThumbnailCache = new Guid("50EF4544-AC9F-4A8E-B21B-8A26180DB13F");
    static readonly Guid BHID_ThumbnailHandler = new Guid("7B2E650A-8E20-4F4A-B09E-6597AFC72FB0");
    static IWorkerThumbnailCache thumbnailCache;

    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false, EntryPoint="SHCreateItemFromParsingName")]
    static extern void SHCreateImageFactory(string path, IntPtr ctx, ref Guid iid,
      [MarshalAs(UnmanagedType.Interface)] out IWorkerShellItemImageFactory factory);

    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true, EntryPoint="SHCreateItemFromParsingName")]
    static extern int SHCreateShellItem(string path, IntPtr ctx, ref Guid iid,
      [MarshalAs(UnmanagedType.Interface)] out IWorkerShellItem item);

    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);

    static IWorkerThumbnailCache GetThumbnailCache() {
      if (thumbnailCache == null) {
        Type t = Type.GetTypeFromCLSID(CLSID_LocalThumbnailCache, true);
        thumbnailCache = (IWorkerThumbnailCache)Activator.CreateInstance(t);
      }
      return thumbnailCache;
    }

    public static int RequestImageFactory(string path, int size, bool cacheOnly) {
      IWorkerShellItemImageFactory f = null; IntPtr b = IntPtr.Zero;
      try {
        Guid iid = typeof(IWorkerShellItemImageFactory).GUID;
        SHCreateImageFactory(path, IntPtr.Zero, ref iid, out f);
        WorkerNativeSize s = new WorkerNativeSize { Width = size, Height = size };
        return f.GetImage(s, cacheOnly ? 0x18 : 0x8, out b);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (b != IntPtr.Zero) DeleteObject(b);
        if (f != null) Marshal.ReleaseComObject(f);
      }
    }

    public static int RequestThumbnailCache(string path, int size, bool cacheOnly) {
      IWorkerShellItem item = null;
      try {
        Guid iid = typeof(IWorkerShellItem).GUID;
        int hr = SHCreateShellItem(path, IntPtr.Zero, ref iid, out item);
        if (hr < 0) return hr;
        return GetThumbnailCache().GetThumbnail(item, (uint)size,
          cacheOnly ? WTS_INCACHEONLY : 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally { if (item != null) Marshal.ReleaseComObject(item); }
    }

    public static int RequestBoundThumbnailProvider(string path, int size) {
      IWorkerShellItem item = null; IWorkerThumbnailProvider provider = null;
      IntPtr raw = IntPtr.Zero, bitmap = IntPtr.Zero;
      try {
        Guid itemIid = typeof(IWorkerShellItem).GUID;
        int hr = SHCreateShellItem(path, IntPtr.Zero, ref itemIid, out item);
        if (hr < 0) return hr;
        Guid bhid = BHID_ThumbnailHandler;
        Guid providerIid = typeof(IWorkerThumbnailProvider).GUID;
        hr = item.BindToHandler(IntPtr.Zero, ref bhid, ref providerIid, out raw);
        if (hr < 0 || raw == IntPtr.Zero) return hr < 0 ? hr : unchecked((int)0x80004005);
        provider = (IWorkerThumbnailProvider)Marshal.GetTypedObjectForIUnknown(raw, typeof(IWorkerThumbnailProvider));
        uint alphaType;
        return provider.GetThumbnail((uint)size, out bitmap, out alphaType);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        if (provider != null) Marshal.ReleaseComObject(provider);
        if (raw != IntPtr.Zero) Marshal.Release(raw);
        if (item != null) Marshal.ReleaseComObject(item);
      }
    }

    public static int RequestBoundExtractImage(string path, int size) {
      IWorkerShellItem item = null; IWorkerExtractImage extractor = null;
      IntPtr raw = IntPtr.Zero;
      try {
        Guid itemIid = typeof(IWorkerShellItem).GUID;
        int hr = SHCreateShellItem(path, IntPtr.Zero, ref itemIid, out item);
        if (hr < 0) return hr;
        Guid bhid = BHID_ThumbnailHandler;
        Guid extractIid = typeof(IWorkerExtractImage).GUID;
        hr = item.BindToHandler(IntPtr.Zero, ref bhid, ref extractIid, out raw);
        if (hr < 0 || raw == IntPtr.Zero) return hr < 0 ? hr : unchecked((int)0x80004005);
        extractor = (IWorkerExtractImage)Marshal.GetTypedObjectForIUnknown(raw, typeof(IWorkerExtractImage));
        return ExtractLegacy(extractor, path, size);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (extractor != null) Marshal.ReleaseComObject(extractor);
        if (raw != IntPtr.Zero) Marshal.Release(raw);
        if (item != null) Marshal.ReleaseComObject(item);
      }
    }

    static int InitializeHandler(object handler, string path) {
      IWorkerInitializeWithFile initFile = handler as IWorkerInitializeWithFile;
      if (initFile != null) {
        int hr = initFile.Initialize(path, STGM_READ);
        if (hr >= 0) return hr;
      }

      IWorkerPersistFile persistFile = handler as IWorkerPersistFile;
      if (persistFile != null) {
        return persistFile.Load(path, STGM_READ);
      }

      return unchecked((int)0x80004002);
    }

    static int ExtractLegacy(IWorkerExtractImage extractor, string path, int size) {
      IntPtr bitmap = IntPtr.Zero;
      try {
        WorkerNativeSize s = new WorkerNativeSize { Width = size, Height = size };
        uint priority;
        uint flags = IEIFLAG_ASPECT | IEIFLAG_SCREEN | IEIFLAG_QUALITY;
        StringBuilder location = new StringBuilder(32768);
        int hr = extractor.GetLocation(location, (uint)location.Capacity, out priority, ref s, 32, ref flags);
        if (hr < 0) return hr;
        return extractor.Extract(out bitmap);
      } finally {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
      }
    }

    public static int RequestDirectThumbnailProvider(string path, int size, string clsidText) {
      object handler = null;
      IWorkerThumbnailProvider provider = null;
      IntPtr bitmap = IntPtr.Zero;
      try {
        Guid clsid;
        if (!Guid.TryParse(clsidText, out clsid)) return unchecked((int)0x80070057);
        Type t = Type.GetTypeFromCLSID(clsid, true);
        handler = Activator.CreateInstance(t);
        provider = handler as IWorkerThumbnailProvider;
        if (provider == null) return unchecked((int)0x80004002);

        int initHr = InitializeHandler(handler, path);
        if (initHr < 0 && initHr != unchecked((int)0x80004002)) return initHr;

        uint alphaType;
        return provider.GetThumbnail((uint)size, out bitmap, out alphaType);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        if (provider != null && Marshal.IsComObject(provider)) Marshal.ReleaseComObject(provider);
        else if (handler != null && Marshal.IsComObject(handler)) Marshal.ReleaseComObject(handler);
      }
    }

    public static int RequestDirectExtractImage(string path, int size, string clsidText) {
      object handler = null;
      IWorkerExtractImage extractor = null;
      try {
        Guid clsid;
        if (!Guid.TryParse(clsidText, out clsid)) return unchecked((int)0x80070057);
        Type t = Type.GetTypeFromCLSID(clsid, true);
        handler = Activator.CreateInstance(t);
        extractor = handler as IWorkerExtractImage;
        if (extractor == null) return unchecked((int)0x80004002);

        int initHr = InitializeHandler(handler, path);
        if (initHr < 0 && initHr != unchecked((int)0x80004002)) return initHr;

        return ExtractLegacy(extractor, path, size);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (extractor != null && Marshal.IsComObject(extractor)) Marshal.ReleaseComObject(extractor);
        else if (handler != null && Marshal.IsComObject(handler)) Marshal.ReleaseComObject(handler);
      }
    }
  }
}
'@
}

function Get-RegisteredHandlerClsid {
    param(
        [string]$File,
        [string]$AssociationIid
    )

    $ext = [IO.Path]::GetExtension($File)
    if ([string]::IsNullOrWhiteSpace($ext)) { return $null }

    $root = [Microsoft.Win32.Registry]::ClassesRoot
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $paths.Add($ext + '\shellex\' + $AssociationIid)

    $extKey = $null
    try {
        $extKey = $root.OpenSubKey($ext)
        if ($null -ne $extKey) {
            $progId = [string]$extKey.GetValue($null)
            if (-not [string]::IsNullOrWhiteSpace($progId)) {
                $paths.Add($progId + '\shellex\' + $AssociationIid)
            }
            $perceivedType = [string]$extKey.GetValue('PerceivedType')
            if (-not [string]::IsNullOrWhiteSpace($perceivedType)) {
                $paths.Add('SystemFileAssociations\' + $perceivedType + '\shellex\' + $AssociationIid)
            }
        }
    } finally {
        if ($null -ne $extKey) { $extKey.Dispose() }
    }

    $paths.Add('SystemFileAssociations\' + $ext + '\shellex\' + $AssociationIid)

    foreach ($path in $paths) {
        $key = $null
        try {
            $key = $root.OpenSubKey($path)
            if ($null -eq $key) { continue }
            $value = [string]$key.GetValue($null)
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        } finally {
            if ($null -ne $key) { $key.Dispose() }
        }
    }

    return $null
}

function Invoke-ThumbnailRequest {
    param([string]$File, [int]$Size, [bool]$ForceRefresh)

    $hr = -1
    $lastHandler = $null

    if (-not $ForceRefresh) {
        $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestImageFactory($File, $Size, $true)
        if ($hr -eq 0) { return @{ status='Cached'; method='ImageFactory'; hr=$hr } }
        $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestThumbnailCache($File, $Size, $true)
        if ($hr -eq 0) { return @{ status='Cached'; method='ThumbnailCache'; hr=$hr } }
    }

    $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestImageFactory($File, $Size, $false)
    if ($hr -eq 0) { return @{ status='Requested'; method='ImageFactory'; hr=$hr } }

    $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestThumbnailCache($File, $Size, $false)
    if ($hr -eq 0) { return @{ status='Requested'; method='ThumbnailCache'; hr=$hr } }

    $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestBoundThumbnailProvider($File, $Size)
    if ($hr -eq 0) { return @{ status='Requested'; method='BoundThumbnailProvider'; hr=$hr } }

    $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestBoundExtractImage($File, $Size)
    if ($hr -eq 0) { return @{ status='Requested'; method='BoundExtractImage'; hr=$hr } }

    $thumbnailClsid = Get-RegisteredHandlerClsid -File $File -AssociationIid $thumbnailProviderAssociationIid
    if (-not [string]::IsNullOrWhiteSpace($thumbnailClsid)) {
        $lastHandler = $thumbnailClsid
        $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestDirectThumbnailProvider($File, $Size, $thumbnailClsid)
        if ($hr -eq 0) {
            return @{ status='Requested'; method='DirectRegisteredThumbnailProvider'; hr=$hr; handler=$thumbnailClsid }
        }
    }

    $extractClsid = Get-RegisteredHandlerClsid -File $File -AssociationIid $extractImageAssociationIid
    if (-not [string]::IsNullOrWhiteSpace($extractClsid)) {
        $lastHandler = $extractClsid
        $hr = [ThumbnailCacheBuilder.WorkerNative]::RequestDirectExtractImage($File, $Size, $extractClsid)
        if ($hr -eq 0) {
            return @{ status='Requested'; method='DirectRegisteredExtractImage'; hr=$hr; handler=$extractClsid }
        }
    }

    return @{ status='Failed'; method='AllMethods'; hr=$hr; handler=$lastHandler }
}

while (($line = [Console]::In.ReadLine()) -ne $null) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $request = $line | ConvertFrom-Json
        $result = Invoke-ThumbnailRequest -File ([string]$request.file) -Size ([int]$request.size) -ForceRefresh ([bool]$request.forceRefresh)
        $result.id = [string]$request.id
        [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
    } catch {
        $errorResult = @{ id=''; status='Failed'; method='WorkerError'; hr=[int]0x80004005; message=$_.Exception.Message }
        try { $errorResult.id = [string]$request.id } catch {}
        [Console]::Out.WriteLine(($errorResult | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
    }
}
