# Privacy Policy

Last updated: 2026-04-03

This project (`iPhoneKeyboard`) is software that lets an iPhone send input to a Mac host and optionally view a live screen preview.

## What Data Is Processed

- Pairing/session data:
  - Pairing code
  - Session token
  - Device name
  - Device identifier (for trusted-device behavior)
- Input data:
  - Keyboard events/text
  - Mouse/trackpad events
- Preview data (optional):
  - Screen frames captured on the Mac and streamed to the paired iPhone

## Where Data Is Stored

- Trusted device IDs are stored locally on the Mac host using local app storage.
- Session tokens are short-lived in-memory/session data.
- This project does not include a cloud backend by default.

## Data Sharing

- Data is exchanged between your iPhone and Mac host over your network.
- The project does not intentionally transmit data to third-party servers in its default architecture.

## Permissions

The Mac host may request:

- Accessibility permission (to inject keyboard/mouse input)
- Screen Recording permission (to provide live preview)

## Security and Network Notice

- Current transport is designed for trusted LAN/VPN scenarios.
- Do not expose the host to untrusted/public networks without additional hardening (for example TLS, stronger auth, and network controls).

## Your Responsibilities

You are responsible for:

- Using the software only on systems you own/control or are authorized to access
- Complying with applicable laws, policies, and platform terms

## Contact

For project privacy questions, open an issue in this repository.
