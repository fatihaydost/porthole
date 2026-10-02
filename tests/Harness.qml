import QtQuick

import "../package/contents/ui" as UI

// End-to-end scenario for Service.qml against the scratch sshd started by
// tests/run-e2e.sh. Every action is a call the popup makes; every check reads
// the widget's own state, or the system (curl, systemctl) for ground truth.
Item {
    id: h

    signal finished(int code)

    readonly property string scratch: scratchDir
    readonly property string user: userName
    // Scratch known_hosts only, and with `kh` the scratch client key only:
    // the user's own keys and agent never take part.
    readonly property string khOnly: "-o UserKnownHostsFile=" + scratch + "/known_hosts"
    readonly property string kh: khOnly + " -o IdentitiesOnly=yes -o IdentityFile=" + scratch + "/client_key"
    readonly property var svc: loader.item
    property var ids: ({})
    property var shellResult: null
    property var mark: ({})
    property int failures: 0
    property int passes: 0
    property var steps: []
    property int idx: -1
    property double stepStart: 0

    Loader {
        id: loader
        sourceComponent: serviceComponent
    }

    Component {
        id: serviceComponent
        UI.Service {}
    }

    UI.Exec {
        id: sh
    }

    UI.LocalPorts {
        id: lp
    }

    function local(port) {
        const all = lp.entries.concat(lp.system);
        for (let i = 0; i < all.length; i++)
            if (all[i].port === port)
                return all[i];
        return null;
    }

    function fw(name) { return svc.findForward(ids[name]); }
    function st(name) { return svc.statusOf(ids[name]); }
    function unit(name) { return "porthole-" + String(ids[name]).replace(/[^A-Za-z0-9_-]/g, "_"); }
    function shell(cmd) {
        shellResult = null;
        sh.run(cmd, (code, out, err) => { shellResult = { code: code, out: out, err: err }; });
    }
    function def(label, lp, target, rp, extra, autostart) {
        return { label: label, localPort: lp, sshTarget: target, remoteHost: "localhost", remotePort: rp, autostart: autostart === true, extraOptions: extra };
    }
    function elapsed() { return Date.now() - stepStart; }
    function describe(name) {
        return name + " status=" + st(name) + " err=" + JSON.stringify(svc.errorOf(ids[name])) + " hk=" + svc.hostKeyIssueOf(ids[name]);
    }
    function restartService() {
        loader.active = false;
        loader.active = true;
    }

    function buildSteps() {
        const T = scratch;
        const target = user + "@127.0.0.1";
        return [
            { name: "service loads; requirements found; empty store",
              until: () => svc.loaded && svc.depsChecked,
              check: () => svc.missing.length === 0 && svc.forwards.length === 0 ? "" : "missing=" + svc.missing + " forwards=" + svc.forwards.length },
            { name: "add forward A (18765 -> 8765) via the form API",
              run: () => { ids.A = svc.addForward(def("web A", 18765, target, 8765, "-p 2222 " + kh)); },
              until: () => elapsed() > 600,
              check: () => fw("A") ? "" : "not added" },
            { name: "store written to disk, original format",
              run: () => shell('cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null,
              check: () => {
                  const j = JSON.parse(shellResult.out);
                  return j.version === 1 && j.forwards.length === 1 && j.forwards[0].id === ids.A && j.forwards[0].remotePort === 8765 ? "" : shellResult.out;
              } },
            { name: "start A, host key unknown -> error 'new'",
              run: () => svc.start(fw("A")),
              until: () => st("A") === "error", timeout: 25000,
              check: () => svc.hostKeyIssueOf(ids.A) === "new" && svc.errorOf(ids.A) === "Host key not trusted yet" && svc.severityOf(ids.A) === "warning" ? "" : describe("A"),
              detail: () => describe("A") },
            { name: "trust & retry -> active",
              run: () => svc.trustAndRetry(fw("A")),
              until: () => st("A") === "active", timeout: 25000,
              detail: () => describe("A") },
            { name: "curl through tunnel A shows server A",
              run: () => shell("curl -s --max-time 5 http://localhost:18765/"),
              until: () => shellResult !== null,
              check: () => shellResult.out.indexOf("TUNNEL-A") === 0 ? "" : JSON.stringify(shellResult) },
            { name: "accept-new recorded the key in the scratch known_hosts",
              run: () => shell("grep -c '127.0.0.1' " + T + "/known_hosts"),
              until: () => shellResult !== null,
              check: () => parseInt(shellResult.out, 10) >= 1 ? "" : shellResult.out },
            { name: "A runs as a transient systemd user service",
              run: () => shell("systemctl --user show " + unit("A") + " -p ActiveState -p Transient -p Description"),
              until: () => shellResult !== null,
              check: () => /ActiveState=active/.test(shellResult.out) && /Transient=yes/.test(shellResult.out) ? "" : shellResult.out },
            { name: "add B on the same local port (18765 -> 8766)",
              run: () => { ids.B = svc.addForward(def("web B", 18765, target, 8766, "-p 2222 " + kh)); },
              until: () => elapsed() > 300,
              check: () => fw("B") ? "" : "not added" },
            { name: "start B bounces A off the port",
              run: () => svc.start(fw("B")),
              until: () => st("B") === "active" && st("A") === "inactive", timeout: 25000,
              detail: () => describe("A") + " | " + describe("B") },
            { name: "curl now reaches server B",
              run: () => shell("curl -s --max-time 5 http://localhost:18765/"),
              until: () => shellResult !== null,
              check: () => shellResult.out.indexOf("TUNNEL-B") === 0 ? "" : JSON.stringify(shellResult) },
            { name: "systemd agrees A's unit is gone",
              run: () => shell("systemctl --user is-active " + unit("A") + "; true"),
              until: () => shellResult !== null,
              check: () => /^(inactive|unknown)/.test(shellResult.out.trim()) ? "" : shellResult.out },
            { name: "stop B -> inactive and stays inactive across polls",
              run: () => svc.stop(ids.B),
              until: () => elapsed() > 5000,
              check: () => st("B") === "inactive" ? "" : describe("B") },
            { name: "curl fails once B is down",
              run: () => shell("curl -s --max-time 3 http://localhost:18765/"),
              until: () => shellResult !== null,
              check: () => shellResult.code !== 0 ? "" : JSON.stringify(shellResult) },
            { name: "on then off in the same instant ends off (commands queued per forward)",
              run: () => { svc.start(fw("A")); svc.stop(ids.A); },
              until: () => elapsed() > 7000, timeout: 9000,
              check: () => st("A") === "inactive" ? "" : describe("A") },
            { name: "systemd agrees: nothing left running for A",
              run: () => shell("systemctl --user is-active " + unit("A") + "; true"),
              until: () => shellResult !== null,
              check: () => !/^active/.test(shellResult.out.trim()) ? "" : shellResult.out },
            { name: "port shared with another program -> active with a warning",
              run: () => { ids.H = svc.addForward(def("shared port", 18780, target, 8765, "-p 2222 " + kh)); svc.start(fw("H")); },
              until: () => st("H") === "active" && svc.warningOf(ids.H) !== "", timeout: 20000,
              check: () => svc.severityOf(ids.H) === "warning" && svc.warningCount >= 1 ? "" : describe("H"),
              detail: () => describe("H") + " warn=" + svc.warningOf(ids.H) },
            { name: "stop H",
              run: () => svc.stop(ids.H),
              until: () => elapsed() > 1500 && st("H") === "inactive" },
            { name: "wrong ssh port -> error 'Connection refused'",
              run: () => { ids.C = svc.addForward(def("wrong port", 18766, target, 8765, "-p 2223 " + kh)); svc.start(fw("C")); },
              until: () => st("C") === "error", timeout: 25000,
              check: () => /refused/i.test(svc.errorOf(ids.C)) ? "" : describe("C"),
              detail: () => describe("C") },
            { name: "unknown host -> error 'Could not resolve'",
              run: () => { ids.D = svc.addForward(def("", 18767, user + "@pf-test.invalid", 80, "")); svc.start(fw("D")); },
              until: () => st("D") === "error", timeout: 25000,
              check: () => /resolve/i.test(svc.errorOf(ids.D)) ? "" : describe("D"),
              detail: () => describe("D") },
            { name: "changed host key -> error 'changed', MITM warning",
              run: () => { ids.E = svc.addForward(def("changed key", 18768, target, 8765, "-p 2222 -o UserKnownHostsFile=" + T + "/known_hosts_bad")); svc.start(fw("E")); },
              until: () => st("E") === "error", timeout: 25000,
              check: () => svc.hostKeyIssueOf(ids.E) === "changed" && /CHANGED/.test(svc.errorOf(ids.E)) && svc.severityOf(ids.E) === "error" ? "" : describe("E"),
              detail: () => describe("E") },
            { name: "key not accepted -> Permission denied (publickey) with agent hint",
              run: () => { ids.F = svc.addForward(def("no key", 18769, target, 8765, "-p 2222 " + khOnly + " -o IdentitiesOnly=yes -o IdentityFile=" + T + "/unauthorized_key")); svc.start(fw("F")); },
              until: () => st("F") === "error", timeout: 25000,
              check: () => /Permission denied \(publickey/.test(svc.errorOf(ids.F)) && /ssh-add/.test(svc.errorOf(ids.F)) ? "" : describe("F"),
              detail: () => describe("F") },
            { name: "Tailscale-style approval URL -> auth",
              run: () => { ids.G = svc.addForward(def("approval", 18770, target, 8765, "-p 2222 " + kh + " -o ProxyCommand=" + T + "/fake-tailscale.sh")); svc.start(fw("G")); },
              until: () => st("G") === "auth", timeout: 15000,
              check: () => svc.authUrlOf(ids.G) === "https://login.tailscale.com/a/plasmapftest123" && svc.authCount === 1 ? "" : describe("G") + " url=" + svc.authUrlOf(ids.G),
              detail: () => describe("G") },
            { name: "approval completes -> active without a restart",
              until: () => st("G") === "active", timeout: 25000,
              detail: () => describe("G") },
            { name: "removing G stops its unit",
              run: () => { mark.gUnit = unit("G"); svc.removeForward(ids.G); },
              until: () => elapsed() > 1500 },
            { name: "systemd agrees G is stopped",
              run: () => shell("systemctl --user is-active " + mark.gUnit + "; true"),
              until: () => shellResult !== null,
              check: () => /^(inactive|unknown)/.test(shellResult.out.trim()) && !fw("G") ? "" : shellResult.out },
            { name: "start A again",
              run: () => svc.start(fw("A")),
              until: () => st("A") === "active", timeout: 25000,
              detail: () => describe("A") },
            { name: "editing an active forward restarts it and keeps it active",
              run: () => { svc.updateForward(ids.A, def("web A edited", 18765, target, 8765, "-p 2222 " + kh, true)); },
              until: () => elapsed() > 2000 && st("A") === "active", timeout: 25000,
              check: () => fw("A").label === "web A edited" && fw("A").autostart === true ? "" : JSON.stringify(fw("A")),
              detail: () => describe("A") },
            { name: "local ports: test servers listed with name, project and scope",
              run: () => lp.poll(),
              until: () => lp.loaded && local(18850) && local(18851) && local(18852) && local(18853), timeout: 10000,
              check: () => {
                  const a = local(18850), b = local(18851);
                  const ok = a.kind === "user" && a.name === "Python http.server" && a.project === "lp-loop" && a.scope === "loopback"
                      && b.kind === "user" && b.name === "Python http.server" && b.project === "lp-lan" && b.scope === "all"
                      && local(18853).name === "Python stubborn.py" && local(18853).project === "lp-stubborn";
                  return ok ? "" : JSON.stringify([a, b, local(18853)]);
              } },
            { name: "local ports: the active tunnel A (18765) is not listed again",
              check: () => st("A") === "active" && local(18765) === null ? "" : describe("A") + " " + JSON.stringify(local(18765)) },
            { name: "local ports: Stop sends SIGTERM and the server is gone",
              run: () => { mark.stopPid = local(18852).pid; lp.stop(local(18852), false); },
              until: () => lp.stopStateOf(local(18852) ? local(18852).key : "") === "" && local(18852) === null, timeout: 10000 },
            { name: "...the process really exited",
              run: () => shell("test -d /proc/" + mark.stopPid + " && awk '{print $3}' /proc/" + mark.stopPid + "/stat; true"),
              until: () => shellResult !== null,
              check: () => /^(Z)?$/.test(shellResult.out.trim()) ? "" : "state " + shellResult.out },
            { name: "local ports: a server that ignores SIGTERM is reported alive",
              run: () => { mark.stubborn = local(18853); lp.stop(mark.stubborn, false); },
              until: () => lp.stopStateOf(mark.stubborn.key) === "alive", timeout: 10000 },
            { name: "...Force Stop (SIGKILL) ends it",
              run: () => lp.stop(mark.stubborn, true),
              until: () => lp.stopStateOf(mark.stubborn.key) === "" && local(18853) === null, timeout: 10000 },
            { name: "local ports: no polling while the popup is closed",
              run: () => { lp.active = true; },
              until: () => elapsed() > 5000 },
            { name: "...revision frozen for 9 s after closing",
              run: () => { lp.active = false; mark.rev = -1; Qt.callLater(() => { mark.rev = lp.revision; }); },
              until: () => elapsed() > 9000, timeout: 12000,
              check: () => lp.revision === mark.rev && mark.rev > 0 ? "" : mark.rev + " -> " + lp.revision },
            { name: "record A's invocation id",
              run: () => shell("systemctl --user show -p InvocationID --value " + unit("A")),
              until: () => shellResult !== null,
              check: () => { mark.inv = shellResult.out.trim(); return mark.inv.length > 10 ? "" : shellResult.out; } },
            { name: "new widget instance picks up the live tunnel (no double start)",
              run: () => restartService(),
              until: () => svc.loaded && elapsed() > 6000, timeout: 15000,
              check: () => st("A") === "active" ? "" : describe("A") },
            { name: "autostart left the running unit alone (same invocation)",
              run: () => shell("systemctl --user show -p InvocationID --value " + unit("A")),
              until: () => shellResult !== null,
              check: () => shellResult.out.trim() === mark.inv ? "" : mark.inv + " != " + shellResult.out },
            { name: "stop A (autostart=true)",
              run: () => svc.stop(ids.A),
              until: () => elapsed() > 2500 && st("A") === "inactive" },
            { name: "new widget instance autostarts A",
              run: () => restartService(),
              until: () => svc.loaded && st("A") === "active", timeout: 25000,
              detail: () => describe("A") },
            { name: "hand edit of the store is picked up by the poll",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; sed -i "s/web A edited/hand edited/" "$f"'),
              until: () => shellResult !== null && fw("A") && fw("A").label === "hand edited", timeout: 12000 },
            { name: "hand-written entry without id gets a derived id",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; python3 - "$f" <<\'EOF\'\nimport json,sys\np=sys.argv[1]\nd=json.load(open(p))\nd["forwards"].append({"localPort": 18771, "sshTarget": "hand@written"})\nopen(p,"w").write(json.dumps(d))\nEOF\ncat "$f"'),
              until: () => shellResult !== null && svc.forwards.length === 8, timeout: 15000,
              check: () => {
                  const f = svc.forwards[7];
                  mark.handId = f.id;
                  mark.handText = shellResult.out;
                  return /^h[0-9a-z]+$/.test(f.id) && f.sshTarget === "hand@written" && f.remotePort === 18771 && f.remoteHost === "localhost" ? "" : JSON.stringify(f);
              } },
            { name: "loading never writes the file back",
              run: () => shell('sleep 5; cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null, timeout: 12000,
              check: () => shellResult.out === mark.handText ? "" : "file changed on load" },
            { name: "derived id is the same after a reload",
              run: () => { svc.reload(); },
              until: () => elapsed() > 1500,
              check: () => svc.forwards[7] && svc.forwards[7].id === mark.handId ? "" : JSON.stringify(svc.forwards[7]) },
            { name: "broken JSON: list kept, saving refused, file untouched",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; cp "$f" "$f.good"; printf "{ broken" > "$f"'),
              until: () => shellResult !== null && svc.storeOk === false, timeout: 12000,
              check: () => {
                  const r = svc.addForward(def("x", 18772, target, 1, ""));
                  return r === null && svc.forwards.length === 8 ? "" : "add returned " + r;
              } },
            { name: "broken file still holds the user's text",
              run: () => shell('sleep 1; cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null,
              check: () => shellResult.out === "{ broken" ? "" : shellResult.out },
            { name: "fixed file is accepted again",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; mv "$f.good" "$f"'),
              until: () => shellResult !== null && svc.storeOk === true, timeout: 12000 },
            { name: "unreadable entries and unknown fields: kept, warned about, not written on load",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; printf "%s\\n" \'{"version": 1, "note": "mine", "forwards": [{"id": "keep1", "localPort": 18790, "sshTarget": "' + h.user + '@127.0.0.1", "comment": "kept"}, {"id": "bad", "localport": 5432, "sshTarget": "db", "comment": "prod"}]}\' > "$f"; cat "$f"'),
              until: () => shellResult !== null && svc.invalidCount === 1 && svc.findForward("keep1") !== null, timeout: 12000,
              check: () => { mark.badText = shellResult.out; return svc.storeOk ? "" : "storeOk false"; } },
            { name: "...and the file is untouched a few polls later",
              run: () => shell('sleep 5; cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null, timeout: 12000,
              check: () => shellResult.out === mark.badText ? "" : shellResult.out },
            { name: "adding a forward writes the unreadable entry and the extra fields back",
              run: () => { ids.N = svc.addForward(def("new one", 18791, target, 8765, "")); },
              until: () => elapsed() > 1500 },
            { name: "...checked on disk",
              run: () => shell('cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null,
              check: () => {
                  const j = JSON.parse(shellResult.out);
                  const bad = j.forwards.filter(e => e.id === "bad")[0];
                  const keep = j.forwards.filter(e => e.id === "keep1")[0];
                  return j.note === "mine" && bad && bad.localport === 5432 && bad.comment === "prod" && keep.comment === "kept"
                      && j.forwards.length === 3 ? "" : shellResult.out;
              } },
            { name: "forwards not a list: refused, saving blocked, file untouched",
              run: () => shell('f="$XDG_CONFIG_HOME/porthole/forwards.json"; printf "%s" \'{"forwards": {"a": 1}}\' > "$f"'),
              until: () => shellResult !== null && svc.storeOk === false, timeout: 12000,
              check: () => svc.addForward(def("x", 18792, target, 1, "")) === null ? "" : "add was accepted" },
            { name: "...file still holds the user's text",
              run: () => shell('sleep 1; cat "$XDG_CONFIG_HOME/porthole/forwards.json"'),
              until: () => shellResult !== null,
              check: () => shellResult.out === '{"forwards": {"a": 1}}' ? "" : shellResult.out },
            { name: "cleanup: stop every unit this test created",
              run: () => {
                  for (const key in ids)
                      svc.stop(ids[key]);
              },
              until: () => elapsed() > 3000 },
            { name: "none of this test's units is left running",
              run: () => {
                  const names = [];
                  for (const key in ids)
                      names.push(unit(key));
                  shell("for u in " + names.join(" ") + "; do systemctl --user is-active \"$u\" | grep -qx active && echo \"$u\"; done; true");
              },
              until: () => shellResult !== null,
              check: () => shellResult.out.trim() === "" ? "" : shellResult.out },
        ];
    }

    function next() {
        idx += 1;
        if (idx >= steps.length) {
            tick.stop();
            console.log("RESULT", passes, "passed,", failures, "failed");
            finished(failures === 0 ? 0 : 1);
            return;
        }
        stepStart = Date.now();
        shellResult = null;
        const s = steps[idx];
        if (s.run)
            s.run();
    }

    function advance() {
        if (idx < 0 || idx >= steps.length)
            return;
        const s = steps[idx];
        let done = false;
        try {
            done = s.until ? s.until() : true;
        } catch (e) {
            done = false;
        }
        if (done) {
            let err = "";
            try {
                err = s.check ? s.check() : "";
            } catch (e) {
                err = "exception: " + e;
            }
            if (err === "") {
                passes += 1;
                console.log("PASS", (idx + 1) + ".", s.name, "(" + elapsed() + " ms)");
            } else {
                failures += 1;
                console.log("FAIL", (idx + 1) + ".", s.name, "->", err);
            }
            next();
        } else if (elapsed() > (s.timeout || 20000)) {
            failures += 1;
            console.log("FAIL", (idx + 1) + ".", s.name, "-> timeout", s.detail ? s.detail() : "");
            next();
        }
    }

    Timer {
        id: tick
        interval: 200
        repeat: true
        onTriggered: h.advance()
    }

    Component.onCompleted: {
        steps = buildSteps();
        tick.start();
        next();
    }
}
