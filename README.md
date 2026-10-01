<p align="center"><img src="docs/banner.svg" alt="MacLinker: one keyboard and mouse across your Macs" width="100%"></p>

<p align="center">
  <a href="https://github.com/kaungkhantko26/MacLinker/actions/workflows/ci.yml"><img src="https://github.com/kaungkhantko26/MacLinker/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kaungkhantko26/MacLinker/releases/latest"><img src="https://img.shields.io/github/v/release/kaungkhantko26/MacLinker" alt="Latest release"></a>
  <img src="https://img.shields.io/github/downloads/kaungkhantko26/MacLinker/total" alt="Downloads">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-8b5cf6" alt="Universal">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

<p align="center"><b>Push your pointer off the edge of one Mac and it appears on the other.</b><br>
Shared keyboard and mouse, clipboard, file drop and remote brightness/volume, over a plain network or a USB-C cable.</p>

---

## Why this exists

Apple's Universal Control and Handoff often refuse to connect even when both Macs look set up correctly. They need the same Apple ID, Bluetooth, Wi-Fi and Handoff all on, plus a direct peer-to-peer Wi-Fi link (AWDL) that VPNs, firewalls and some networks quietly break. When it fails there is no error and no way to see why.

MacLinker swaps that stack for something simple and visible: **plain encrypted TCP**, found with standard Bonjour, with its own pairing. No iCloud account, no Bluetooth, no AWDL.

| | Universal Control | MacLinker |
| --- | --- | --- |
| Needs same Apple ID / iCloud | Yes | **No** |
| Needs Bluetooth + peer-to-peer Wi-Fi | Yes | **No** |
| Works through a USB-C / Thunderbolt cable | Not as a documented path | **Yes, preferred automatically** |
| Works next to a VPN (e.g. Outline) | Often breaks | **Yes: traffic stays on the local link** |
| Shows what's wrong | No | **Link in use, latency, connection state** |
| Remote brightness / volume of the other Mac | No | **Yes** |
| Use another Mac as an extra monitor | Sidecar (iPad only) | **Yes, Mac to Mac** |
| Open source | No | **Yes (MIT)** |

## Features

- **Edge-crossing control**: push the pointer against a screen edge to move to the other Mac, with the keyboard following
- **Clipboard sync** for text, links and images (password-manager items are never sent)
- **File transfer**, including drag and drop onto the connected Mac
- **Remote brightness and volume** sliders for the other Mac (built-in displays, and DDC-capable external monitors on Apple Silicon)
- **Use a Mac as a second display**: your desktop extends onto the other Mac, with its mouse and keyboard working on it
- **Fast on a cable**: prefers a USB-C/Thunderbolt or Ethernet link over Wi-Fi, and shows the link and latency live
- **Works with VPNs**: Mac-to-Mac traffic is pinned to the physical interface so it never enters a tunnel
- **Automatic discovery and reconnect**, or add a Mac by IP or `name.local`
- **Secure by default**: end-to-end encrypted, mutually authenticated, pairing confirmed by a code on both screens
- **Self-updating** from signed GitHub releases; menu-bar app plus a normal window

## Install

**Homebrew**
```
brew tap kaungkhantko26/maclinker https://github.com/kaungkhantko26/MacLinker
brew install --cask maclinker
```

**Or download** `MacLinker.dmg` (drag to Applications) or `MacLinker.zip` from the [latest release](https://github.com/kaungkhantko26/MacLinker/releases/latest) on **each** Mac.

Then, on each Mac:

1. Open it from **Applications**. It isn't notarized by Apple, so the first launch needs **right-click > Open**, or:
   ```
   xattr -dr com.apple.quarantine /Applications/MacLinker.app
   ```
2. Allow **Accessibility** and **Input Monitoring** in System Settings > Privacy & Security. macOS requires this for any app that reads or sends keyboard and mouse input; it cannot be skipped. Restart MacLinker afterwards.
3. On one Mac click **Pair**. Check the 6-digit code is identical on both Macs, then confirm on both.
4. In **Devices**, choose which side the other Mac sits on. Push the pointer against that edge.

Emergency exit while controlling the other Mac: **Control + Option + Command + Esc**.

Updates install themselves: Settings > Updates > Check Now, then Restart & Update.

## Use a Mac as a second display

Extend one Mac's desktop onto the other Mac's screen, like an external monitor:

1. On the Mac whose desktop you want to extend (the **host**), open MacLinker, find the other Mac under Devices, and click **Start** next to "Use … as a second display".
2. The other Mac (the **viewer**) asks you to allow it. Click **Allow**. Its screen then shows a new display from the host.
3. Drag windows onto the new display, or arrange it under System Settings > Displays on the host (**Arrange Displays…** opens it). The pointer moves onto it like any monitor, and the viewer's own mouse and keyboard work on it too.
4. Stop with **Stop** on the host, or press **Control+Option+Command+Esc** on the viewer.

Requirements and limits:

- Both Macs need MacLinker 1.4.0 or newer, and the host needs the **Screen Recording** permission (Settings shows it, and macOS asks the first time).
- It uses a private macOS interface to create the virtual display (the same one DeskPad and BetterDisplay use), so a future macOS update could break it. If macOS refuses, MacLinker tells you instead of failing silently.
- It's a video stream (H.264 over your encrypted link), so expect a small delay: fine for documents, chat and reference windows, and not a replacement for a real monitor for fast video or games. A USB-C cable or 5 GHz Wi-Fi gives the best result. **Settings > Second display** has a Balanced (smoother) and a Sharp (full Retina) option.
- No audio. Only one display share at a time.

## For the lowest latency

Use a USB-C/Thunderbolt cable between the Macs (Thunderbolt Bridge appears in System Settings > Network) or Ethernet. Otherwise use 5 GHz Wi-Fi near the router. The Devices tab shows the link in use (`bridge0` = cable, `en0` = Wi-Fi) and live latency.

## Using it with a VPN (Outline and others)

A VPN installs a system tunnel and sends most traffic through it. MacLinker binds its connections to the physical interface so Mac-to-Mac traffic stays local. Both Macs need to be on the same network or cable; a VPN client can't connect two Macs to each other by itself.

## FAQ

**Do I really have to grant Accessibility and Input Monitoring?** Yes. macOS requires both for anything that captures or injects keyboard and mouse input. It's one-time per Mac, and updates keep the grant because every release is signed with the same certificate.

**Why isn't it notarized?** Notarization needs a paid Apple Developer account. Until then, the first launch needs right-click > Open (the in-app updater and Homebrew handle this for you afterwards).

**Is my keyboard traffic safe?** Everything is encrypted and authenticated, and a new Mac can only join after both people confirm a matching code. Details below.

**It connects but the pointer lags.** Check the link in the Devices tab. If it says `en0`, you're on Wi-Fi: use a cable or 5 GHz.

**Can it control a Mac over the internet?** No. It's designed for Macs on the same network or cable.

## How it works

```
 Mac A                                             Mac B
 event taps (own thread) ──► batch @ ~300 Hz ──► encrypted TCP ──► input thread ──► CGEvent
 clipboard / files / brightness ───────────────►                ──► pasteboard / Downloads / display
            Bonjour discovery  +  pairing  +  reconnect  +  VPN-aware interface pinning
```

Input capture, batching and injection run on a dedicated high-priority thread, so a busy UI never delays the pointer. While the pointer is on its own Mac, the event tap is listen-only and adds no latency.

## Security

- Each Mac has an Ed25519 identity key, created on first launch and kept only on that Mac (`~/Library/Application Support/MacLinker`, mode 0600).
- Sessions use an ephemeral X25519 key exchange signed by those identities, then ChaCha20-Poly1305 with counter nonces (replay and reorder safe).
- First pairing needs both users to confirm a short code derived from the handshake, which defeats a man-in-the-middle.
- Clipboard items flagged as concealed or transient by password managers are never sent. Received files go to `~/Downloads/MacLinker` with sanitized names.
- Updates must be signed by the same certificate as the running app.

## Roadmap

- [ ] Display layout matching for multi-monitor setups
- [ ] Second display: audio, and sharing to more than one Mac
- [ ] Remote display resolution and refresh rate
- [ ] Remote sleep, lock and wake
- [ ] Notarized builds
- [ ] Media-key forwarding and folder transfer

Ideas welcome: open an [issue](https://github.com/kaungkhantko26/MacLinker/issues/new/choose).

## Build from source

```
git clone https://github.com/kaungkhantko26/MacLinker && cd MacLinker
swift test
MACLINKER_SIGN_IDENTITY=- ./scripts/bundle.sh     # ad-hoc signed universal app -> build/MacLinker.app
```

For a signing identity that keeps your permissions across rebuilds, run `scripts/setup_signing.sh` once and omit `MACLINKER_SIGN_IDENTITY`. Maintainers publish with `scripts/release.sh <version>`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Author

Built by **Kaung Khant Ko** ([@kaungkhantko26](https://github.com/kaungkhantko26)). If MacLinker saves you from a Continuity headache, a ⭐ helps others find it.

## License

MIT, copyright Kaung Khant Ko and MacLinker contributors.
