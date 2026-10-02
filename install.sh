#!/bin/bash
# Install (or upgrade) Porthole for the current user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="io.github.fatihaydost.porthole"

if ! command -v kpackagetool6 >/dev/null; then
    echo "kpackagetool6 not found: Porthole needs KDE Plasma 6." >&2
    exit 1
fi

missing=()
for c in ssh systemd-run systemctl journalctl ss; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if (( ${#missing[@]} )); then
    echo "Warning: not found on PATH: ${missing[*]}" >&2
    echo "Porthole runs tunnels as systemd user services and needs the OpenSSH client and iproute2 (ss)." >&2
fi

upgraded=0
if kpackagetool6 --type Plasma/Applet --show "$ID" >/dev/null 2>&1; then
    echo "Upgrading $ID ..."
    kpackagetool6 --type Plasma/Applet --upgrade "$ROOT/package"
    upgraded=1
else
    echo "Installing $ID ..."
    kpackagetool6 --type Plasma/Applet --install "$ROOT/package"
fi

echo
echo "Done. Porthole shows up in the system tray. If it does not:"
echo "  right-click the tray arrow -> Configure System Tray... -> Entries -> Porthole -> Always shown"
echo

# Plasma loads an applet's QML once and keeps it for the life of the shell, so
# a widget already in the tray goes on running the old code until Plasma
# restarts. Tunnels are systemd units and keep running through the restart.
if [[ "${1:-}" == "--reload" ]]; then
    echo "Restarting Plasma so the tray picks up the new code ..."
    if systemctl --user is-active --quiet plasma-plasmashell.service; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null || true
        sleep 1
        setsid plasmashell >/dev/null 2>&1 < /dev/null &
    fi
    echo "Done."
elif (( upgraded )); then
    echo "A Porthole already in your tray is still running the old code."
    echo "Restart Plasma to pick this up  ->  ./install.sh --reload"
    echo "                              or  ->  systemctl --user restart plasma-plasmashell.service"
fi
