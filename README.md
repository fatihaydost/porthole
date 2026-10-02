<div align="center">

<img src="docs/logo.svg" width="96" alt="Porthole logo">

# Porthole

**SSH port forwards from the KDE Plasma system tray. One switch per tunnel.**

[![Release](https://img.shields.io/github/v/release/fatihaydost/porthole?label=release&color=1c74c2)](https://github.com/fatihaydost/porthole/releases/latest)
[![KDE Store](https://img.shields.io/badge/KDE%20Store-get%20it-1d99f3?logo=kde&logoColor=white)](https://store.kde.org/p/2376816/)
[![Plasma 6](https://img.shields.io/badge/Plasma-6-1d99f3?logo=kdeplasma&logoColor=white)](https://kde.org/plasma-desktop/)
![systemd user session](https://img.shields.io/badge/runs%20on-systemd%20user%20session-555555)
[![License](https://img.shields.io/github/license/fatihaydost/porthole?color=4c1)](LICENSE)

Define a forward once, then turn it on and off from the tray instead of keeping an
`ssh -L` terminal open. Below it, every port listening on your machine, named after
its program and project.

<img src="docs/hero.png" width="400" alt="The Porthole popup in Breeze Dark: three tunnels in different states, and the local ports Vite, Next.js and Python http.server">

</div>

## What it does

**Tunnels**

- **One switch per forward**, with a live state: *Active*, *Connecting…*, *Waiting for
  approval*, *Off*, or the error ssh reported. Click a row to read the whole error.
- **Tunnels outlive Plasma.** Each runs as a transient systemd user service
  (`porthole-<id>`), not as a child of plasmashell, and is found again after a restart.
- **Active means listening**: a row turns green only once its ssh accepts connections
  on the local port.
- **Bounce a port between hosts**: switching on a forward stops any other one on the same
  local port, so moving `3000` from staging to production is one click.
- **When ssh needs you**: the Tailscale SSH approval link opens from the row; an unknown
  host key can be trusted and retried; a *changed* host key is never trusted
  automatically.
- **Start with Plasma**, per forward. The SSH host field suggests the hosts in
  `~/.ssh/config`.
- The tray icon counts active tunnels and marks a failure with a small red dot. It never
  bounces.

**Local ports**

- Dev servers, containers and services listening on TCP: `Vite · shop`,
  `Next.js · dashboard`, `Docker · postgres`. The project is the process's git
  repository, or its folder.
- Servers open to the network (`0.0.0.0`, `::`, a LAN address) are marked
  **Reachable from your network**.
- **Open in Browser**, **Copy Address**, and **Stop** for your own processes. Stop asks
  first, sends SIGTERM, and offers **Force Stop** if the process is still there after
  3 seconds.
- System services are folded away. Ports are only read while the popup is open.

It follows your colour scheme and accent colour:

| Breeze Light | A failed tunnel, opened |
|:---:|:---:|
| <img src="docs/light.png" width="300" alt="The same popup in Breeze Light"> | <img src="docs/row-actions.png" width="300" alt="A tunnel row opened to show its full error and actions"> |

| Adding a forward | In the tray |
|:---:|:---:|
| <img src="docs/form.png" width="300" alt="The add-forward form, suggesting hosts from ~/.ssh/config"> | <img src="docs/tray.png" width="196" alt="The tray icon with its active-tunnel count"> |

## Requirements

- KDE Plasma 6
- a systemd user session (`systemd-run --user`). Distributions without systemd are not
  supported; the popup says so.
- the OpenSSH client and iproute2 (`ss`), present on almost every desktop
- SSH that logs in without a prompt: a key without a passphrase, or one loaded in an
  agent (see [SSH agent](#ssh-agent))

## Install

**From the KDE Store.** Right-click the desktop → **Add Widgets…** → **Get New Widgets…** →
**Download New Plasma Widgets**, and search for *Porthole*. It is also on the
[KDE Store](https://store.kde.org/p/2376816/).

**From a release.** Download `porthole.plasmoid` from
[Releases](https://github.com/fatihaydost/porthole/releases), then:

```bash
kpackagetool6 --type Plasma/Applet --install porthole.plasmoid
```

Use `--upgrade` instead of `--install` to update.

**From source.**

```bash
git clone https://github.com/fatihaydost/porthole.git
cd porthole
./install.sh --reload
```

`--reload` restarts Plasma so that a running copy picks up the new code.

Porthole shows up in the system tray. If it is hidden, right-click the tray's arrow →
**Configure System Tray…** → **Entries** and set Porthole to *Always shown*.

**Uninstall:** `kpackagetool6 --type Plasma/Applet --remove io.github.fatihaydost.porthole`

## Using it

Click **Add**, give the forward a name, a local port, an SSH host and the remote port,
and flip its switch.

- Left click opens the list, middle click re-reads everything.
- With the popup open: `↑`/`↓` select a tunnel, `Space`/`Enter` toggle, `E` edit, `A` add,
  `R` or `F5` refresh. `Delete` asks first; `Enter` confirms, `Esc` cancels.

## Configuration file

Forwards are kept in `~/.config/porthole/forwards.json`. You can edit it by hand, and an
Omarchy `port-forwards.json` can be copied over as is:

```json
{
  "version": 1,
  "forwards": [
    {
      "label": "Staging web",
      "localPort": 3000,
      "sshTarget": "staging",
      "remoteHost": "localhost",
      "remotePort": 3000,
      "autostart": false,
      "extraOptions": "-J bastion"
    }
  ]
}
```

- `localPort` and `sshTarget` (a `Host` from `~/.ssh/config`, or `user@host`) are
  required. `remoteHost` defaults to `localhost`, `remotePort` to the local port.
- `extraOptions` is split on whitespace; anything that needs quoting belongs in
  `~/.ssh/config`.
- `id` may be left out; Porthole derives a stable one.

Porthole never loses what you wrote: loading never writes the file, entries it cannot
read are kept as they are, unknown fields survive a save, and writes are atomic
(symlinks and permissions are kept). If the file is not valid JSON, Porthole shows an
error and will not save until you fix it.

## How a tunnel runs

```
systemd-run --user --unit=porthole-<id> -- \
  ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10 \
      -L <localPort>:<remoteHost>:<remotePort> [extraOptions] -- <sshTarget>
```

systemd is the single source of truth: every 4 seconds Porthole reads each unit's state,
who listens on its port, and its journal when something is wrong. There is no automatic
reconnect; a dropped connection shows as an error, and the switch retries it. The units
are ordinary ones:

```bash
systemctl --user list-units 'porthole-*'
journalctl --user -u porthole-<id>
```

## SSH agent

Tunnels run with `BatchMode=yes` under the systemd user manager, which often has no
`SSH_AUTH_SOCK`. Porthole looks for a running agent itself (the systemd environment,
Plasma's environment, OpenSSH's `ssh-agent.socket`, GNOME Keyring, gpg-agent) and passes
it to the tunnel. Without one, ssh reads your key files directly, which works for keys
without a passphrase. For a key with a passphrase:

```bash
systemctl --user enable --now ssh-agent.socket
ssh-add
```

**Docker containers** are named in Local ports only if `docker ps` works for your user
(the `docker` group). Otherwise their ports show as unnamed system services.

## Development

```bash
node tests/logic.test.js   # 29 unit tests
tests/run-e2e.sh           # 56 end-to-end steps against a throwaway sshd on 127.0.0.1:2222
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml package/contents/ui/*.qml
plasmoidviewer -a package
```

`run-e2e.sh` needs `sshd`, `socat`, `curl` and PyQt6. It drives the widget's own QML
through real tunnels and local servers, and stops only what it started.

## Credits and license

MIT, see [LICENSE](LICENSE). Porthole is a Plasma port of the Omarchy
[port-forward plugin](https://github.com/omacom/omarchy-port-forward-plugin)
by HeyOodle (MIT); the behaviour is the same, the interface is native Plasma.
