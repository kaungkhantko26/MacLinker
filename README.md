# MacLinker 🔗

[![CI](https://github.com/kaungkhantko26/MacLinker/actions/workflows/ci.yml/badge.svg)](https://github.com/kaungkhantko26/MacLinker/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/kaungkhantko26/MacLinker)](https://github.com/kaungkhantko26/MacLinker/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![License MIT](https://img.shields.io/badge/license-MIT-green)

One keyboard and mouse, a shared clipboard and file transfer between your Macs, **without relying on Apple's Continuity / Universal Control**.

Works on Apple Silicon and Intel Macs running macOS 13 or later.

## Why this exists (root cause)

Universal Control and Handoff often refuse to connect even when both Macs look correctly set up. They depend on a stack of things that all have to line up at once:

- the same Apple ID/iCloud account, with Bluetooth, Wi-Fi and Handoff all enabled on both Macs;
- Bluetooth LE for discovery plus a direct peer-to-peer Wi-Fi link (AWDL) for the data;
- no VPN, firewall, content filter or network setting that interferes with that peer-to-peer link;
- a supported Mac model, and the feature switched on in System Settings.

When any one of those fails (a VPN such as Outline in the way, a Wi-Fi network that isolates devices, a flaky AWDL link) there is no error and no way to see what went wrong; the Macs just don't connect.

MacLinker replaces that stack with something simple and observable: plain TCP over your normal network (Wi-Fi, Ethernet or a USB-C/Thunderbolt cable), found with standard Bonjour, with its own pairing and encryption. No iCloud account, Bluetooth or AWDL needed.

## Features

- Share keyboard and mouse: push the pointer against a screen edge to cross to the other Mac
- Clipboard sync (text, links, images)
- File transfer, with drag and drop
- Automatic discovery (Bonjour) and automatic reconnect; add a Mac by IP or `name.local` if discovery is blocked
- Prefers a direct USB-C/Thunderbolt cable or Ethernet over Wi-Fi for the lowest latency
- Works alongside VPNs: Mac-to-Mac traffic is pinned to the physical network interface so it never enters a tunnel (for example Outline)
- End-to-end encrypted and authenticated; menu-bar app plus a normal window
- Signed in-app updates from GitHub Releases

## Install

**Homebrew**
```
brew tap kaungkhantko26/maclinker https://github.com/kaungkhantko26/MacLinker
brew install --cask maclinker
```

**Or download:** get `MacLinker.dmg` (drag to Applications) or `MacLinker.zip` from the [latest release](https://github.com/kaungkhantko26/MacLinker/releases/latest) on **each** Mac.

Then, on each Mac:

1. Move `MacLinker.app` to **Applications** and open it from there. Because the app isn't notarized by Apple, the first launch needs **right-click > Open**, or:
   ```
   xattr -dr com.apple.quarantine /Applications/MacLinker.app
   ```
2. Allow **Accessibility** and **Input Monitoring** in System Settings > Privacy & Security. macOS requires this for any app that reads or sends keyboard/mouse input; it cannot be skipped. Restart MacLinker after granting.
3. On one Mac click **Pair**. Confirm the 6-digit code is identical on both Macs, then confirm on both.
4. In Devices, choose which side the other Mac sits on. Push the pointer against that edge to cross.

Emergency exit while controlling the other Mac: **Control + Option + Command + Esc**.

Updates install themselves: Settings > Updates > Check Now, then Restart & Update.

## Tips for the lowest latency

Use a USB-C/Thunderbolt cable between the Macs (Thunderbolt Bridge appears in System Settings > Network), or Ethernet. Otherwise use 5 GHz Wi-Fi close to the router. The Devices tab shows live latency.

## Using it with a VPN (e.g. Outline)

A VPN installs a system tunnel and sends most traffic through it. MacLinker binds its connections to the physical interface so Mac-to-Mac traffic stays local. Both Macs need to be on the same local network (or cable). A VPN client can't connect two Macs to each other by itself.

## How it works

```
 Mac A                                             Mac B
 event taps (own thread) ──► batch @ ~300 Hz ──► encrypted TCP ──► input thread ──► CGEvent
 clipboard / files      ───────────────────────►                ──► pasteboard / Downloads
            Bonjour discovery  +  pairing  +  reconnect  +  VPN-aware interface pinning
```

Input capture, batching and injection run on a dedicated high-priority thread, so a busy UI never delays the pointer. While the pointer is on its own Mac the event tap is listen-only and adds no latency.

## Security

- Each Mac has an Ed25519 identity key, created on first launch and stored only on that Mac (`~/Library/Application Support/MacLinker`, mode 0600).
- Sessions use an ephemeral X25519 key exchange signed by those identities, then ChaCha20-Poly1305 with counter nonces (replay and reorder safe).
- First pairing needs both users to confirm a short code derived from the handshake, which defeats a man-in-the-middle.
- Clipboard items flagged as concealed/transient by password managers are never sent. Received files are saved to `~/Downloads/MacLinker` with sanitized names.
- Updates must be signed by the same certificate as the running app.

## Build from source

```
git clone https://github.com/kaungkhantko26/MacLinker && cd MacLinker
swift test
MACLINKER_SIGN_IDENTITY=- ./scripts/bundle.sh     # ad-hoc signed universal app -> build/MacLinker.app
```

For a signing identity that keeps your permissions across rebuilds, run `scripts/setup_signing.sh` once (creates a local self-signed certificate) and omit `MACLINKER_SIGN_IDENTITY`. Maintainers publish with `scripts/release.sh <version>`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). CI builds a universal binary and runs the tests on every push.

## Status

Early software. Not supported: media keys, folder transfer. Bug reports and pull requests are welcome.

## Author

Built by **Kaung Khant Ko** ([@kaungkhantko26](https://github.com/kaungkhantko26)).

## License

MIT, copyright Kaung Khant Ko and MacLinker contributors.
