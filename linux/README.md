# MacLinker for Linux

The Linux side of [MacLinker](../README.md): share one keyboard and mouse, the clipboard and files between a Linux
machine and a Mac, in **both directions**, over your network or a USB-C/Ethernet link. It speaks the same encrypted
protocol as the macOS app, so a Mac and a Linux box pair exactly like two Macs do.

Written in Python (3.9+). Works on X11 and Wayland (GNOME, KDE, wlroots) because it uses the kernel's `uinput`
and `evdev` rather than a desktop-specific API.

## Status: read this first

| Part | Verified how |
| --- | --- |
| Protocol, handshake, encryption, pairing code | Byte-for-byte test vectors generated from the macOS app's Swift code, plus a **live handshake against the real Mac app** (it decrypted the Mac's hello and reached the pairing step) |
| Sessions, pairing, reconnect, layout sync, file transfer, control hand-off | Automated tests, including two full daemons talking over loopback |
| Keyboard/mouse injection (`uinput`), capture (`evdev`), clipboard tools, Avahi discovery | **Written carefully but not yet run on a real Linux desktop.** Expect to report a bug or two the first time |

## Install

Download `maclinker-linux.tar.gz` from the [latest release](https://github.com/kaungkhantko26/MacLinker/releases/latest):

```
tar xzf maclinker-linux.tar.gz && cd maclinker-linux
./deploy/install.sh
```

or build from source:

```
git clone https://github.com/kaungkhantko26/MacLinker && cd MacLinker/linux
./deploy/install.sh
```

That creates a private virtualenv in `~/.local/share/maclinker`, links `maclinker` into `~/.local/bin`, and installs a
systemd user service. Then grant device access once (the installer prints these; they need sudo):

```
sudo cp deploy/99-maclinker.rules /etc/udev/rules.d/
echo uinput | sudo tee /etc/modules-load.d/maclinker.conf
sudo modprobe uinput
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -aG input "$USER"      # then log out and back in
```

Optional: `wl-clipboard` (Wayland) or `xclip` (X11) for clipboard sync; `python-xlib` (`pip install 'maclinker[x11]'`)
so pushing the pointer against a screen edge works on X11.

Start it: `systemctl --user enable --now maclinker`, or run it in a terminal with `maclinker run -v`.

## Pair with a Mac

1. Open MacLinker on the Mac and have it on the same network (or connected by a cable).
2. On Linux: `maclinker status` shows the Mac if discovery found it, otherwise `maclinker connect 192.168.1.6`
   (the Mac's IP or `name.local`).
3. Both sides show a 6-digit code. Check it matches, then confirm on **both**: on the Mac click *Codes Match*, on
   Linux run `maclinker confirm` (or answer `y` if running in a terminal).
4. Say where the Mac sits relative to your Linux screen: `maclinker position "Mac mini" right`.

## Using it

* **Mac to Linux**: push the Mac's pointer against the Mac's screen edge facing the Linux machine.
* **Linux to Mac**: on **X11** push the pointer against the edge facing the Mac. On **Wayland** (which never tells apps
  where the pointer is) press **Ctrl + Alt + Shift + Space** to move to the Mac, and the same keys to come back.
* Emergency exit while driving the Mac: the same hotkey (or `maclinker toggle`).
* **Clipboard** syncs automatically. Items that password managers mark as sensitive are never sent.
* **Files**: `maclinker send ~/report.pdf` (add `--to "Mac mini"` if several are connected). Received files land in
  `~/Downloads/MacLinker`.

### Keyboard layout

Shortcuts keep working the way you expect by swapping modifiers: **Ctrl ↔ Command, Alt ↔ Option, Super ↔ Control**.
So Ctrl+C on the Linux keyboard is Cmd+C on the Mac, and Cmd+C from the Mac is Ctrl+C on Linux. Turn it off with
`--no-swap-modifiers`. Other tuning: `--mouse-speed 1.5`, `--edge-push 20`, `--scroll-invert`.

## Commands

```
maclinker run [options]          start the daemon
maclinker status                 devices, state, latency, pending pairing
maclinker confirm | reject       answer a pairing request
maclinker connect HOST[:PORT]    connect to a Mac by address
maclinker position DEVICE EDGE   left | right | top | bottom | none
maclinker send FILE [--to NAME]  send a file
maclinker toggle                 switch control to/from the Mac
maclinker forget DEVICE          unpair
maclinker setup                  print the one-time permission setup
```

## Limits

* Multiple monitors are treated as one desktop; screen size comes from `xrandr`, then `/sys/class/drm`. Override with
  `MACLINKER_SCREEN=2560x1440`.
* No remote brightness/volume on Linux (the Mac app doesn't send those to builds older than its 1.2.0, and this one
  reports itself as older on purpose).
* Touchpads are supported for pointer motion only (no gestures).
* The Mac app's VPN pinning has no Linux counterpart yet: if a VPN swallows LAN traffic on the Linux box, use a cable
  or exclude the LAN in the VPN client.
* Smooth (high-resolution) scrolling from a Linux mouse is sent as whole notches.

## Security

Same as the Mac app: Ed25519 identities, a signed ephemeral X25519 key exchange, ChaCha20-Poly1305 with counter
nonces, and a pairing code both people must confirm. Your identity key is `~/.config/maclinker/identity.key` (mode
0600) and never leaves the machine. Anyone allowed to use `uinput`/`input` on your account can inject input, which is
how Linux works for any such tool.

## Development

```
python3 -m venv .venv && .venv/bin/pip install -e '.[test]'
.venv/bin/pytest
```

`tests/vectors.json` is produced by the Swift test `InteropVectorTests` (`WRITE_VECTORS=1 swift test --filter
InteropVectorTests` from the repo root). If the Mac protocol changes, regenerate it and the Python tests will show
exactly what drifted.
