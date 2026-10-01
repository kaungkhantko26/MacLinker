"""Command line: `maclinker run` starts the daemon; the other commands talk to a running one."""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path

from . import DEFAULT_PORT, __version__
from .identity import config_dir

SETUP_TEXT = """\
MacLinker needs access to two kernel devices:
  /dev/uinput       to inject keyboard/mouse events (so a Mac can control this machine)
  /dev/input/event* to read keyboard/mouse events (so this machine can control a Mac)

One-time setup (needs sudo):
  sudo cp deploy/99-maclinker.rules /etc/udev/rules.d/
  echo uinput | sudo tee /etc/modules-load.d/maclinker.conf
  sudo modprobe uinput
  sudo udevadm control --reload-rules && sudo udevadm trigger
  sudo usermod -aG input "$USER"        # then log out and back in

Optional, for clipboard sync: wl-clipboard (Wayland) or xclip (X11).
Optional, for edge-crossing on X11: pip install 'maclinker[x11]'.
On Wayland, switch control to the Mac with the hotkey Ctrl+Alt+Shift+Space.
"""


def ctl(cmd: dict) -> dict:
    path = config_dir() / "ctl.sock"

    async def go() -> dict:
        reader, writer = await asyncio.open_unix_connection(str(path))
        writer.write(json.dumps(cmd).encode() + b"\n")
        await writer.drain()
        data = await reader.readline()
        writer.close()
        return json.loads(data)

    try:
        return asyncio.run(go())
    except (FileNotFoundError, ConnectionRefusedError):
        return {"ok": False, "error": "MacLinker isn't running. Start it with `maclinker run`."}


def show(reply: dict) -> int:
    if not reply.get("ok"):
        print(f"error: {reply.get('error')}", file=sys.stderr)
        return 1
    if "message" in reply:
        print(reply["message"])
    return 0


def print_status(r: dict) -> None:
    print(f"{r['name']} [{r['id']}] port {r['port']}  state: {r['state']}")
    for d in r["devices"]:
        lat = f"  {d['latency_ms']:.0f} ms" if d.get("latency_ms") is not None else ""
        state = "connected" if d["connected"] else ("nearby" if d["nearby"] else "offline")
        print(f"  {d['name']:<24} {state:<10} position: {d['position'] or '-'}{lat}")
    for f in r["nearby_unpaired"]:
        print(f"  {f['name']:<24} nearby, not paired (connect: maclinker connect {f['host']}:{f['port']})")
    if r.get("pairing"):
        print(f"\nPairing with {r['pairing']['name']}: code {r['pairing']['code']}  ->  maclinker confirm | reject")
    for t in r.get("transfers", []):
        print(f"  file: {t[0]} {t[1]} ({t[2]})")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="maclinker", description="Share keyboard, mouse, clipboard and files with MacLinker on macOS.")
    ap.add_argument("--version", action="version", version=f"maclinker {__version__}")
    sub = ap.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="start the daemon (default)")
    run.add_argument("--port", type=int, default=DEFAULT_PORT)
    run.add_argument("--no-discovery", action="store_true", help="don't use mDNS/Bonjour")
    run.add_argument("--no-capture", action="store_true", help="don't read local keyboard/mouse (this machine can only be controlled)")
    run.add_argument("--no-swap-modifiers", action="store_true", help="don't swap Ctrl<->Cmd, Alt<->Option, Super<->Control")
    run.add_argument("--mouse-speed", type=float, default=1.0, help="scale this machine's mouse motion on the Mac")
    run.add_argument("--edge-push", type=float, default=12.0, help="pixels of pressure needed at a screen edge")
    run.add_argument("--scroll-invert", action="store_true")
    run.add_argument("-v", "--verbose", action="store_true")

    sub.add_parser("status", help="show devices and connection state")
    sub.add_parser("confirm", help="confirm the pairing code shown on both screens")
    sub.add_parser("reject", help="reject a pairing request")
    c = sub.add_parser("connect", help="connect to a Mac by address"); c.add_argument("host", help="HOST or HOST:PORT")
    s = sub.add_parser("send", help="send a file to a connected Mac"); s.add_argument("path"); s.add_argument("--to")
    pos = sub.add_parser("position", help="set where a paired Mac sits relative to this screen")
    pos.add_argument("device"); pos.add_argument("edge", help="left | right | top | bottom | none")
    sub.add_parser("toggle", help="switch control to/from the Mac (same as the hotkey)")
    f = sub.add_parser("forget", help="unpair a device"); f.add_argument("device")
    sub.add_parser("setup", help="print the one-time permissions setup")

    args = ap.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "setup":
        print(SETUP_TEXT)
        return 0
    if cmd == "run":
        verbose = getattr(args, "verbose", False)
        logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO,
                            format="%(asctime)s %(levelname)s %(name)s: %(message)s")
        from .app import App
        opts = vars(args)
        app = App(port=opts.get("port", DEFAULT_PORT), discovery=not opts.get("no_discovery", False),
                  swap_modifiers=not opts.get("no_swap_modifiers", False), mouse_speed=opts.get("mouse_speed", 1.0),
                  edge_push=opts.get("edge_push", 12.0), scroll_invert=opts.get("scroll_invert", False),
                  capture=not opts.get("no_capture", False))
        try:
            asyncio.run(app.run())
        except KeyboardInterrupt:
            pass
        return 0

    if cmd == "status":
        r = ctl({"cmd": "status"})
        if not r.get("ok"):
            return show(r)
        print_status(r)
        return 0
    payload = {"cmd": cmd}
    if cmd == "connect":
        payload["host"] = args.host
    elif cmd == "send":
        payload.update(path=str(Path(args.path).resolve()), to=args.to)
    elif cmd == "position":
        payload.update(device=args.device, edge=args.edge)
    elif cmd == "forget":
        payload["device"] = args.device
    return show(ctl(payload))


if __name__ == "__main__":
    sys.exit(main())
