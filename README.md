# iMote: control your Mac from your iPhone

This workspace contains two SwiftUI targets:

- `iMote-iOS`: iPhone remote keyboard client
- `iMote-Host`: macOS host (window + menu-bar extra + CLI mode) that injects input with `CGEvent`

It uses local-network WebSockets, Bonjour discovery, pairing code authentication, trusted-device sessions, and an app-layer secure channel after pairing.

## Project Policies

- License: [LICENSE](LICENSE)
- Privacy Policy: [PRIVACY.md](PRIVACY.md)
- Terms of Use: [TERMS.md](TERMS.md)

## Threat Model (Current)

This app is designed for personal devices on trusted networks.

- Intended scope: your own Mac and your own iPhone, either on the same LAN or on a tailnet you control (Tailscale).
- Discovery: Bonjour (`_rkbd._tcp`) on the local network only. Bonjour does not cross a tailnet, and that path is unchanged.
- Remote reachability: the iPhone stores hosts you enter (a Tailscale MagicDNS name or a `100.x` address, plus the port) and can reconnect to them later. The host shows the addresses it can be reached at, including its Tailscale name and address when Tailscale is running.
- Listener: `ws://` on port `8989` by default, bound on every interface so a connection that arrives on Tailscale's `utun` interface is accepted. There is still no TLS in the app.
- Tailscale encrypts the path between your devices with WireGuard. That does not replace pairing, the session token, trusted-device checks, or the app-layer channel, and a tailnet address does not skip any of them. Every tailnet peer that can open port 8989 can attempt pairing.
- Post-pairing transport: app-layer authenticated encryption for every message after the handshake, including ping, cursor position, stream status, and permission status. Pairing and the handshake themselves are still plaintext on `ws://`.
- Trust boundary: a single-use pairing code, a session token, a device id recorded only after a verified handshake, and a signing key pinned only after that signature checks out.
- Protocol: version 2. A phone or Mac on an older build is rejected with an update message. They do not fall through into the old handshake.
- Main risk if the network is untrusted: anyone who can route to the listener port can still probe it before pairing, and transport metadata is not protected by TLS. Do not publish this port on a public interface. A tailnet you control is in scope. The open internet is not.

Current mitigations:

- 6-digit pairing code. A successful guess burns it. Failed guesses wait, and five failures rotate it.
- A trusted phone can reconnect without a code only when its signing key is already pinned. The id is added to that set only after the handshake signature verifies.
- Curve25519 handshake with signed ephemeral keys. The signature is checked before either side writes a pin. A bad hello does not stick.
- Clear, Remove, and Forget delete the pin as well as the trusted id. The Mac window, menu bar, and iPhone show a fingerprint on first pair.
- ChaChaPoly with a direction and a counter in the associated data, so a captured control or media box cannot be replayed. The outer `secureControl` frame does not carry the session token.
- Signing private keys live in the keychain, this device only. An older preferences copy is deleted and not imported, so both apps pair again with new keys.
- Host audio is AAC-LC. Capture and the microphone stop when the last paired phone leaves.
- Shortcuts and shifted characters are resolved from the Mac's current keyboard layout.
- Saved remote hosts are local to the iPhone. They are addresses, not credentials.

Not a hardened remote administration solution yet:

- No TLS on the underlying WebSocket transport.
- No cloud relay. Remote access is a direct connection over your LAN or tailnet.
- No enterprise IAM / policy enforcement.

## What It Does

- Remote keyboard input (text, modifiers, special keys)
- Remote trackpad input (move/click/scroll)
- Live screen preview from macOS host to iPhone
- Host audio streaming to iPhone (`System`, `Mic`, or `Both`)
- Trusted-device pairing with optional trust reset from iPhone or Mac
- Start on Login support for the macOS host
- Saved remote hosts on iPhone for Tailscale MagicDNS names or `100.x` addresses
- Host window and menu bar list LAN and Tailscale addresses
- Host permission checklist for Accessibility and Screen Recording
- Host preview diagnostics on iPhone (`capture route`, `display count`, `live/no frames`)
- Thermal auto-stepdown on host (`Ultra` -> `Balanced`) with iOS quality control lock during override

## Project Structure

- `Shared/Protocol/RemoteKeyboardProtocol.swift`: shared JSON protocol types/codec.
- `Shared/Input/KeyboardKey.swift`: shared named-key list.
- `iOSApp/...`: discovery, client networking, preview, keyboard/trackpad UI
- `macOSApp/...`: window, menu-bar, and CLI host, listener, capture, injection, pairing/security
- `project.yml`: XcodeGen spec for both app targets.

## Protocol Examples

Pairing and the handshake carry `protocolVersion`. After the handshake, control messages (text, keys, ping, and the host's cursor and status) are the plaintext inside `secureControl`, not separate frames.

```json
{ "type": "pair", "code": "123456", "deviceName": "Selva iPhone", "deviceID": "...", "protocolVersion": 2 }
{ "type": "pairAck", "success": true, "token": "...", "deviceID": "...", "protocolVersion": 2 }
{ "type": "e2eHello", "deviceID": "...", "signingPublicKey": "...", "ephemeralPublicKey": "...", "signature": "...", "token": "...", "protocolVersion": 2 }
{ "type": "secureControl", "securePayload": "<base64 ChaChaPoly box>" }
```

A missing or different `protocolVersion` fails the pair. The inner payload is still the same JSON (`text`, `key`, `streamConfig`, `audioConfig`, `trustControl`, `ping`, `cursorPosition`, `streamStatus`), sealed with the direction and counter as associated data.

## Build

The project is already generated as `iMote.xcodeproj`.

To regenerate from spec:

```bash
xcodegen generate
```

Build commands used for validation:

```bash
xcodebuild -project iMote.xcodeproj -scheme iMote-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/iMoteDerivedIOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iMote.xcodeproj -scheme iMote-Host -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/iMoteDerived CODE_SIGNING_ALLOWED=NO build
```

## Run

1. Open `iMote.xcodeproj` in Xcode.
2. Run `iMote-Host` first.
3. In the iMote Host window, or the menu-bar extra:
   - confirm the listener is running
   - note the 6-digit pairing code
   - copy a reachable address if the iPhone is not on the same Wi-Fi
   - use Request for Accessibility, and Screen Recording for live preview
4. On the Mac, grant permission at:
   - `System Settings > Privacy & Security > Accessibility`
   - enable the host app
5. For live preview, also grant:
   - `System Settings > Privacy & Security > Screen Recording`
   - enable the host app
6. Same Wi-Fi: run `iMote-iOS` on a physical iPhone.
7. In the iOS app, leave the mode on Local:
   - pick the discovered Mac host (Bonjour)
   - enter the pairing code
   - tap `Connect`
8. Tap the typing area and type. Text and key events should appear immediately on macOS.

Closing the host window leaves the menu-bar extra and the listener running. Click the Dock icon, or Show Window in the menu bar, to open it again.

### Remote use (Tailscale)

Bonjour stays on the LAN. To connect from another network, both devices join a tailnet you control. The app does not embed Tailscale and does not change Tailscale or firewall settings.

1. Install Tailscale on the Mac and the iPhone and sign both into the same tailnet.
2. Run iMote Host. Under Reachable, copy the Tailscale name (for example `macbook.tailnet.ts.net:8989`) or the `100.x` address. The local name and LAN address stay in that list for same-Wi-Fi use.
3. On the iPhone, choose Remote, paste the host, and leave the port at `8989` unless you changed it. A pasted `host:port` is accepted. Enter the pairing code and tap Connect.
4. The host is saved on the iPhone. Next time, pick it under Saved hosts. A trusted device can reconnect without a new code until trust is cleared.
5. Local discovery still finds the Mac when the iPhone is on its Wi-Fi.

The iOS app allows cleartext `ws://` with `NSAllowsArbitraryLoads`, which is what lets a tailnet host work. Do not add `NSAllowsLocalNetworking` beside that key. On iOS 10 and later, adding it makes the system ignore `NSAllowsArbitraryLoads`, and cleartext connections to non-LAN hosts stop working.

If the Mac firewall asks the first time the listener starts, allow incoming connections for iMote Host. The iPhone also needs the Tailscale VPN connected, or the `100.x` address and MagicDNS name will not route.

## CLI Host Mode (Remote Mac)

You can run the mac host directly from terminal:

```bash
/Applications/iMote-Host.app/Contents/MacOS/iMote-Host --cli --port 8989
```

CLI flags:

- `--cli`: run listener headlessly in terminal
- `--port <number>`: custom listener port (default `8989`)
- `--help`: print CLI usage

In CLI mode the host prints:

- current listener state
- pairing code + expiry
- this Mac's signing fingerprint, and the iPhone fingerprint after a pair
- accessibility status
- reachable LAN and Tailscale addresses
- connected device names

Notes for CLI mode:

- Accessibility and Screen Recording permissions still require GUI approval in System Settings.
- `--cli` is intended for headless listener lifecycle, not bypassing macOS privacy prompts.

## Notes

- Host listens on port `8989` on all interfaces, including Tailscale's interface when Tailscale is running, and advertises `_rkbd._tcp` on the local network only.
- Shortcuts and capitals follow the Mac's current keyboard layout. Named keys such as Return and the arrows stay on fixed virtual keycodes.
- Protocol version is 2. Update the iPhone and the Mac together. An older build stops with an update message instead of pairing.
- iOS background execution is limited by platform policy.
- The iPhone preview strip can show host capture diagnostics such as route (`Real` / `Dummy/Fallback` / `Unknown`), online display count, and whether preview frames are currently live.
- Preview quality remains user-selectable unless thermal override is active.
- During thermal override, host forces `Balanced` and iOS quality control is disabled until thermal recovers.

## Privacy

- Keyboard/mouse commands and preview frames are exchanged directly between your iPhone and Mac host, either on the local network or over a tailnet you control. There is no relay in this app.
- Saved remote hosts (name or IP, and port) are stored on the iPhone. Trusted-device display names are stored on the Mac.
- After the handshake, control messages (including ping, cursor, and status) and media are protected by the app-layer secure channel. Pairing and the handshake are not.
- The app does not include a cloud relay/backend in the current architecture.
- Trusted device ids, display names, and peer signing-key pins are stored locally on the host. Forget, Remove, and Clear delete the pin with the id.
- Each app's own signing private key is in the keychain with this-device-only protection. It is not kept in preferences, and an older preferences value is not copied in.
- Screen preview requires macOS Screen Recording permission. Input injection requires Accessibility. Mic and Both also require the microphone, which the host asks for with a usage string.

## Legal and Safety

- Use only on Macs and iPhones you own or are explicitly authorized to control.
- Do not expose the host listener to untrusted/public networks without additional hardening.
- This project can control keyboard/mouse and stream desktop pixels; misuse can cause data/privacy harm.
- You are responsible for complying with local laws, organizational policies, and platform terms when operating this software.

## Quick Functional Test

Try these after pairing:

- Type `hello` on iPhone: should appear in active Mac text field.
- Tap `⌫`: deletes one character.
- Tap `↩`: sends return.
- Enable `⌘` modifier + type `c`: sends `Cmd+C` for the Mac's current layout, including a non-US layout.
- Tap arrow buttons: moves cursor.
- Change iPhone audio source to `System`, `Mic`, or `Both`: host audio should follow the selected mode, and the orange mic indicator should go away after the phone disconnects.
- Compare the fingerprint on the iPhone with This Mac in the host window the first time you pair.
- Forget trusted Mac on the iPhone, or Clear trusted devices on the Mac. The next connection needs a new code, and a bad pin does not survive the forget.
