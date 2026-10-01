# Contributing to MacLinker

Thanks for helping! MacLinker is a small Swift package (macOS 13+).

## Setup
```
git clone https://github.com/kaungkhantko26/MacLinker && cd MacLinker
swift test
MACLINKER_SIGN_IDENTITY=- ./scripts/bundle.sh   # ad-hoc build -> build/MacLinker.app
```
Accessibility and Input Monitoring must be granted to whatever app you run, and ad-hoc builds lose them on every rebuild. Run `scripts/setup_signing.sh` once to create a local certificate and omit `MACLINKER_SIGN_IDENTITY`.

## Layout
| Folder | What lives there |
| --- | --- |
| `Network/` | wire protocol, TCP sessions, handshake and encryption plumbing |
| `Security/` | identity keys, pairing, trusted devices, the authenticated key exchange |
| `Discovery/` | Bonjour browsing and advertising |
| `Input/` | event taps, injection, edge detection (runs on its own thread) |
| `Clipboard/`, `Transfer/` | clipboard sync and file transfer |
| `Services/` | settings, permissions, reconnect, network path/VPN detection, updater |
| `UI/` | SwiftUI views |

## Guidelines
- Keep `swift test` green and add tests for new logic. Anything crypto- or protocol-related needs a test.
- Input code runs on the input thread. Don't touch its state from other threads; use the methods that hop onto it.
- Never commit keys, certificates or personal data (`.gitignore` blocks the usual files).
- Security-sensitive changes (handshake, pairing, updater verification) get extra review. Report vulnerabilities privately through GitHub's security advisories rather than a public issue.

## Releases (maintainer)
`scripts/release.sh <version>` builds a universal app, signs it with the maintainer certificate, publishes `MacLinker.zip` + `MacLinker.dmg`, and refreshes `Casks/maclinker.rb`. The in-app updater only trusts builds signed with that same certificate.
