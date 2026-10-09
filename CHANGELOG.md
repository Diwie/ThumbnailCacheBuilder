# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-10-09

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
