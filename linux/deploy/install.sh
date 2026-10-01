#!/bin/bash
# Installs MacLinker for the current user: a private virtualenv, the udev rule for uinput, and a systemd user service.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/.local/share/maclinker"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --upgrade pip >/dev/null
"$DEST/venv/bin/pip" install ".[x11]" || "$DEST/venv/bin/pip" install .
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
ln -sf "$DEST/venv/bin/maclinker" "$HOME/.local/bin/maclinker"
cp deploy/maclinker.service "$HOME/.config/systemd/user/"

echo
echo "Next, grant device access once (needs sudo):"
sed -n '/^One-time setup/,/^Optional/p' <("$DEST/venv/bin/maclinker" setup) | sed '$d'
echo "Then:  systemctl --user enable --now maclinker   and   maclinker status"
echo "Make sure ~/.local/bin is in your PATH."
