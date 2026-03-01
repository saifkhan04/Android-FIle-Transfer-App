# Android File Transfer App (macOS)

A native macOS SwiftUI app for transferring files between Android and Mac using `adb` (Android Platform Tools).

## Features

- Dual-pane file browser:
  - Left pane: Android device
  - Right pane: Mac local filesystem
- Per-pane navigation (`Back`, `Forward`) and pane-specific `Refresh`
- Per-pane selection controls:
  - Row checkbox selection
  - `Cmd + click` multi-select
  - Select-all checkbox in each pane header
- Cross-pane exclusive selection (selecting one side clears the other side)
- One-click transfer actions:
  - Android pane transfer icon downloads selected Android items to current Mac folder
  - Mac pane transfer icon uploads selected Mac items to current Android folder
- Recursive folder download with directory structure preservation
- Transfer queue with:
  - Pending / in-progress / completed / cancelled / failed states
  - Per-item animated progress indicator for active transfers
  - Cancel pending item, Cancel All, Clear Queue
- Delete selected files/folders on both Android and Mac (with confirmation)
- Friendly device name detection via adb properties

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

## Build and Run

Build the `.app` bundle:

```bash
./Scripts/build-release-app.sh
```

Output:

- `dist/AndroidFileTransferApp.app`

Launch it from Finder or terminal:

```bash
open "dist/AndroidFileTransferApp.app"
```

For development, you can also run directly:

```bash
swift run
```

Or open as a Swift Package in Xcode:

1. Open Xcode
2. `File` -> `Open...`
3. Select this folder
4. Run target `AndroidFileTransferApp`

## Usage

1. Connect Android phone via USB.
2. Enable USB debugging on the phone and accept the RSA authorization prompt.
3. Open the app and confirm the connected device name in the top bar.
4. Browse Android folders in the left pane and Mac folders in the right pane.
5. Select items:
   - Single click selects one row
   - `Cmd + click` toggles multiple rows
   - Use the select-all checkbox in a pane header to select everything in that pane
6. Transfer:
   - To download Android -> Mac: select in left pane and click the down transfer icon in left header.
   - To upload Mac -> Android: select in right pane and click the up transfer icon in right header.
7. Watch progress and status in the transfer queue footer.
8. Use delete (trash icon) in either pane header to delete selected items on that side.

## Troubleshooting

- No device detected:
  - Run `adb devices` and verify the phone appears as `device`.
  - Reconnect USB cable and accept the phone authorization prompt again.
- You see `unauthorized` in `adb devices`:
  - Revoke USB debugging authorizations on phone, reconnect, and re-allow prompt.
- App cannot browse expected Android storage:
  - Confirm device is unlocked and still authorized.
  - Verify path in terminal: `adb shell ls -1Ap /sdcard`
- adb missing:
  - Install with Homebrew and reopen terminal/app.

## Notes

- This app uses `adb push` / `adb pull`, not MTP.
- Architecture is modular (`Views`, `ViewModels`, `Backend`, `Domain`) so a future MTP backend can be added by implementing the backend protocol.
