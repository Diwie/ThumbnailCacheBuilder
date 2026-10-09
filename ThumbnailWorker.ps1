#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'

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

  public static class WorkerNative {
    const uint WTS_INCACHEONLY = 1;
    const uint IEIFLAG_ASPECT = 4;
    const uint IEIFLAG_SCREEN = 0x20;
    const uint IEIFLAG_QUALITY = 0x200;

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
      IntPtr raw = IntPtr.Zero, bitmap = IntPtr.Zero;
      try {
        Guid itemIid = typeof(IWorkerShellItem).GUID;
        int hr = SHCreateShellItem(path, IntPtr.Zero, ref itemIid, out item);
        if (hr < 0) return hr;
        Guid bhid = BHID_ThumbnailHandler;
        Guid extractIid = typeof(IWorkerExtractImage).GUID;
        hr = item.BindToHandler(IntPtr.Zero, ref bhid, ref extractIid, out raw);
        if (hr < 0 || raw == IntPtr.Zero) return hr < 0 ? hr : unchecked((int)0x80004005);
        extractor = (IWorkerExtractImage)Marshal.GetTypedObjectForIUnknown(raw, typeof(IWorkerExtractImage));
        WorkerNativeSize s = new WorkerNativeSize { Width = size, Height = size };
        uint priority;
        uint flags = IEIFLAG_ASPECT | IEIFLAG_SCREEN | IEIFLAG_QUALITY;
        StringBuilder location = new StringBuilder(32768);
        hr = extractor.GetLocation(location, (uint)location.Capacity, out priority, ref s, 32, ref flags);
        if (hr < 0) return hr;
        return extractor.Extract(out bitmap);
      } catch (COMException ex) { return ex.ErrorCode; }
        catch { return unchecked((int)0x80004005); }
      finally {
        if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        if (extractor != null) Marshal.ReleaseComObject(extractor);
        if (raw != IntPtr.Zero) Marshal.Release(raw);
        if (item != null) Marshal.ReleaseComObject(item);
      }
    }
  }
}
'@
}

function Invoke-ThumbnailRequest {
    param([string]$File, [int]$Size, [bool]$ForceRefresh)

    $hr = -1
    $method = 'ImageFactory'
    $status = 'Failed'

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

    return @{ status='Failed'; method='AllMethods'; hr=$hr }
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
