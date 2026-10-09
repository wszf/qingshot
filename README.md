<p align="center"><img src="assets/AppIcon.png" width="128" alt="QingShot icon"></p>
<h1 align="center">QingShot · 轻截图</h1>
<p align="center">Capture. Annotate. Share. A native macOS screenshot utility.</p>
<p align="center">English · <a href="docs/README.zh-CN.md">简体中文</a> · MIT</p>

QingShot is a SwiftUI + AppKit development preview for macOS 15 and later. It combines global capture shortcuts, annotations, on-device OCR, pinned references, backgrounds and local capture history. It has no third-party package dependencies, analytics, upload service or network requests.

## Features

- Area, window and main-display captures, with a floating quick-action preview.
- Customizable global shortcuts: record a combination, detect registration conflicts, disable an action or restore defaults. Changes persist across restarts.
- Arrow, rectangle, ellipse, pen, text, numbered callout, highlight and opaque redaction tools; crop and undo/redo.
- Chinese/English OCR using Apple Vision, with editable results.
- Always-on-top image references; PNG export and clipboard copy.
- Four gradient backgrounds, adjustable padding, rounded corners and shadows.
- Last 30 original captures stored locally.
- Manual vertical image stitching with a specified overlap.
- Main-display H.264 MP4 recording at 30 fps, without audio.
- English and Simplified Chinese UI, with an in-app language selector and system-language default.

## Build

Install Xcode or a suitable Swift toolchain. The package requires macOS 15+ and Swift 5.9+. Build and run the checks without a signing certificate:

```sh
git clone https://github.com/wszf/qingshot.git
cd qingshot
./scripts/check.sh
```

To build the app bundle, quit any running QingShot and select a stable Apple Development or Developer ID certificate from your own Keychain:

```sh
security find-identity -v -p codesigning
QINGSHOT_SIGNING_IDENTITY="YOUR_CERTIFICATE_NAME_OR_SHA1" ./scripts/build.sh
open ../QingShot.app
```

You can instead save that certificate identifier in `.signing-identity`, an ignored local file. This file is not a private key. Never commit certificates, private keys or provisioning secrets. The script stages and verifies the bundle before replacing the previous build. It intentionally refuses ad-hoc signing: ad-hoc code hashes change after rebuilding and can invalidate macOS permission records.

The build script creates a bundle for the current host architecture. This project does not yet publish a notarized distribution build. Building from source is currently the recommended installation method.

## Use

| Action | Default shortcut |
| --- | --- |
| Capture area | Control + Shift + 2 |
| Capture window | Control + Shift + 3 |
| Capture main display | Control + Shift + 4 |
| Settings and language | Command + comma |
| Import / paste image | Command + O / V |
| Copy / export PNG | Command + C / S |
| Undo / redo annotation or crop | Command + Z / Shift + Command + Z |

Open **Settings & Shortcuts** in the editor or **Settings…** in the menu-bar menu. Click a shortcut button and press a combination containing Command or Control. Esc cancels recording; × disables that shortcut. Key labels use physical US keyboard positions. System-owned combinations may require manually changing macOS keyboard settings first.

Choose **System Default**, **English** or **简体中文** in Settings. The app updates immediately; macOS-owned file panels follow the OS language. Images, user-entered annotations and already generated capture names are not translated.

## Screen permission

Allow QingShot in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen it. The permission alert opens this page directly. If an older development build remains authorized but capture fails, remove only the old QingShot entry, add the current app, and enable it again. Keep using the same signing identity for later builds. No Accessibility permission is required by QingShot.

## Data and limitations

- The most recent 30 **originals** are stored in `~/Library/Application Support/QingShot/History`. Oldest files are removed automatically. Right-click an item to delete it. Export/copy your annotations before switching images; editable projects are not persisted.
- Solid redaction affects the exported/copied image. The original in history remains unredacted until you delete it.
- Image stitching is manual, in filename order, with a uniform overlap. It is not automatic scrolling capture. Result limits: 100 million pixels and 32,000 pixels tall.
- Recording captures the main display only, without microphone or system audio. Stop through the menu bar and wait for the file to finish saving.
- The canvas currently fits to the window; arbitrary zoom, moving existing annotations, video editing, cloud sharing and configurable history retention are not implemented.
- Capture has been exercised locally on Apple Silicon. Mixed-DPI multi-display capture and recording still need broader validation. Treat this as a development preview.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and [localization notes](docs/LOCALIZATION.md) for adding languages. The [icon source and design notes](assets/README.md) describe the included artwork.

Product workflow references: [CleanShot X](https://cleanshot.com/features), [Shottr](https://shottr.cc/) and [Xnapper](https://xnapper.com/). QingShot's code and artwork were created for this project; it is not affiliated with those products.

## License

[MIT](LICENSE).
