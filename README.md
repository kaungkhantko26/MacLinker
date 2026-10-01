# MacLinker 🔗

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

1. Download `MacLinker.zip` from the [latest release](https://github.com/kaungkhantko26/MacLinker/releases/latest) on **each** Mac and unzip it.
2. Move `MacLinker.app` to Applications. Because the app isn't notarized by Apple, the first time **right-click > Open**, or run:
   ```
   xattr -dr com.apple.quarantine /Applications/MacLinker.app
   ```
3. Allow **Accessibility** and **Input Monitoring** in System Settings > Privacy & Security. macOS requires this for any app that reads or sends keyboard/mouse input; it cannot be skipped. Restart MacLinker after granting.
4. On one Mac click **Pair**. Confirm the 6-digit code is identical on both Macs, then confirm on both.
5. In Devices, choose which side the other Mac sits on. Push the pointer against that edge to cross.

Emergency exit while controlling the other Mac: **Control + Option + Command + Esc**.

## Tips for the lowest latency

Use a USB-C/Thunderbolt cable between the Macs (Thunderbolt Bridge appears in System Settings > Network), or Ethernet. Otherwise use 5 GHz Wi-Fi close to the router. The Devices tab shows live latency.

## Using it with a VPN (e.g. Outline)

A VPN installs a system tunnel and sends most traffic through it. MacLinker binds its connections to the physical interface so Mac-to-Mac traffic stays local. Both Macs need to be on the same local network (or cable). A VPN client can't connect two Macs to each other by itself.

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

## Status

Early software. Not supported: media keys, folder transfer. Bug reports and pull requests are welcome.

## License

MIT
