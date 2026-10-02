.pragma library

/*
 * Pure helpers for Porthole: definition normalisation, the ssh
 * command line, and the shell scripts that run the tunnels and poll their
 * state. Nothing in here touches QML or i18n, so it can be unit tested with
 * node (see tests/logic.test.js).
 *
 * Copyright notices: see LICENSE.
 */

var UNIT_PREFIX = "porthole-";

// Every script runs under the C locale: under tr_TR, for one, awk's
// tolower("Include") is "ınclude" and grep -i stops matching I to i.
var C_LOCALE = "export LC_ALL=C; ";

// Resolves the store path inside every script that needs it.
var CONFIG_SHELL = 'cfg="${XDG_CONFIG_HOME:-$HOME/.config}/porthole/forwards.json"; ';
var CONFIG_DISPLAY = "~/.config/porthole/forwards.json";

// POSIX single-quote escaping: wrap in '…', turn every ' into '\''.
function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function genId(counter) {
    return "f" + Date.now().toString(36) + Number(counter || 0).toString(36);
}

var KNOWN_FIELDS = ["id", "label", "localPort", "sshTarget", "remoteHost", "remotePort", "autostart", "extraOptions"];

// Small stable string hash (FNV-1a, 32 bit) for ids of hand-written entries.
function hashString(text) {
    var h = 0x811c9dc5;
    for (var i = 0; i < text.length; i++) {
        h ^= text.charCodeAt(i);
        h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return h.toString(36);
}

// Same rules as the original: a forward needs a positive local port and an
// ssh target, everything else falls back to a default. Ids travel through the
// space and pipe separated poll protocol, so they are kept to safe characters.
// A target starting with "-" would be read by ssh as an option: refused.
// `makeId` is called only when the stored id is missing or empty.
function normalizeForward(raw, makeId) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var lp = parseInt(raw.localPort, 10);
    if (!isFinite(lp) || lp <= 0 || lp > 65535)
        return null;
    var target = String(raw.sshTarget || "").trim();
    if (target === "" || target.charAt(0) === "-")
        return null;
    var rp = parseInt(raw.remotePort, 10);
    if (!isFinite(rp) || rp <= 0 || rp > 65535)
        rp = lp;
    var id = String(raw.id || "").trim().replace(/[^A-Za-z0-9._-]/g, "_");
    return {
        id: id || makeId(),
        label: String(raw.label || "").trim(),
        localPort: lp,
        sshTarget: target,
        remoteHost: String(raw.remoteHost || "").trim() || "localhost",
        remotePort: rp,
        autostart: raw.autostart === true,
        extraOptions: String(raw.extraOptions || "").trim()
    };
}

// Parses the store without ever losing what the user wrote:
//  - `ok` is false when the text is not JSON, or not an object, or has a
//    "forwards" that is not a list. The caller then refuses to save.
//  - entries that do not validate are kept verbatim in `invalid` (with their
//    position) and written back by serializeStore;
//  - unknown fields of valid entries are kept in `extras` (by id), unknown
//    top-level keys in `top`.
//  - an entry without an id gets one derived from its content, so it is the
//    same on every load and nothing has to be written back.
function parseStore(text) {
    var raw = String(text || "").trim();
    var result = { ok: true, error: "", forwards: [], extras: {}, invalid: [], top: {} };
    if (raw === "")
        return result;
    var parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (e) {
        result.ok = false;
        result.error = String(e && e.message ? e.message : e);
        return result;
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        result.ok = false;
        result.error = "the file is not a JSON object";
        return result;
    }
    if (parsed.forwards !== undefined && !Array.isArray(parsed.forwards)) {
        result.ok = false;
        result.error = "\"forwards\" is not a list";
        return result;
    }
    for (var key in parsed)
        if (key !== "forwards")
            result.top[key] = parsed[key];
    var list = parsed.forwards || [];
    var seenUnits = {};
    for (var i = 0; i < list.length; i++) {
        var entry = list[i];
        var n = normalizeForward(entry, function () {
            return "h" + hashString([entry.localPort, entry.sshTarget, entry.remoteHost, entry.remotePort, entry.label].join("|"));
        });
        if (!n) {
            result.invalid.push({ index: i, raw: entry });
            continue;
        }
        // Two entries on one systemd unit ("a.b" and "a_b" included): the
        // later one gets a suffix, the same one on every load.
        var base = n.id;
        for (var k = 2; seenUnits[unitName(n.id)]; k++)
            n.id = base + "-" + k;
        seenUnits[unitName(n.id)] = true;
        var extra = {};
        var hasExtra = false;
        for (var f in entry) {
            if (KNOWN_FIELDS.indexOf(f) < 0) {
                extra[f] = entry[f];
                hasExtra = true;
            }
        }
        if (hasExtra)
            result.extras[n.id] = extra;
        result.forwards.push(n);
    }
    return result;
}

// Writes the forwards back with everything parseStore kept aside: unknown
// fields, unreadable entries at their old positions, unknown top-level keys.
function serializeStore(forwards, extras, invalid, top) {
    var list = [];
    for (var i = 0; i < forwards.length; i++) {
        var f = forwards[i];
        var item = {};
        for (var k = 0; k < KNOWN_FIELDS.length; k++)
            item[KNOWN_FIELDS[k]] = f[KNOWN_FIELDS[k]];
        var extra = (extras || {})[f.id];
        for (var key in extra)
            if (KNOWN_FIELDS.indexOf(key) < 0)
                item[key] = extra[key];
        list.push(item);
    }
    var kept = (invalid || []).slice().sort(function (a, b) { return a.index - b.index; });
    for (var j = 0; j < kept.length; j++)
        list.splice(Math.min(kept[j].index, list.length), 0, kept[j].raw);
    var out = { version: 1 };
    for (var t in (top || {}))
        if (t !== "forwards")
            out[t] = top[t];
    out.forwards = list;
    return JSON.stringify(out, null, 2) + "\n";
}

// Text for a rich-text-capable label (Kirigami.InlineMessage renders with
// AutoText): every character shown literally, nothing fetched or styled.
function richEscape(text) {
    return "<p>" + String(text === undefined || text === null ? "" : text)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;").replace(/\n/g, "<br/>") + "</p>";
}

function forwardTitle(f) {
    if (!f)
        return "";
    if (f.label && f.label !== "")
        return f.label;
    return f.localPort + " → " + f.sshTarget;
}

function localAddress(f) {
    return f ? "localhost:" + f.localPort : "";
}

function remoteAddress(f) {
    return f ? (f.remoteHost || "localhost") + ":" + f.remotePort : "";
}

function unitName(id) {
    return UNIT_PREFIX + String(id).replace(/[^A-Za-z0-9_-]/g, "_");
}

// The ssh argument vector, flag for flag the original's.
function forwardCommand(f, trustHostKey) {
    var rh = (f.remoteHost && String(f.remoteHost).length) ? String(f.remoteHost) : "localhost";
    var spec = f.localPort + ":" + rh + ":" + f.remotePort;
    var cmd = ["ssh", "-N", "-T",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=10",
        "-L", spec];
    // One-shot opt-in from "Trust host key & retry". accept-new records an
    // unknown host but still fails hard when a known key has CHANGED.
    if (trustHostKey === true)
        cmd.push("-o", "StrictHostKeyChecking=accept-new");
    var extra = String(f.extraOptions || "").trim();
    if (extra !== "") {
        var parts = extra.split(/\s+/);
        for (var i = 0; i < parts.length; i++)
            if (parts[i] !== "")
                cmd.push(parts[i]);
    }
    // End of options: the target is never read as a flag.
    cmd.push("--", String(f.sshTarget));
    return cmd;
}

// Finds an ssh agent for the unit. The user manager often lacks
// SSH_AUTH_SOCK, so try in order and take the first live socket: the
// manager's environment, the one plasmashell passed down (plasma-workspace
// env scripts), OpenSSH's ssh-agent.socket, GNOME Keyring, gpg-agent.
var AGENT_SHELL =
    'sock=$(systemctl --user show-environment 2>/dev/null | sed -n "s/^SSH_AUTH_SOCK=//p" | tail -n 1); ' +
    '[ -n "$sock" ] && [ -S "$sock" ] || sock=""; ' +
    'if [ -z "$sock" ] && [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then sock="$SSH_AUTH_SOCK"; fi; ' +
    'if [ -z "$sock" ] && [ -n "$XDG_RUNTIME_DIR" ] && [ -S "$XDG_RUNTIME_DIR/ssh-agent.socket" ]; then sock="$XDG_RUNTIME_DIR/ssh-agent.socket"; fi; ' +
    'if [ -z "$sock" ] && [ -n "$XDG_RUNTIME_DIR" ] && [ -S "$XDG_RUNTIME_DIR/gcr/ssh" ]; then sock="$XDG_RUNTIME_DIR/gcr/ssh"; fi; ' +
    'if [ -z "$sock" ] && command -v gpgconf >/dev/null 2>&1; then g=$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null); if [ -n "$g" ] && [ -S "$g" ]; then sock="$g"; fi; fi; ';

// One sequenced script: stop every unit that may hold the port (the forward's
// own unit plus `otherUnits`, the active forwards on the same local port),
// wait up to 4 s for the port to free, then start the tunnel as a fresh
// transient unit. Running it as one command is what keeps restarts and port
// bouncing free of races. No --collect: a failed unit has to stay around long
// enough for the poll to read its journal; reset-failed cleans it up.
function startScript(f, otherUnits, trustHostKey, description) {
    var unit = unitName(f.id);
    var units = [shellQuote(unit)];
    for (var i = 0; i < (otherUnits || []).length; i++)
        units.push(shellQuote(otherUnits[i]));
    var q = units.join(" ");
    var ssh = forwardCommand(f, trustHostKey === true).map(shellQuote).join(" ");
    // One unit per systemctl call: with several names, current systemd
    // refuses the whole job when any of them is not loaded (the forward's own
    // unit usually is not), and nothing would be stopped.
    return C_LOCALE
        + "for u in " + q + "; do systemctl --user stop \"$u\" 2>/dev/null; systemctl --user reset-failed \"$u\" 2>/dev/null; done; "
        + "for i in $(seq 1 40); do ss -Hltn 2>/dev/null | grep -q ':" + parseInt(f.localPort, 10) + " ' || break; sleep 0.1; done; "
        + AGENT_SHELL
        + "exec systemd-run --user --unit=" + shellQuote(unit)
        + " --description=" + shellQuote(description)
        + ' ${sock:+"--setenv=SSH_AUTH_SOCK=$sock"}'
        + " -- " + ssh;
}

function stopScript(id) {
    var unit = shellQuote(unitName(id));
    return "systemctl --user stop " + unit + " 2>/dev/null; "
        + "systemctl --user reset-failed " + unit + " 2>/dev/null; true";
}

// One round trip for every forward: systemd state, who listens on the local
// port, and for failed units a base64 error line plus a host key
// classification, for running-but-not-listening units any approval URL ssh
// printed. Journal reads are scoped to the unit's current invocation so an
// old error or URL never comes back, and skipped when the caller already
// holds the error of that invocation (`cachedInvocations`, id -> id string):
// the column then reads "=".
// "listen" is "yes" when the unit's own ssh (MainPID) listens on the port and
// nobody else does, "shared" when another program listens on it as well (ssh
// got ::1 but 127.0.0.1 was taken, say), "no" otherwise.
// Output per forward: id state listen msg hk url invocation ("-" = empty).
// A last "@cfg" line carries the store's mtime/size/inode so hand edits are
// picked up without reopening the popup.
function pollScript(forwards, cachedInvocations) {
    var script = C_LOCALE + CONFIG_SHELL;
    var cache = cachedInvocations || {};
    var specs = [];
    for (var i = 0; i < forwards.length; i++) {
        var id = forwards[i].id;
        specs.push(shellQuote(id + "|" + unitName(id) + "|" + forwards[i].localPort + "|" + (cache[id] || "")));
    }
    if (specs.length > 0) {
        script +=
            'listening=$(ss -Hltnp 2>/dev/null); ' +
            'for e in ' + specs.join(" ") + '; do ' +
            'IFS="|" read -r id unit port cinv <<< "$e"; ' +
            'state=$(systemctl --user is-active "$unit" 2>/dev/null); ' +
            'inv=$(systemctl --user show -p InvocationID --value "$unit" 2>/dev/null); ' +
            'pid=$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null); ' +
            'mine=no; other=no; ' +
            'while IFS= read -r l; do [ -z "$l" ] && continue; ' +
            'if [ "${pid:-0}" != 0 ] && [[ "$l" == *"pid=$pid,"* ]]; then mine=yes; else other=yes; fi; ' +
            'done <<< "$(printf "%s\\n" "$listening" | grep ":$port ")"; ' +
            'listen=no; [ $mine = yes ] && listen=yes; [ $mine = yes ] && [ $other = yes ] && listen=shared; ' +
            'msg=-; hk=-; url=-; ' +
            'if [ "$state" = failed ] && [ -n "$inv" ] && [ "$inv" = "$cinv" ]; then msg="="; hk="="; ' +
            'elif [ "$state" = failed ]; then ' +
            'j=$(journalctl --user -u "$unit" ${inv:+_SYSTEMD_INVOCATION_ID=$inv} --no-pager -n 200 -o cat 2>/dev/null); ' +
            'if printf %s "$j" | grep -q "IDENTIFICATION HAS CHANGED"; then hk=changed; ' +
            'elif printf %s "$j" | grep -qi "host key verification failed"; then hk=new; fi; ' +
            'm=$(printf %s "$j" | grep -iE "ssh:|bind|cannot|denied|refused|timed out|could not|already in use|forbidden|no route|host key|authentication" | tail -1 | base64 -w0); ' +
            '[ -n "$m" ] && msg=$m; ' +
            'elif [ "$state" = active ] && [ "$listen" = no ]; then ' +
            'u=$(journalctl --user -u "$unit" ${inv:+_SYSTEMD_INVOCATION_ID=$inv} --no-pager -o cat 2>/dev/null | grep -oE "https://login[.]tailscale[.]com/[A-Za-z0-9/_.-]+" | tail -1); ' +
            '[ -n "$u" ] && url=$u; ' +
            'fi; ' +
            'echo "$id ${state:-unknown} $listen $msg $hk $url ${inv:--}"; ' +
            'done; ';
    }
    script += 'echo "@cfg $(stat -L -c "%Y.%s.%i" -- "$cfg" 2>/dev/null || echo none)"';
    return script;
}

// Parses the poll output into rows and the store signature.
function parsePoll(text) {
    var lines = String(text || "").split("\n");
    var rows = [];
    var cfg = "";
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line === "")
            continue;
        var parts = line.split(" ");
        if (parts[0] === "@cfg") {
            cfg = parts[1] || "";
            continue;
        }
        var cached = parts[3] === "=";
        rows.push({
            id: parts[0],
            state: parts[1] || "unknown",
            listen: parts[2] === "yes" || parts[2] === "shared" ? parts[2] : "no",
            cached: cached,
            msg: (!cached && parts[3] && parts[3] !== "-") ? decodeBase64Utf8(parts[3]) : "",
            hostKey: (!cached && parts[4] && parts[4] !== "-") ? parts[4] : "",
            url: (parts[5] && parts[5] !== "-") ? parts[5] : "",
            invocation: (parts[6] && parts[6] !== "-") ? parts[6] : ""
        });
    }
    return { rows: rows, cfg: cfg };
}

// systemd state + listening port + approval URL -> widget status.
function deriveStatus(row) {
    if (row.state === "active") {
        if (row.listen === "yes" || row.listen === "shared")
            return "active";
        if (row.url !== "")
            return "auth"; // ssh is waiting on out-of-band approval
        return "connecting";
    }
    if (row.state === "activating" || row.state === "reloading")
        return "connecting";
    if (row.state === "failed")
        return "error";
    return "inactive";
}

// Which message an error row should show. The caller maps the kind to a
// translated string; "raw" means show `msg` as is.
function errorKind(hostKey, msg) {
    if (hostKey === "changed")
        return "hostkey-changed";
    if (hostKey === "new")
        return "hostkey-new";
    if (/Permission denied \(publickey/i.test(msg || ""))
        return "publickey";
    if (msg && msg !== "")
        return "raw";
    return "generic";
}

var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// base64 -> UTF-8 text. Qt.atob() is Latin-1 only, and ssh output can carry
// any bytes from the remote side, so decode by hand.
function decodeBase64Utf8(input) {
    var s = String(input || "").replace(/[^A-Za-z0-9+/]/g, "");
    var bytes = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < s.length; i++) {
        buffer = (buffer << 6) | B64.indexOf(s.charAt(i));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes.push((buffer >> bits) & 0xff);
        }
    }
    var out = "";
    for (var j = 0; j < bytes.length;) {
        var b = bytes[j++];
        var cp;
        if (b < 0x80) {
            cp = b;
        } else if (b >= 0xc0 && b < 0xe0 && j < bytes.length) {
            cp = ((b & 0x1f) << 6) | (bytes[j++] & 0x3f);
        } else if (b >= 0xe0 && b < 0xf0 && j + 1 < bytes.length) {
            cp = ((b & 0x0f) << 12) | ((bytes[j++] & 0x3f) << 6) | (bytes[j++] & 0x3f);
        } else if (b >= 0xf0 && j + 2 < bytes.length) {
            cp = ((b & 0x07) << 18) | ((bytes[j++] & 0x3f) << 12) | ((bytes[j++] & 0x3f) << 6) | (bytes[j++] & 0x3f);
        } else {
            cp = 0xfffd;
        }
        if (cp > 0xffff) {
            cp -= 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        } else {
            out += String.fromCharCode(cp);
        }
    }
    return out.replace(/[\r\n]+$/, "");
}

// Reads the store; exit code 3 means the file does not exist yet.
function readStoreScript() {
    return CONFIG_SHELL + 'if [ -e "$cfg" ]; then cat -- "$cfg"; else exit 3; fi';
}

// Atomic write: a temp file next to the real file (a symlinked store, as
// dotfile managers make, is followed, not replaced), same mode as before,
// then rename over. Prints the new mtime/size/inode signature.
function writeStoreScript(content) {
    return CONFIG_SHELL
        + 'if [ -L "$cfg" ]; then cfg=$(readlink -f -- "$cfg") || exit 1; fi; '
        + 'd=$(dirname -- "$cfg"); mkdir -p -- "$d" || exit 1; '
        + 't=$(mktemp "$d/.forwards.json.XXXXXX") || exit 1; '
        + 'if [ -e "$cfg" ]; then chmod --reference="$cfg" -- "$t"; else chmod "$(printf %o $(( 0666 & ~0$(umask) )))" -- "$t"; fi; '
        + "printf '%s' " + shellQuote(content) + ' > "$t" && '
        + 'mv -f -- "$t" "$cfg" || { rm -f -- "$t"; exit 1; }; '
        + 'stat -c "%Y.%s.%i" -- "$cfg"';
}

// Prints ~/.ssh/config plus the files its Include lines name (one level,
// globs expanded by the shell, never eval'd).
function sshConfigScript() {
    return C_LOCALE + 'f="$HOME/.ssh/config"; [ -r "$f" ] || exit 0; cat -- "$f"; echo; '
        + 'awk \'tolower($1)=="include"{for(i=2;i<=NF;i++)print $i}\' "$f" | while IFS= read -r inc; do '
        + 'case "$inc" in "~"/*) inc="$HOME/${inc#"~/"}";; /*) ;; *) inc="$HOME/.ssh/$inc";; esac; '
        + 'for g in $inc; do [ -f "$g" ] && [ -r "$g" ] && { cat -- "$g"; echo; }; done; done';
}

// Host aliases from ssh_config text: every name on a Host line that is not a
// pattern (*, ?, negation).
function parseSshHosts(text) {
    var hosts = [];
    var seen = {};
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/#.*$/, "").trim();
        var m = /^host(?:\s*=\s*|\s+)(.*)$/i.exec(line);
        if (!m)
            continue;
        var names = m[1].split(/\s+/);
        for (var k = 0; k < names.length; k++) {
            var name = names[k].replace(/^"(.*)"$/, "$1");
            if (name === "" || /[*?!<>&"'`]/.test(name) || seen[name])
                continue;
            seen[name] = true;
            hosts.push(name);
        }
    }
    return hosts;
}

// Prints the names of missing requirements, space separated.
function dependencyScript() {
    return 'miss=""; for c in ssh systemd-run systemctl journalctl ss; do '
        + 'command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done; '
        + 'if command -v systemctl >/dev/null 2>&1 && ! systemctl --user show-environment >/dev/null 2>&1; then miss="$miss systemd-user"; fi; '
        + 'echo $miss';
}

// --- local ports -------------------------------------------------------------
//
// Everything listening on TCP on this machine, for the "Local ports" section.
// One script prints:
//   @home <base64 $HOME>
//   @l <ss -Hltnp line>                         for every listener
//   @p <pid> <tunnel> <ppid> <start> <cmd> <cwd> <repo>
//                                               for every pid ss could show
//                                               (cmd: base64 of NUL-split args,
//                                               cwd: base64, "-" when unreadable,
//                                               repo: base64 of the nearest
//                                               folder above cwd holding .git,
//                                               below $HOME or /, "-" for none,
//                                               tunnel: yes when the process
//                                               sits in a porthole-*.service)
//   @docker <base64 of `docker ps` names/ports>, only when docker answers
//   @dockerdenied, when the Docker socket exists but this user cannot write to it

function localPortsScript() {
    return C_LOCALE
        + 'echo "@home $(printf %s "$HOME" | base64 -w0)"; '
        + 'out=$(ss -Hltnp 2>/dev/null); '
        + 'printf "%s\\n" "$out" | sed -n "s/^/@l /p"; '
        + 'for p in $(printf "%s\\n" "$out" | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -un); do '
        + '[ -r "/proc/$p/stat" ] || continue; '
        + 's=$(sed "s/^.*) //" "/proc/$p/stat" 2>/dev/null); set -- $s; '
        + 'ppid=${2:-0}; start=${20:-0}; '
        + 'tun=no; grep -q "/porthole-[^/]*\\.service" "/proc/$p/cgroup" 2>/dev/null && tun=yes; '
        + 'cmd=$(tr "\\0" "\\n" < "/proc/$p/cmdline" 2>/dev/null | base64 -w0); '
        + 'c=$(readlink "/proc/$p/cwd" 2>/dev/null); r=""; d="$c"; '
        + 'while [ -n "$d" ] && [ "$d" != / ] && [ "$d" != "$HOME" ]; do [ -e "$d/.git" ] && { r="$d"; break; }; d="${d%/*}"; done; '
        + 'cwd=$(printf %s "$c" | base64 -w0); repo=$(printf %s "$r" | base64 -w0); '
        + 'echo "@p $p $tun $ppid $start ${cmd:--} ${cwd:--} ${repo:--}"; '
        + 'done; '
        + 'if command -v docker >/dev/null 2>&1; then '
        + 'd=$(timeout 2 docker ps --format "{{.Names}}\\t{{.Ports}}" 2>/dev/null) && echo "@docker $(printf %s "$d" | base64 -w0)"; '
        + '[ -S /var/run/docker.sock ] && [ ! -w /var/run/docker.sock ] && echo "@dockerdenied"; '
        + 'fi; true';
}

// Splits an ss address column ("127.0.0.1:5180", "[::1]:631", "*:3000",
// "127.0.0.53%lo:53", "[fe80::1%wlan0]:22") into host and port.
function splitAddress(text) {
    var s = String(text || "");
    var colon = s.lastIndexOf(":");
    if (colon < 0)
        return null;
    var port = parseInt(s.slice(colon + 1), 10);
    if (!isFinite(port))
        return null;
    var host = s.slice(0, colon);
    if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]")
        host = host.slice(1, -1);
    var pct = host.indexOf("%");
    if (pct >= 0)
        host = host.slice(0, pct);
    return { host: host, port: port };
}

// "loopback", "all" (every interface: reachable from the network) or "lan"
// (one specific address).
function addressScope(host) {
    if (host === "*" || host === "0.0.0.0" || host === "::" || host === "")
        return "all";
    if (/^127\./.test(host) || host === "::1" || /^::ffff:127\./i.test(host))
        return "loopback";
    return "lan";
}

var SCOPE_RANK = { loopback: 0, lan: 1, all: 2 };

// One ss -Hltn(p) line -> {host, port, scope, procs: [{name, pid}]}.
function parseSsLine(line) {
    var cols = String(line || "").trim().split(/\s+/);
    if (cols.length < 5 || cols[0] !== "LISTEN")
        return null;
    var addr = splitAddress(cols[3]);
    if (!addr)
        return null;
    var procs = [];
    var re = /\("((?:[^"\\]|\\.)*)",pid=(\d+),fd=\d+\)/g;
    var m;
    var rest = cols.slice(5).join(" ");
    while ((m = re.exec(rest)) !== null)
        procs.push({ name: m[1], pid: parseInt(m[2], 10) });
    return { host: addr.host, port: addr.port, scope: addressScope(addr.host), procs: procs };
}

function baseName(path) {
    var s = String(path || "").replace(/\/+$/, "");
    return s.slice(s.lastIndexOf("/") + 1);
}

// A readable name for a listening process, from its argv and its comm.
// `dev` is true when a rule recognised it (a dev server or a known service).
function processLabel(args, comm) {
    var a = (args || []).filter(function (x) { return x !== ""; });
    var exe = baseName(a[0] || comm || "");
    var joined = a.join(" ");
    var after = function (flag) {
        var i = a.indexOf(flag);
        return i >= 0 && i + 1 < a.length ? a[i + 1] : "";
    };
    var named = function (label) { return { name: label, dev: true }; };
    // Paths come in many shapes: node_modules/.bin/vite,
    // node_modules/.bin/../vite/bin/vite.js, .pnpm/vite@5/node_modules/vite/bin/vite.js
    var anyArg = function (re) { return a.some(function (x) { return re.test(x); }); };
    if (anyArg(/(^|\/)vite$/) || anyArg(/(^|\/)vite\/bin\/vite\.m?js$/))
        return named("Vite");
    if (/^next-server/.test(comm || "") || /(^|\/)next-server\b/.test(joined) || anyArg(/(^|\/)next\/dist\/bin\/next$/)
            || (anyArg(/(^|\/)next$/) && /\b(dev|start)\b/.test(joined)))
        return named("Next.js");
    if (/^python[0-9.]*$/.test(exe)) {
        var mod = after("-m");
        if (mod === "http.server")
            return named("Python http.server");
        if (mod === "uvicorn")
            return named("Uvicorn");
        if (mod === "gunicorn")
            return named("Gunicorn");
        if (mod === "flask")
            return named("Flask");
        if (/manage\.py$/.test(a[1] || "") && a.indexOf("runserver") >= 0)
            return named("Django");
        var script = a.slice(1).filter(function (x) { return x.charAt(0) !== "-"; })[0];
        if (mod !== "")
            return named("Python " + mod);
        if (script)
            return named("Python " + baseName(script));
        return named("Python");
    }
    var known = {
        "uvicorn": "Uvicorn", "gunicorn": "Gunicorn", "flask": "Flask", "docker-proxy": "Docker",
        "postgres": "PostgreSQL", "postmaster": "PostgreSQL", "redis-server": "Redis", "mysqld": "MySQL",
        "mariadbd": "MariaDB", "mongod": "MongoDB", "nginx": "nginx", "caddy": "Caddy", "hugo": "Hugo",
        "jekyll": "Jekyll", "rails": "Rails", "puma": "Puma", "memcached": "Memcached", "ollama": "Ollama"
    };
    if (known[exe])
        return named(known[exe]);
    if (/^php[0-9.]*$/.test(exe) && a.indexOf("-S") >= 0)
        return named("PHP server");
    if (exe === "node" || exe === "bun" || exe === "deno") {
        var runtime = exe === "node" ? "Node" : exe === "bun" ? "Bun" : "Deno";
        var target = a.slice(1).filter(function (x) { return x.charAt(0) !== "-" && x !== "run"; })[0];
        if (target) {
            var bin = /node_modules\/\.bin\/([^\/]+)$/.exec(target);
            return named(runtime + " " + (bin ? bin[1] : baseName(target)));
        }
        return named(runtime);
    }
    return { name: comm || exe || "?", dev: false };
}

// Folders under $HOME that hold one folder per project.
var PROJECT_DIRS = /^(projects?|projeler|code|src|dev|developer|repos?|git|workspace|work|sites)$/i;

// The project a process runs for: the git repository its working directory
// is in (`repo`, from localPortsScript), else X for ~/Projects/X/…, ~/code/X/…
// and the like, else the last folder of the working directory; nothing for
// $HOME or /.
function projectName(cwd, home, repo) {
    var c = String(cwd || "").replace(/\/+$/, "");
    var h = String(home || "").replace(/\/+$/, "");
    var r = String(repo || "").replace(/\/+$/, "");
    if (r !== "" && r !== h)
        return baseName(r);
    if (c === "" || c === h)
        return "";
    if (h !== "" && c.indexOf(h + "/") === 0) {
        var rel = c.slice(h.length + 1).split("/");
        if (rel.length >= 2 && PROJECT_DIRS.test(rel[0]))
            return rel[1];
    }
    return baseName(c);
}

// `docker ps --format '{{.Names}}\t{{.Ports}}'` -> {hostPort: containerName}.
function parseDockerPorts(text) {
    var map = {};
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var tab = lines[i].indexOf("\t");
        if (tab < 0)
            continue;
        var name = lines[i].slice(0, tab).trim();
        var re = /(?:(?:\[[^\]]*\]|[0-9.]+|::):)?(\d+)(?:-(\d+))?->\d+(?:-\d+)?\/tcp/g;
        var m;
        while ((m = re.exec(lines[i].slice(tab + 1))) !== null) {
            var from = parseInt(m[1], 10);
            var to = m[2] ? parseInt(m[2], 10) : from;
            for (var p = from; p <= to && p - from < 1024; p++)
                map[p] = name;
        }
    }
    return map;
}

// Whole poll output -> {entries, system, dockerDenied}: entries are the user's own
// processes and Docker containers, system the rest (other users' daemons and
// desktop services). Porthole's own tunnels are left out. Listeners of one
// process on several addresses of a port become one entry.
function parseLocalPorts(text) {
    var lines = String(text || "").split("\n");
    var home = "";
    var listeners = [];
    var procs = {};
    var docker = {};
    var dockerDenied = false;
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.indexOf("@home ") === 0) {
            home = decodeBase64Utf8(line.slice(6));
        } else if (line.indexOf("@l ") === 0) {
            var l = parseSsLine(line.slice(3));
            if (l)
                listeners.push(l);
        } else if (line.indexOf("@p ") === 0) {
            var f = line.split(" ");
            procs[f[1]] = {
                pid: parseInt(f[1], 10),
                tunnel: f[2] === "yes",
                ppid: parseInt(f[3], 10) || 0,
                start: f[4] || "0",
                args: f[5] && f[5] !== "-" ? decodeBase64Utf8(f[5]).split("\n") : [],
                cwd: f[6] && f[6] !== "-" ? decodeBase64Utf8(f[6]) : "",
                repo: f[7] && f[7] !== "-" ? decodeBase64Utf8(f[7]) : ""
            };
        } else if (line.indexOf("@docker ") === 0) {
            docker = parseDockerPorts(decodeBase64Utf8(line.slice(8)));
        } else if (line === "@dockerdenied") {
            dockerDenied = true;
        }
    }
    var groups = {};
    var order = [];
    for (var j = 0; j < listeners.length; j++) {
        var ls = listeners[j];
        var pids = ls.procs.map(function (p) { return p.pid; }).sort(function (a, b) { return a - b; });
        if (pids.some(function (p) { return procs[p] && procs[p].tunnel; }))
            continue; // one of Porthole's tunnels: shown above
        var key = "p" + ls.port + (pids.length ? "-" + pids.join("-") : "");
        var g = groups[key];
        if (!g) {
            g = groups[key] = { key: key, port: ls.port, hosts: [], scope: ls.scope, pids: pids, comm: ls.procs.length ? ls.procs[0].name : "" };
            order.push(key);
        }
        if (g.hosts.indexOf(ls.host) < 0)
            g.hosts.push(ls.host);
        if (SCOPE_RANK[ls.scope] > SCOPE_RANK[g.scope])
            g.scope = ls.scope;
    }
    var entries = [];
    var system = [];
    for (var k = 0; k < order.length; k++) {
        var e = groups[order[k]];
        // The listening pid that is not a child of another listener (a
        // pre-fork server's master, not one of its workers).
        var main = null;
        for (var q = 0; q < e.pids.length; q++) {
            var pr = procs[e.pids[q]];
            if (pr && e.pids.indexOf(pr.ppid) < 0) {
                main = pr;
                break;
            }
        }
        if (!main && e.pids.length && procs[e.pids[0]])
            main = procs[e.pids[0]];
        var label = main ? processLabel(main.args, e.comm) : { name: "", dev: false };
        var project = main ? projectName(main.cwd, home, main.repo) : "";
        var item = {
            key: e.key,
            port: e.port,
            hosts: e.hosts,
            scope: e.scope,
            pid: main ? main.pid : 0,
            start: main ? main.start : "",
            comm: e.comm,
            name: label.name,
            project: project,
            kind: "user",
            container: ""
        };
        var isDocker = docker[e.port] !== undefined && (!main || baseName(main.args[0] || e.comm) === "docker-proxy");
        if (isDocker) {
            item.kind = "docker";
            item.container = docker[e.port];
            item.name = "Docker";
            item.project = docker[e.port];
            item.pid = 0;
            entries.push(item);
        } else if (!main) {
            item.kind = "system";
            system.push(item);
        } else if (!label.dev && project === "") {
            // the user's own, but a desktop daemon rather than something
            // started for a project (kdeconnectd, …)
            item.kind = "own-system";
            system.push(item);
        } else {
            entries.push(item);
        }
    }
    var byPort = function (a, b) { return a.port - b.port; };
    entries.sort(byPort);
    system.sort(byPort);
    // docker-proxy belongs to root, so without socket access its ports have
    // no process and no name; the popup explains that.
    var unnamed = dockerDenied && system.some(function (x) { return x.pid === 0; });
    return { entries: entries, system: system, dockerDenied: unnamed };
}

// "127.0.0.1:5180", "[::1]:631", "*:3000"
function formatAddress(host, port) {
    return (host.indexOf(":") >= 0 ? "[" + host + "]" : host === "" ? "*" : host) + ":" + port;
}

// Where a browser should go: localhost unless the server is bound to one
// specific address only.
function browseHost(entry) {
    if (entry.scope === "lan" && entry.hosts.length === 1)
        return entry.hosts[0].indexOf(":") >= 0 ? "[" + entry.hosts[0] + "]" : entry.hosts[0];
    return "localhost";
}

// Sends SIGTERM (SIGKILL when `force`) to `pid`, but only if it is still the
// process we saw (same start time), then waits up to 3 s (1 s for SIGKILL).
// Prints "gone" or "alive".
function killScript(pid, start, force) {
    var p = parseInt(pid, 10);
    var st = String(start).replace(/[^0-9]/g, "");
    var check = 'alive() { [ -r /proc/' + p + '/stat ] || return 1; set -- $(sed "s/^.*) //" /proc/' + p + '/stat 2>/dev/null); '
        + '[ "$1" != Z ] && [ "${20}" = "' + st + '" ]; }; ';
    return C_LOCALE + check
        + 'alive || { echo gone; exit 0; }; '
        + 'kill -' + (force ? "KILL" : "TERM") + ' ' + p + ' 2>/dev/null; '
        + 'for i in $(seq 1 ' + (force ? 10 : 30) + '); do alive || { echo gone; exit 0; }; sleep 0.1; done; '
        + 'alive && echo alive || echo gone';
}
