# ThumbnailCacheBuilder

A lightweight Windows PowerShell 5.1+ tool to warm the **Windows Explorer thumbnail cache** for supported image, video, audio-cover and document formats. No installer, admin rights or third-party dependencies are required.

The tool asks Windows' registered thumbnail providers (such as Windows Photo Thumbnail Provider, Office shell handlers, PowerToys PDF thumbnails or Icaros) to produce previews. **It does not install codecs, fix broken providers, change registry associations, modify media files, or guarantee thumbnails for every listed extension.**

## Quick start

Download `Build-ThumbnailCache.ps1`, then run in Windows PowerShell (in the signed-in user's session):

```powershell
powershell.exe -NoProfile -File "C:\steve\bat\ThumbnailCacheBuilder\Build-ThumbnailCache.ps1"
```

If your machine's execution policy blocks local scripts, review the script first and use a one-time process-scoped override if appropriate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\steve\bat\ThumbnailCacheBuilder\Build-ThumbnailCache.ps1"
```

**Default (no `-Paths` argument):** scans all fixed local drives (DriveType=3), prints detected drive paths before scanning, shows each processed file and status in the console, prints per-drive and overall statistics, and writes results continuously to `ThumbnailScan.csv` next to the script. Uses 256px thumbnails, scans drives sequentially with cooldown pauses, and skips Windows/program directories and directory junctions/symlinks. Network drives and removable USB media are not automatically included.

## Extension selection

The scan list is deliberately built from three sources:

1. a built-in media/image/audio candidate list, so common formats remain covered even when a third-party tool such as Icaros does not register every extension individually;
2. explicit document candidates: `pdf`, `doc`, `docx`, `xls`, `xlsx`, `ppt`, `pptx`;
3. additional extensions detected from registered Windows shell thumbnail handlers (`IThumbnailProvider` and legacy `IExtractImage`), including direct extension mappings, ProgID mappings and `SystemFileAssociations`.

These sources are merged case-insensitively and de-duplicated. A detected handler still does not guarantee that every file of that type can be rendered successfully.

Use `-ShowDetectedExtensions` to display all extensions discovered from the registry and which of them were not already in the built-in/document lists. Use `-SkipExtensionDiscovery` to skip dynamic registry discovery and use only the built-in plus PDF/Office candidates.

### Example startup output

The exact numbers depend on the installed shell extensions and file associations. A real-world startup can look like this:

```text
Thumbnail handler discovery: 2,03 s
Extension sources:
  Built-in media candidates : 112
  PDF/Office candidates     : 7
  Registered handler types  : 341
  Newly discovered types    : 222
  Total unique scan types   : 341
Detected scan locations:
  C:\
  D:\
  L:\
  P:\
  Q:\
  S:\
  W:\
```

This makes it immediately visible how much of the scan list comes from the built-in candidates versus the current Windows installation, and how quickly the handler discovery completed.

## Examples

```powershell
# No path argument: automatically scan all fixed local drives
.\Build-ThumbnailCache.ps1

# Test just one folder
.\Build-ThumbnailCache.ps1 -Paths 'C:\Temp'

# Show dynamically detected shell-thumbnail extensions
.\Build-ThumbnailCache.ps1 -Paths 'C:\Temp' -ShowDetectedExtensions

# Skip dynamic registry discovery
.\Build-ThumbnailCache.ps1 -SkipExtensionDiscovery

# Scan selected drives and write a streaming CSV log
.\Build-ThumbnailCache.ps1 -Paths 'D:\','E:\' -LogFile 'C:\Temp\ThumbnailScan.csv'

# Force re-request rather than checking for a cached thumbnail first
.\Build-ThumbnailCache.ps1 -ForceRefresh -Size 512

# More conservative pauses for large drives
.\Build-ThumbnailCache.ps1 -DelayMs 200 -BatchSize 50 -BatchPauseMs 10000 -DrivePauseMs 60000

# Include otherwise skipped system/program directories
.\Build-ThumbnailCache.ps1 -IncludeSystemFolders
```

## Thumbnail request strategy

The normal request path uses `IShellItemImageFactory`. If that route fails, ThumbnailCacheBuilder falls back to the shared Windows `IThumbnailCache` API. This gives Windows another opportunity to invoke the registered thumbnail handler and populate the Explorer cache, which is particularly useful for document formats such as PDF and Office files.

The console and CSV output show which method succeeded (`ImageFactory` or `ThumbnailCache`).

## Statistics

After each drive the script prints its processed, cached, requested, failed and skipped-directory counts. At the end it displays a per-drive summary table and overall totals, plus elapsed time. These counters use constant memory per drive rather than retaining individual file results. The CSV contains individual file statuses.

At startup it also shows extension-source statistics: built-in count, PDF/Office count, detected registered-handler count, newly discovered count and total unique scan types.

## Memory and performance

- Processes drives strictly one at a time, waiting 30 seconds between drives by default.
- Throttles requests: 75 ms per file plus 3 seconds per 100 matching files; tune with `-DelayMs`, `-BatchSize`, `-BatchPauseMs`, `-DrivePauseMs`. This reduces load but cannot enforce a memory limit on third-party providers.
- Uses direct .NET registry access for dynamic extension discovery instead of recursively walking HKCR through the slower PowerShell registry provider.
- Iterates files lazily and uses an explicit directory stack instead of recursively loading a full file tree.
- Writes CSV **incrementally** by default and displays the same status in the console. `-LogFile` overrides the default log location. No per-file results are retained in RAM.
- Releases native HBITMAP and COM references after every request.
- A cache-only lookup is attempted first unless `-ForceRefresh` is specified.
- File-processing errors are isolated so one bad thumbnail request does not abort the remainder of a directory.
- The directory stack can still grow for very wide trees; Explorer/thumbnail providers may consume memory outside this script.
- Some codecs or shell extensions may hang or crash independently of the script; test on a small directory first.

## Limitations

- The fallback still relies on the Windows Shell and the thumbnail handlers installed on the machine. A registered handler can be missing, broken or unable to render a particular file.
- A successful COM call indicates Windows returned or cached a thumbnail; it does not prove Explorer will keep it permanently in cache.
- Cache-only requests are best-effort and may miss valid thumbnails at different requested sizes.
- Windows can evict the cache at any time.
- The extension list is a *candidate filter*, not a guarantee that every format has a working thumbnail provider.
- This script does not follow directory reparse points, to avoid loops.
- Large full-disk scans can take hours and produce disk/CPU load. Stop with Ctrl+C.
- Only use on Windows in an interactive user session. Run from the account whose Explorer thumbnail cache should be warmed.

## Roadmap

- Further document-handler compatibility where `IShellItemImageFactory` and `IThumbnailCache` are both insufficient
- Optional GUI for Windows
- Signed and reproducible release builds

## License

GPL-3.0-or-later; see `LICENSE`.

### Default log path

If `-LogFile` is omitted, the CSV log is written alongside `Build-ThumbnailCache.ps1`. The path is resolved after parameter binding, avoiding empty `$PSScriptRoot` errors.
