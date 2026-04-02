# iPhone Keyboard Over Wi-Fi (iOS + macOS)

This workspace contains a two-target SwiftUI prototype:

- `iPhoneKeyboard-iOS`: iPhone remote keyboard client
- `iPhoneKeyboard-Mac`: macOS menu-bar host that injects keystrokes with `CGEvent`

It uses local-network WebSockets + Bonjour discovery + pairing code authentication.

## What It Does

- iPhone captures incremental typing from a hidden `UITextField`.
- iPhone sends JSON key/text events over a persistent WebSocket.
- Mac receives events, validates pairing/session token, maps keys, and posts system keyboard events.
- Mac supports modifiers (`command`, `option`, `shift`, `control`) and special keys (`backspace`, `enter`, arrows, etc.).

## Project Structure

- `Shared/Protocol/RemoteKeyboardProtocol.swift`: shared JSON protocol types/codec.
- `Shared/Input/KeyboardKey.swift`: shared named-key list.
- `iOSApp/...`: Bonjour discovery, WebSocket client, input capture, liquid-glass UI.
- `macOSApp/...`: menu-bar UI, WebSocket listener, pairing manager, key mapper, CGEvent injector.
- `project.yml`: XcodeGen spec for both app targets.

## Protocol Examples

```json
{ "type": "pair", "code": "123456", "deviceName": "Selva iPhone" }
{ "type": "pairAck", "success": true, "token": "..." }
{ "type": "text", "value": "h", "token": "..." }
{ "type": "key", "key": "c", "modifiers": ["command"], "action": "tap", "token": "..." }
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
5. Run `iPhoneKeyboard-iOS` on a physical iPhone on the same Wi-Fi.
6. In iOS app:
   - pick discovered Mac host (Bonjour)
   - enter pairing code
   - tap `Connect`
7. Tap the typing area and type. Text and key events should appear immediately on macOS.

## Notes

- Host listens on port `8989` and advertises service type `_rkbd._tcp`.
- Key mapping assumes US keyboard layout for MVP (`KeyCodeMapper`).
- iOS sends incremental events (not full text blobs).
- iOS background execution is limited by platform policy.

## Quick Functional Test

Try these after pairing:

- Type `hello` on iPhone: should appear in active Mac text field.
- Tap `⌫`: deletes one character.
- Tap `↩`: sends return.
- Enable `⌘` modifier + type `c`: sends `Cmd+C`.
- Tap arrow buttons: moves cursor.
