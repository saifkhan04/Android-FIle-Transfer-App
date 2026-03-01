# Android File Transfer App (macOS)

A native macOS SwiftUI app for transferring files to/from Android devices using `adb` (Android Platform Tools).

## Features

- Detect connected Android devices (`adb devices`)
- Browse remote folders on device storage
- Upload files/folders from Mac to current Android folder
- Download selected Android files/folders to a local destination
- Drag-and-drop upload and download flows in the UI
- Handles Android paths with spaces/special characters more safely

## Requirements

- macOS 13+
- Android phone with:
  - USB debugging enabled
  - Authorized debugging prompt accepted on device
- `adb` installed and available in PATH (or in `/opt/homebrew/bin/adb` or `/usr/local/bin/adb`)

Install `adb` with Homebrew:

```bash
brew install android-platform-tools
```

## Run (Development)

```bash
swift run
```

Or open as a Swift Package in Xcode:

1. Open Xcode
2. `File` -> `Open...`
3. Select this folder
4. Run target `AndroidFileTransferApp`

## Drag-and-Drop

- Upload: drag files/folders from Finder and drop them on the file list or upload drop zone.
- Download: select one or more remote files/folders in the list, then drag a local destination folder from Finder onto the download drop zone.

## Build a Release `.app`

```bash
./Scripts/build-release-app.sh
```

Output:

- `dist/AndroidFileTransferApp.app`

## Notes

- This app uses `adb push` / `adb pull`, not MTP.
- Folder downloads use recursive `adb pull`.
- If no device appears, confirm cable mode, USB debugging, and authorization dialog on phone.
