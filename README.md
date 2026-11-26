# IPAedit

An iOS file explorer and editor for `.ipa` files. You can open an IPA, browse and edit everything inside it, then rebuild it into a new IPA.

## Features
- **Open IPAs** with the + button, from the Files app ("Open in IPAedit"), or from the Share sheet. Each IPA is unpacked into its own workspace.
- **File browser**: browse folders, `.app` bundles, Frameworks and PlugIns. You can create, rename, duplicate, delete, import (replacing files with the same name) and share files, and set Unix permissions.
- **Viewers and editors** (switch with the icon at the top right):
  - Text editor with Find & Replace, JSON pretty-print, UTF-8, UTF-16 and Latin-1 support
  - Hex editor: overwrites bytes in place, go to offset, find hex or text, handles very large binaries
  - Plist editor: binary and XML plists, a tree editor (add, delete, reorder, change type), raw XML editing, choice of save format
  - Image viewer with zoom, and image replacement from Photos or Files (re-encoded to the original format)
  - Mach-O info: architectures, minimum OS and SDK, linked libraries, rpaths, segments, encryption (cryptid), entitlements
  - Strings dump for any binary
  - Assets.car browser: view every image rendition and export them all as PNGs (read-only)
  - Provisioning profile viewer, media player, PDF viewer, and Quick Look for everything else
- **Quick app edits**: display name, bundle ID, version, build, minimum iOS, Files-app sharing, removal of device restrictions
- **Search** across the workspace by file name or by contents
- **Build IPA**: repacks the workspace with Unix permissions and symlinks preserved. Output goes to `Exports/` and the Share sheet.

Edited apps lose their original signature. Re-sign them when installing (LiveContainer, Sideloadly, AltStore and similar tools do this).

## Build
GitHub Actions (`.github/workflows/build.yml`) builds the app on every push and uploads an unsigned `IPAedit.ipa` as a workflow artifact.

To build locally on a Mac:
```
brew install xcodegen
xcodegen generate
open IPAedit.xcodeproj
```

Requires iOS 16 or later. The app has no third-party dependencies: it uses its own ZIP reader and writer, with deflate from Apple's Compression framework.
