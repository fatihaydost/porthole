#!/bin/bash
# End-to-end test: a throwaway user-level sshd on 127.0.0.1:2222, two HTTP
# servers behind it, then tests/harness.py drives Service.qml through real
# tunnels (systemd-run --user units named porthole-*).
#
# Touches nothing outside a temp dir and the porthole-* units it creates: its own host keys, its own
# client key and authorized_keys (your ~/.ssh keys and agent are not used), its own known_hosts
# files, and XDG_CONFIG_HOME=<tmp>/config for the store.
# Needs: sshd, python3 + PyQt6, socat, curl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d /tmp/porthole-e2e.XXXXXX)"
pids=()

# Units that exist before the run (the user's own tunnels) are left alone.
before=" $(systemctl --user list-units --all --plain --no-legend 'porthole-*' | awk '{print $1}' | tr '\n' ' ') "

cleanup() {
    for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done
    for u in $(systemctl --user list-units --all --plain --no-legend 'porthole-*' | awk '{print $1}'); do
        [[ "$before" == *" $u "* ]] && continue
        systemctl --user stop "$u" 2>/dev/null || true
        systemctl --user reset-failed "$u" 2>/dev/null || true
    done
    rm -rf "$T"
}
trap cleanup EXIT

for port in 2222 2223 8765 8766 18765 18766 18767 18768 18769 18770 18780 18790 18791 18795 18797 18850 18851 18852 18853; do
    if ss -Hltn | grep -q ":$port "; then echo "port $port is busy" >&2; exit 2; fi
done

ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$T/otherhostkey"
ssh-keygen -q -t ed25519 -N '' -f "$T/unauthorized_key"
ssh-keygen -q -t ed25519 -N '' -f "$T/client_key"
cp "$T/client_key.pub" "$T/authorized_keys"
cat > "$T/sshd_config" <<EOF
ListenAddress 127.0.0.1
HostKey $T/hostkey
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding yes
PermitTTY no
EOF
: > "$T/known_hosts"
echo "[127.0.0.1]:2222 $(cut -d' ' -f1,2 "$T/otherhostkey.pub")" > "$T/known_hosts_bad"
# Tailscale SSH check mode, simulated: print the approval URL, stall, connect.
cat > "$T/fake-tailscale.sh" <<'EOF'
#!/bin/bash
echo "To authenticate, visit: https://login.tailscale.com/a/plasmapftest123" >&2
sleep 6
exec socat - TCP:127.0.0.1:2222
EOF
chmod +x "$T/fake-tailscale.sh"
mkdir -p "$T/www-a" "$T/www-b"
echo "TUNNEL-A $(date +%s)" > "$T/www-a/index.html"
echo "TUNNEL-B $(date +%s)" > "$T/www-b/index.html"

/usr/bin/sshd -D -f "$T/sshd_config" -p 2222 -E "$T/sshd.log" < /dev/null &
pids+=($!)
(cd "$T/www-a" && exec python3 -m http.server 8765 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1) &
pids+=($!)
(cd "$T/www-b" && exec python3 -m http.server 8766 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1) &
pids+=($!)
# Local ports section: servers of our own, one on loopback, one on every
# interface, one to stop, one that ignores SIGTERM (needs SIGKILL).
mkdir -p "$T/lp-loop" "$T/lp-lan" "$T/lp-stop" "$T/lp-stubborn"
(cd "$T/lp-loop" && exec python3 -m http.server 18850 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1) &
pids+=($!)
(cd "$T/lp-lan" && exec python3 -m http.server 18851 --bind 0.0.0.0 < /dev/null > /dev/null 2>&1) &
pids+=($!)
(cd "$T/lp-stop" && exec python3 -m http.server 18852 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1) &
pids+=($!)
cat > "$T/lp-stubborn/stubborn.py" <<'EOF'
import signal, socket, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 18853))
s.listen()
time.sleep(600)
EOF
(cd "$T/lp-stubborn" && exec python3 stubborn.py < /dev/null > /dev/null 2>&1) &
pids+=($!)

# Another program on 127.0.0.1:18780 only: the tunnel there gets ::1 and the
# widget has to say the port is shared.
python3 -m http.server 18780 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1 &
pids+=($!)
# Bind addresses: the tunnels take 127.0.1.1 and 127.0.1.2 on 18795, a server
# of ours sits on 127.0.1.3 of the same port (Local ports must list it, and
# only it); another program holds 127.0.0.1:18797.
mkdir -p "$T/lp-bind"
(cd "$T/lp-bind" && exec python3 -m http.server 18795 --bind 127.0.1.3 < /dev/null > /dev/null 2>&1) &
pids+=($!)
python3 -m http.server 18797 --bind 127.0.0.1 < /dev/null > /dev/null 2>&1 &
pids+=($!)
sleep 1.5
# no "Killed" job notices when the servers are stopped (some by the test itself)
disown -a

QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen python3 "$HERE/harness.py" "$T" 2>&1 | sed -n 's/^qml: //p'
exit "${PIPESTATUS[0]}"
