# ThumbnailCacheBuilder

A lightweight Windows PowerShell 5.1+ tool to warm the **Windows Explorer thumbnail cache** for supported image, video, audio-cover and document formats. No installer or admin rights are required.

ThumbnailCacheBuilder asks Windows' registered thumbnail providers to produce previews. It does **not** install codecs, repair broken providers, change file associations or modify source files.

## Quick start

Keep `Build-ThumbnailCache.ps1` and `ThumbnailWorker.ps1` in the same directory, then run:

```powershell
powershell.exe -NoProfile -File ".\Build-ThumbnailCache.ps1"
```

or from PowerShell:

```powershell
& ".\Build-ThumbnailCache.ps1"
```

By default the tool scans all fixed local drives (`DriveType=3`), prints detected drive paths, processes matching files sequentially and writes `ThumbnailScan.csv` next to the script.

## Extension selection

The scan list is built from three sources:

1. a built-in media/image/audio candidate list;
2. explicit document candidates: `pdf`, `doc`, `docx`, `xls`, `xlsx`, `ppt`, `pptx`;
3. additional extensions detected from registered Windows shell thumbnail handlers (`IThumbnailProvider` and legacy `IExtractImage`).

Use `-ShowDetectedExtensions` to display detected handler types. Use `-SkipExtensionDiscovery` to use only the built-in and document lists.

### Example startup output

The exact counts depend on the Windows installation:

```text
Thumbnail handler discovery: 2,03 s
ThumbnailCacheBuilder 1.1
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
Request timeout: 15 s
```

## Thumbnail request strategy

Thumbnail extraction runs in a separate `ThumbnailWorker.ps1` process. The worker tries these Windows Shell paths in order:

1. `IShellItemImageFactory`
2. `IThumbnailCache`
3. `IShellItem::BindToHandler` + `IThumbnailProvider`
4. `IShellItem::BindToHandler` + legacy `IExtractImage`

The method that succeeds is written to the console and CSV log.

## Hang protection

Some video codecs and shell extensions can hang indefinitely on a damaged or unusual file. Version 1.1 isolates thumbnail work in a restartable worker process.

The default timeout is 15 seconds per file:

```powershell
.\Build-ThumbnailCache.ps1 -RequestTimeoutSeconds 15
```

If a provider stops responding, the worker is terminated, the file is logged as a timeout and scanning continues with a fresh worker:

```text
[Timeout] D:\Videos\problem.mp4 (WorkerTimeout, TIMEOUT)
```

Set `-RequestTimeoutSeconds 0` to disable the timeout.

## Examples

```powershell
# Automatically scan all fixed local drives
.\Build-ThumbnailCache.ps1

# Test one directory
.\Build-ThumbnailCache.ps1 -Paths 'C:\Temp'

# Show dynamically detected thumbnail extensions
.\Build-ThumbnailCache.ps1 -Paths 'C:\Temp' -ShowDetectedExtensions

# Skip dynamic registry discovery
.\Build-ThumbnailCache.ps1 -SkipExtensionDiscovery

# Use a shorter timeout for problematic media collections
.\Build-ThumbnailCache.ps1 -Paths 'D:\Videos' -RequestTimeoutSeconds 8

# Force thumbnail generation rather than checking the cache first
.\Build-ThumbnailCache.ps1 -ForceRefresh -Size 512

# Tune throttling
.\Build-ThumbnailCache.ps1 -DelayMs 200 -BatchSize 50 -BatchPauseMs 10000 -DrivePauseMs 60000

# Include otherwise skipped system/program directories
.\Build-ThumbnailCache.ps1 -IncludeSystemFolders
```

## Statistics and logging

After each drive the script prints processed, cached, requested, failed, timeout and skipped-directory counts. At the end it displays per-drive and overall totals.

The CSV log contains one line per processed file with:

```text
File,Status,Method,HRESULT
```

Typical statuses are `Cached`, `Requested`, `Failed` and `Timeout`.

## Memory and performance

- Drives are processed sequentially.
- Files are enumerated lazily; a full file tree is not loaded into memory.
- CSV output is written incrementally.
- Dynamic extension discovery uses direct .NET registry access for speed.
- Thumbnail work is isolated from the main scanner process.
- A hung provider can no longer block the complete scan when the request timeout is enabled.
- Reparse points are skipped to avoid directory loops.

## Limitations

- Thumbnail support ultimately depends on the Windows shell providers installed on the machine.
- A registered provider may still fail for a particular format or file.
- On the current test system some legacy `.doc` files return `0x8004B200` (`WTS_E_FAILEDEXTRACTION`).
- On the current test system the PowerToys PDF thumbnail path can return `0x80040154` (`REGDB_E_CLASSNOTREG`) in programmatic extraction even when Explorer can display PDF thumbnails.
- Windows may evict its thumbnail cache at any time.
- Large full-disk scans can still take hours. Stop with Ctrl+C.
- Run the tool in the interactive account whose Explorer thumbnail cache should be warmed.

## Roadmap

- Further PDF and legacy Office handler compatibility
- Optional GUI for Windows
- Signed and reproducible release builds

## License

GPL-3.0-or-later; see `LICENSE`.
