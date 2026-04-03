# iPhone Keyboard Over Wi-Fi (iOS + macOS Host)

This workspace contains two SwiftUI targets:

- `iPhoneKeyboard-iOS`: iPhone remote keyboard client
- `iPhoneKeyboard-Mac`: macOS host (menu-bar UI + CLI mode) that injects input with `CGEvent`

It uses local-network WebSockets, Bonjour discovery, pairing code authentication, and trusted-device sessions.

## What It Does

- Remote keyboard input (text, modifiers, special keys)
- Remote trackpad input (move/click/scroll)
- Live screen preview from macOS host to iPhone
- Trusted-device pairing with optional trust reset from iPhone or Mac
- Thermal auto-stepdown on host (`Ultra` -> `Balanced`) with iOS quality control lock during override

## Project Structure

- `Shared/Protocol/RemoteKeyboardProtocol.swift`: shared JSON protocol types/codec.
- `Shared/Input/KeyboardKey.swift`: shared named-key list.
- `iOSApp/...`: discovery, client networking, preview, keyboard/trackpad UI
- `macOSApp/...`: menu-bar/CLI host, listener, capture, injection, pairing/security
- `project.yml`: XcodeGen spec for both app targets.

## Protocol Examples

```json
{ "type": "pair", "code": "123456", "deviceName": "Selva iPhone" }
{ "type": "pairAck", "success": true, "token": "..." }
{ "type": "text", "value": "h", "token": "..." }
{ "type": "key", "key": "c", "modifiers": ["command"], "action": "tap", "token": "..." }
{ "type": "streamConfig", "qualityMode": "ultra", "token": "..." }
{ "type": "trustControl", "trustAction": "forgetCurrentDevice", "deviceID": "...", "token": "..." }
{ "type": "streamStatus", "thermalOverrideActive": true }
```

## Build

The project is already generated as `iPhoneKeyboard.xcodeproj`.

To regenerate from spec:

```bash
xcodegen generate
```

Build commands used for validation:

```bash
xcodebuild -project iPhoneKeyboard.xcodeproj -scheme iPhoneKeyboard-iOS -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/iPhoneKeyboardDerived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iPhoneKeyboard.xcodeproj -scheme iPhoneKeyboard-Mac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/iPhoneKeyboardDerived CODE_SIGNING_ALLOWED=NO build
```

## Run

1. Open `iPhoneKeyboard.xcodeproj` in Xcode.
2. Run `iPhoneKeyboard-Mac` first.
3. In the menu-bar app:
   - confirm listener is running
   - note the 6-digit pairing code
   - click `Request / Open Prompt` for Accessibility if needed
4. On the Mac, grant permission at:
   - `System Settings > Privacy & Security > Accessibility`
   - enable the host app
5. For live preview, also grant:
   - `System Settings > Privacy & Security > Screen Recording`
   - enable the host app
5. Run `iPhoneKeyboard-iOS` on a physical iPhone on the same Wi-Fi.
6. In iOS app:
   - pick discovered Mac host (Bonjour)
   - enter pairing code
   - tap `Connect`
7. Tap the typing area and type. Text and key events should appear immediately on macOS.

## CLI Host Mode (Remote Mac)

You can run the mac host directly from terminal:

```bash
/Applications/iPhoneKeyboard-Mac.app/Contents/MacOS/iPhoneKeyboard-Mac --cli --port 8989
```

CLI flags:

- `--cli`: run listener headlessly in terminal
- `--port <number>`: custom listener port (default `8989`)
- `--help`: print CLI usage

In CLI mode the host prints:

- current listener state
- pairing code + expiry
- accessibility status
- connected device names

Notes for CLI mode:

- Accessibility and Screen Recording permissions still require GUI approval in System Settings.
- `--cli` is intended for headless listener lifecycle, not bypassing macOS privacy prompts.

## Notes

- Host listens on port `8989` and advertises service type `_rkbd._tcp`.
- Key mapping assumes US keyboard layout for MVP (`KeyCodeMapper`).
- iOS background execution is limited by platform policy.
- Preview quality remains user-selectable unless thermal override is active.
- During thermal override, host forces `Balanced` and iOS quality control is disabled until thermal recovers.

## Quick Functional Test

Try these after pairing:

- Type `hello` on iPhone: should appear in active Mac text field.
- Tap `⌫`: deletes one character.
- Tap `↩`: sends return.
- Enable `⌘` modifier + type `c`: sends `Cmd+C`.
- Tap arrow buttons: moves cursor.
- Open iOS trusted-device controls and test:
  - `Forget on Phone` clears local auto-reconnect trust
  - `Forget on Mac` removes this iPhone from host trusted devices (requires paired session)
