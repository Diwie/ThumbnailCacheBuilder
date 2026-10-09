# Changelog

All notable changes to this project will be documented in this file.

## [1.1] - 2026-10-09

### Added

- Fast dynamic discovery of registered thumbnail-capable file extensions using direct .NET registry access.
- Extension selection now combines the built-in media list, explicit PDF/Office candidates and dynamically detected shell-handler extensions.
- Optional `-ShowDetectedExtensions` and `-SkipExtensionDiscovery` switches.
- Startup statistics for discovery time, extension sources and detected scan locations.
- Windows `IThumbnailCache` fallback after `IShellItemImageFactory` fails.
- Direct Shell handler fallbacks through `BindToHandler`, `IThumbnailProvider` and legacy `IExtractImage`.
- Separate `ThumbnailWorker.ps1` process for thumbnail extraction.
- Configurable per-file timeout through `-RequestTimeoutSeconds` (15 seconds by default).
- Automatic worker termination/restart after a provider or codec timeout so scanning can continue.
- Explicit `Timeout` status in console output, CSV logging and statistics.
- Method information in console/CSV output to make thumbnail-path diagnostics easier.

### Changed

- Thumbnail providers now run outside the main scanner process so a hanging media handler cannot block the complete scan indefinitely.
- Improved per-file error isolation so a failed thumbnail request does not abort the remainder of a directory.
- Fixed PowerShell 5.1 formatting expressions that could trigger `System.Object[]` / `op_Addition` errors.
- Expanded document candidates with PDF and Microsoft Office formats.

### Known issues

- Some document shell handlers work in Explorer but still reject programmatic extraction. On the current test system `.doc` can return `0x8004B200` (`WTS_E_FAILEDEXTRACTION`) and PDF can return `0x80040154` (`REGDB_E_CLASSNOTREG`) even though Explorer thumbnails are available.
- Thumbnail support ultimately depends on the installed shell provider and the activation context Windows allows for that provider.

## [1.0] - 2026-10-09

### Added

- Automatic detection of all fixed local Windows drives when `-Paths` is omitted.
- Sequential drive processing with configurable cooldown between drives.
- Configurable per-file and per-batch throttling for large disks.
- RAM-conscious lazy directory traversal without loading a complete file tree.
- Windows Explorer thumbnail generation through `IShellItemImageFactory`.
- Cache-only lookup before requesting a new thumbnail.
- Console output and incremental CSV logging at the same time.
- Per-drive and overall statistics for cached, requested, failed and skipped items.
- Broad media/document extension candidate list including HEIC/HEIF, AVIF, WebP, WebM, HEVC/H.265 and Apple video formats.
- Protection against directory reparse-point loops.
- Optional `-ForceRefresh` and `-IncludeSystemFolders` switches.

### Notes

- The script uses thumbnail providers already registered in Windows; it does not install codecs or change shell associations.
- Tested successfully on Windows with existing image and video thumbnail providers.
