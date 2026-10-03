# MacLinker for Windows

The Windows side of [MacLinker](../README.md): share one keyboard and mouse, the clipboard and files between a Windows PC and a
Mac, in **both directions**, over your network or a direct cable. It speaks the same encrypted protocol as the Mac app, so a PC
and a Mac pair exactly like two Macs do.

Written in C# (.NET 10, Windows Forms). Windows 10 or 11, x64 or ARM64.

## Status: please read

| Part | How it was checked |
| --- | --- |
| Protocol, handshake, encryption, pairing code | Byte-for-byte test vectors produced by the Mac app's own code, plus a **live handshake with the real Mac app (1.7.0)** |
| Finding Macs (Bonjour / mDNS) | **Found a real MacLinker on the network** |
| Sessions, pairing, reconnect, layout sync, control hand-off, files, clipboard logic | 38 automated tests, including two complete app instances pairing over loopback |
| The Windows-only layer: `SendInput` injection, keyboard/mouse hooks, raw mouse input, hiding the pointer, the Windows clipboard, the tray and window | **Compiles into a real Windows executable, but has never been run on a Windows PC.** Expect to report a bug or two on first use |

## Install

1. Download `MacLinker-Windows-x64.zip` (or `-arm64.zip` for a Windows-on-ARM PC) from the
   [latest release](https://github.com/kaungkhantko26/MacLinker/releases/latest) and unzip it. It is one file, `MacLinker.exe`, and needs nothing else installed.
2. Run it. Windows will say **"Windows protected your PC"** because the program is not signed: choose **More info**, then **Run anyway**.
3. Windows Firewall asks about network access the first time. Tick **Private networks** and allow it, otherwise Macs can't connect to this PC.
4. MacLinker lives in the system tray (near the clock) and opens its window on first launch.

## Pair with a Mac

1. Open MacLinker on the Mac, on the same network (or cable).
2. The Mac appears in the list as **Nearby**. Select it and press **Pair** (or type its address under "Add by address").
3. Both sides show a 6-digit code. Check it is identical, then confirm on **both**.
4. Pick where the Mac sits relative to this screen ("This Mac sits: Left / Right…").

## Using it

* **Mac to PC:** push the Mac's pointer against the screen edge facing the PC.
* **PC to Mac:** push this PC's pointer against the edge facing the Mac, or press **Ctrl + Alt + Shift + Space** (and again to come back).
* The hotkey is also your emergency exit while you are controlling the Mac.
* **Clipboard** (text and images) syncs automatically. Items password managers mark as sensitive are never sent.
* **Send files** with the Send File button. Received files land in `Downloads\MacLinker`.
* Keys are swapped so shortcuts keep working: **Ctrl ↔ Command, Alt ↔ Option, Windows key ↔ Control**. Turn it off in the window (restart to apply).
* **Pointer speed** on the Mac can be tuned in `%APPDATA%\MacLinker\settings.json` (`MouseSpeed`, default 1.5).

## Connecting with a USB-C cable

A plain USB cable between two computers does **not** make a network. What does:

* **Thunderbolt 3/4 or USB4 cable** between a Mac and a PC that both have Thunderbolt / USB4 ports. On the Mac this appears as *Thunderbolt Bridge*. On the PC, Windows 11 needs Thunderbolt Networking (or USB4 networking) enabled, and some PCs need the maker's Thunderbolt driver. Both ends then get `169.254.x.x` addresses, and MacLinker prefers that direct link automatically when it finds the Mac on it.
* A special USB "bridge" cable only works if both computers have a driver for it; macOS usually does not.
* Wi-Fi or Ethernet always works.

## What the Mac app does that this one doesn't (yet)

Remote brightness and volume, locking the other computer, the device cards with keyboards and mice, copy-a-file-then-paste, and dragging across the screen edge. The Mac app is told this PC is an older client, so it never sends it those messages.

## Build from source

```
cd windows
dotnet test tests/MacLinker.Core.Tests          # the cross-platform core, runs on Windows, macOS or Linux
dotnet build src/MacLinker.Windows -c Release   # the app (can be built on macOS/Linux too, run on Windows)
scripts/publish.sh 1.8.0                        # self-contained single-file zips into ../build/
```

`tests/vectors.json` comes from the Swift test `InteropVectorTests` (`WRITE_VECTORS=1 swift test --filter InteropVectorTests` from the repo root).
If the Mac protocol changes, regenerate it and the C# tests show exactly what drifted.

## Security

Same as the Mac app: Ed25519 identities, a signed ephemeral X25519 key exchange, ChaCha20-Poly1305 with counter nonces, and a pairing code both people
must confirm. This PC's identity key is `%APPDATA%\MacLinker\identity.key` and never leaves it.
