# Tunory app icon

The owner supplied the neon T/waveform/orbit artwork on 2026-10-21 for both
macOS and iOS. The original file is preserved byte-for-byte at
`Design/AppIcon/Tunory-source.png` (1254 × 1254, opaque PNG).
Its SHA-256 is
`d618eba53662c0502d5e78d306cfbeec4e80b116b91595518ef593269f5117e9`.

## Platform assets

`Tunory/Assets.xcassets/AppIcon.appiconset` is the shared app icon catalog.
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set in both Debug and Release.
The filesystem-synchronized Tunory group includes the catalog as a resource.

- iOS uses `AppIcon-iOS.png`, a 1024 × 1024 opaque square. The supplied white
  surround and baked tile corners were replaced with an extension of the dark
  background so iOS can apply its own mask. The T, waveform, orbit and palette
  remain the design. Xcode generates the required iPhone/iPad representations
  from the universal iOS entry.
- macOS uses the rounded tile with a transparent exterior. Only the outer
  presentation background/shadow was removed. The catalog provides 16, 32, 128,
  256 and 512 point entries at 1× and 2×, with a 1024 pixel largest image.

Background treatments were prepared with the image-editing tool from the supplied
image. Asset sizes were then produced with macOS `sips`; the iOS asset has no
alpha channel and the macOS assets preserve transparency. The largest platform
images in the catalog are the final raster masters. Do not substitute a generic
music symbol or silently overwrite the preserved owner-supplied original.

## Acceptance and proof

This slice changes branding resources and the app-icon build setting. It preserves
bundle identity `com.raelldottin.tunory`, display name `Tunory`, signing,
deployment targets, app logic and music/library behavior. The repository had no
tracked asset catalog or app-icon setting before this change.

Validation on Xcode 27.1:

- `PASS`: all 11 catalog entries have their required pixel dimensions; the iOS
  source is opaque; the original supplied artwork is preserved exactly.
- `PASS`: macOS Debug build, built identity and icon metadata, and strict app
  signature verification. The built bundle contains `AppIcon.icns` and
  `CFBundleIconName = AppIcon`.
- `PASS`: unsigned iOS Simulator Debug build. Its generated iPhone/iPad
  `CFBundleIcons` entries name `AppIcon`, and compiled icon PNGs are present.
- `PASS`: visual inspection of the compiled macOS icon extracted from the ICNS
  and the compiled iOS icon PNG, in addition to the prepared platform artwork.
- `NOT ATTEMPTED`: physical-device/home-screen or installed Finder/Dock icon
  cache verification, App Store Connect processing and TestFlight distribution.
  Source/build proof does not establish those observations.

Build commands, run from the repository root with task-owned output directories:

```bash
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/tunory-app-icon-validation/macos build

xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/tunory-app-icon-validation/ios-simulator \
  CODE_SIGNING_ALLOWED=NO build
```

The earlier [macOS TestFlight archive](releases/macos-internal-testflight-2026-10-21.md)
at source `64c8d95` predates this icon. Its evidence remains historical; use a new
archive/export from the integrated icon revision for any subsequent upload.
