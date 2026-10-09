# ThumbnailCacheBuilder

A lightweight Windows PowerShell 5.1+ tool to warm the **Windows Explorer thumbnail cache** for supported image, video, audio-cover and document formats. No installer, admin rights or third-party dependencies are required.

The tool asks Windows' registered thumbnail providers (such as Windows Photo Thumbnail Provider or Icaros) to produce previews. **It does not install codecs, fix broken providers, change registry associations, modify media files, or guarantee thumbnails for every listed extension.**

## Quick start

Download `Build-ThumbnailCache.ps1`, then run in Windows PowerShell (in the signed-in user's session):

```powershell
powershell.exe -NoProfile -File "C:\steve\bat\Build-ThumbnailCache.ps1"
```

If your machine's execution policy blocks local scripts, review the script first and use a one-time process-scoped override if appropriate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\steve\bat\Build-ThumbnailCache.ps1"
```

**Default (no `-Paths` argument):** scans all fixed local drives (DriveType=3), prints detected drive paths before scanning, shows each processed file and status in the console, prints per-drive and overall statistics, and writes results continuously to `ThumbnailScan.csv` next to the script. Uses 256px thumbnails, scans drives sequentially with cooldown pauses, and skips Windows/program directories and directory junctions/symlinks. Network drives and removable USB media are not automatically included.

## Examples

```powershell
# No path argument: automatically scan all fixed local drives
.\Build-ThumbnailCache.ps1

# Test just one folder
.\Build-ThumbnailCache.ps1 -Paths 'C:\Temp'

# Scan selected drives and write a streaming CSV log
.\Build-ThumbnailCache.ps1 -Paths 'D:\','E:\' -LogFile 'C:\Temp\ThumbnailScan.csv'

# Force re-request rather than checking for a cached thumbnail first
.\Build-ThumbnailCache.ps1 -ForceRefresh -Size 512

# More conservative pauses for large drives
.\Build-ThumbnailCache.ps1 -DelayMs 200 -BatchSize 50 -BatchPauseMs 10000 -DrivePauseMs 60000

# Include otherwise skipped system/program directories
.\Build-ThumbnailCache.ps1 -IncludeSystemFolders
```

## Statistics

After each drive the script prints its processed, cached, requested, failed and skipped-directory counts. At the end it displays a per-drive summary table and overall totals, plus elapsed time. These counters use constant memory per drive rather than retaining individual file results. The CSV contains individual file statuses.

## Memory and performance

- Processes drives strictly one at a time, waiting 30 seconds between drives by default.
- Throttles requests: 75 ms per file plus 3 seconds per 100 matching files; tune with `-DelayMs`, `-BatchSize`, `-BatchPauseMs`, `-DrivePauseMs`. This reduces load but cannot enforce a memory limit on third-party providers.
- Iterates files lazily and uses an explicit directory stack instead of recursively loading a full file tree.
- Writes CSV **incrementally** by default and displays the same status in the console. `-LogFile` overrides the default log location. No per-file results are retained in RAM.
- Releases native HBITMAP and COM references after every request.
- A cache-only lookup is attempted first unless `-ForceRefresh` is specified.
- The directory stack can still grow for very wide trees; Explorer/thumbnail providers may consume memory outside this script.
- Some codecs or shell extensions may hang or crash independently of the script; test on a small directory first.

## Limitations

- A successful COM call indicates Windows returned a thumbnail bitmap; it does not prove Explorer will keep it permanently in cache.
- Cache-only requests are best-effort and may miss valid thumbnails at different requested sizes.
- Windows can evict the cache at any time.
- The extension list is a *candidate filter*, not a guarantee that every format has a working thumbnail provider.
- This script does not follow directory reparse points, to avoid loops.
- Large full-disk scans can take hours and produce disk/CPU load. Stop with Ctrl+C.
- Only use on Windows in an interactive user session. Run from the account whose Explorer thumbnail cache should be warmed.

## Roadmap

- Optional GUI for Windows
- Signed and reproducible release builds

## License

GPL-3.0-only; see `LICENSE`.

### Default log path

If `-LogFile` is omitted, the CSV log is written alongside `Build-ThumbnailCache.ps1`. The path is resolved after parameter binding, avoiding empty `$PSScriptRoot` errors.
