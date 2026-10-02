import QtQuick

import "logic.js" as Logic

// Headless controller. Port of omarchy-port-forward-plugin's Service.qml
// (Copyright (c) 2026 HeyOodle, MIT) to Plasma 6.
//
// Forwards are defined in ~/.config/porthole/forwards.json. Turning one on
// starts `ssh -N -L …` inside a transient systemd user service
// (porthole-<id>.service, via `systemd-run --user`), so a tunnel outlives a
// plasmashell restart or crash and is picked up again on the next start.
//
// systemd is the source of truth for liveness. A poll every 4 s reads each
// unit's state, who listens on its local port and, for failed or stalled
// units, the current invocation's journal. Statuses are "inactive",
// "connecting", "auth" (waiting on an approval URL, e.g. Tailscale SSH check
// mode), "active" and "error". `statusRevision` bumps on every change so
// bindings re-read the plain maps, which QML does not observe deeply.
Item {
    id: root

    visible: false

    readonly property string configPath: Logic.CONFIG_DISPLAY

    // Normalised forward definitions.
    property var forwards: []
    property bool loaded: false
    // False when the store cannot be understood (not JSON, not an object,
    // "forwards" not a list). Saving is then refused so nothing is lost.
    property bool storeOk: true
    property string storeError: ""
    // Entries of the file that do not validate. They are kept as written and
    // go back into the file on every save.
    property int invalidCount: 0

    // Requirements. `missing` lists what the startup check did not find.
    property bool depsChecked: false
    property var missing: []
    readonly property bool sshAvailable: missing.indexOf("ssh") < 0
    readonly property bool ready: depsChecked && missing.length === 0

    // Host aliases from ~/.ssh/config, for the form's suggestions.
    property var sshHosts: []

    // Runtime state, keyed by forward id.
    property var statuses: ({})
    property var errors: ({})
    property var authUrls: ({})
    property var hostKeyIssues: ({}) // id -> "new" | "changed"
    property var warnings: ({})      // id -> text (port shared with another program)
    property int statusRevision: 0
    property int activeCount: 0
    property int authCount: 0
    // Real failures; an untrusted new host key counts as a warning instead.
    property int errorCount: 0
    // Things that wait on the user: approval, new host key, shared port.
    property int warningCount: 0

    // Transient one-line message for the popup header.
    property string notice: ""

    property bool _autostarted: false
    property int _idCounter: 0
    property var _startedAt: ({}) // id -> ms; grace window so a fresh start reads "connecting"
    property bool _pollRunning: false
    property bool _pollPending: false
    property string _cfgSignature: ""
    property string _lastText: ""
    property bool _saving: false
    property bool _savePending: false
    property int _saveSeq: 0
    property bool _loading: false
    // What parseStore kept aside, written back by save().
    property var _extras: ({})
    property var _invalid: []
    property var _top: ({})
    // Per-forward command queue: start and stop of one forward run in order.
    property var _queues: ({})
    property var _running: ({})
    // Poll results for a forward the user touched after the poll began are
    // stale; `_touched[id]` holds the action sequence number of the last touch.
    property int _actionSeq: 0
    property var _touched: ({})
    // id -> {inv, msg, hk}: the error of a failed unit's current invocation,
    // so its journal is read once, not every 4 s.
    property var _errCache: ({})

    signal changed

    function statusOf(id) { return statuses[String(id)] || "inactive"; }
    function errorOf(id) { return errors[String(id)] || ""; }
    function authUrlOf(id) { return authUrls[String(id)] || ""; }
    function hostKeyIssueOf(id) { return hostKeyIssues[String(id)] || ""; }
    function warningOf(id) { return warnings[String(id)] || ""; }
    function isActive(id) {
        const s = statusOf(id);
        return s === "active" || s === "connecting" || s === "auth";
    }
    // "error" for a real failure, "warning" when the user has to act
    // (approval, new host key, shared port), "" otherwise.
    function severityOf(id) {
        const s = statusOf(id);
        if (s === "error")
            return hostKeyIssueOf(id) === "new" ? "warning" : "error";
        if (s === "auth" || warningOf(id) !== "")
            return "warning";
        return "";
    }

    function findForward(id) {
        const key = String(id);
        for (let i = 0; i < forwards.length; i++)
            if (String(forwards[i].id) === key)
                return forwards[i];
        return null;
    }

    function forwardTitle(f) { return Logic.forwardTitle(f); }
    function localAddress(f) { return Logic.localAddress(f); }
    function remoteAddress(f) { return Logic.remoteAddress(f); }

    function currentErrorText() {
        for (let i = 0; i < forwards.length; i++) {
            const id = String(forwards[i].id);
            if (statusOf(id) === "error")
                return forwardTitle(forwards[i]) + ": " + errorOf(id);
        }
        return "";
    }

    function currentAuthText() {
        for (let i = 0; i < forwards.length; i++) {
            const id = String(forwards[i].id);
            if (statusOf(id) === "auth")
                return i18n("%1: approval required, open the authentication page to continue", forwardTitle(forwards[i]));
        }
        return "";
    }

    function genId() {
        _idCounter += 1;
        return Logic.genId(_idCounter);
    }

    // --- persistence -------------------------------------------------------

    function reload() {
        // Reading between two of our own writes would roll memory back.
        if (_loading || _saving || _savePending)
            return;
        _loading = true;
        exec.run(Logic.readStoreScript(), (code, stdout, stderr) => {
            _loading = false;
            if (code === 3) {
                _applyStore("");
            } else if (code !== 0) {
                // Unreadable (permissions…): keep what we have, never save over it.
                storeOk = false;
                storeError = stderr.trim();
                if (!loaded) {
                    loaded = true;
                    changed();
                    schedulePoll(0);
                }
            } else {
                _applyStore(stdout);
            }
        });
    }

    // Loading never writes: ids of hand-written entries are derived from
    // their content, unreadable entries and unknown fields are kept aside.
    function _applyStore(text) {
        const first = !loaded;
        const result = Logic.parseStore(text);
        storeOk = result.ok;
        storeError = result.error;
        if (!result.ok) {
            console.warn("porthole: could not read", configPath + ":", result.error);
            if (!loaded)
                forwards = [];
        } else if (text !== _lastText || first) {
            // Same text as last time (our own write, a no-op touch): keep the
            // list as it is, so the view keeps its cursor.
            _lastText = text;
            forwards = result.forwards;
            _extras = result.extras;
            _invalid = result.invalid;
            _top = result.top;
            invalidCount = result.invalid.length;
            if (result.invalid.length > 0)
                console.warn("porthole:", result.invalid.length, "entries of", configPath, "could not be read; they are kept as written");
        }
        loaded = true;
        changed();
        // Reconcile with systemd right away: this is what picks up tunnels that
        // outlived the previous plasmashell. Autostart waits for this poll.
        if (first)
            schedulePoll(0);
    }

    function save() {
        if (!storeOk) {
            flash(i18n("Not saved: %1 could not be read. Fix or remove it first.", configPath));
            return false;
        }
        if (_saving) {
            _savePending = true;
            return true;
        }
        _saving = true;
        _saveSeq += 1;
        const content = Logic.serializeStore(forwards, _extras, _invalid, _top);
        exec.run(Logic.writeStoreScript(content), (code, stdout, stderr) => {
            _saving = false;
            if (code !== 0) {
                flash(i18n("Could not save %1: %2", configPath, stderr.trim()));
            } else {
                // Remember our own write so the poll does not read it back.
                _lastText = content;
                _cfgSignature = stdout.trim().split("\n").pop();
            }
            if (_savePending) {
                _savePending = false;
                save();
            }
        });
        return true;
    }

    function _definition(id, def) {
        return Logic.normalizeForward({
            id: id,
            label: def.label,
            localPort: def.localPort,
            sshTarget: def.sshTarget,
            remoteHost: def.remoteHost,
            remotePort: def.remotePort,
            autostart: def.autostart,
            extraOptions: def.extraOptions
        }, genId);
    }

    function addForward(def) {
        if (!storeOk) {
            save();
            return null;
        }
        const n = _definition(genId(), def);
        if (!n) {
            flash(i18n("Local port and SSH host are required"));
            return null;
        }
        forwards = forwards.concat([n]);
        save();
        changed();
        return n.id;
    }

    function updateForward(id, def) {
        if (!storeOk) {
            save();
            return false;
        }
        const key = String(id);
        const wasActive = isActive(key);
        const next = [];
        let updated = null;
        for (let i = 0; i < forwards.length; i++) {
            if (String(forwards[i].id) === key) {
                updated = _definition(key, def);
                if (!updated) {
                    flash(i18n("Local port and SSH host are required"));
                    return false;
                }
                next.push(updated);
            } else {
                next.push(forwards[i]);
            }
        }
        forwards = next;
        save();
        changed();
        if (wasActive && updated)
            start(updated); // start() stops the old unit itself, in sequence
        return true;
    }

    function removeForward(id) {
        if (!storeOk) {
            save();
            return;
        }
        const key = String(id);
        stop(key);
        forwards = forwards.filter(f => String(f.id) !== key);
        const extras = Object.assign({}, _extras);
        delete extras[key];
        _extras = extras;
        save();
        changed();
    }

    // --- commands ----------------------------------------------------------

    function _isBusy(id) {
        const key = String(id);
        return _running[key] === true || (_queues[key] || []).length > 0;
    }

    // Runs the scripts of one forward strictly one after another, so a quick
    // on/off never leaves the stop running ahead of the start.
    function _runFor(id, script, callback) {
        const key = String(id);
        const queue = (_queues[key] || []).concat([{ script: script, callback: callback }]);
        _queues[key] = queue;
        if (!_running[key])
            _nextFor(key);
    }

    function _nextFor(key) {
        const queue = _queues[key] || [];
        if (queue.length === 0) {
            delete _running[key];
            delete _queues[key];
            return;
        }
        const job = queue[0];
        _queues[key] = queue.slice(1);
        _running[key] = true;
        exec.run(job.script, (code, stdout, stderr) => {
            if (job.callback)
                job.callback(code, stdout, stderr);
            _nextFor(key);
        });
    }

    function _touch(id) {
        _actionSeq += 1;
        _touched[String(id)] = _actionSeq;
    }

    // --- tunnels -----------------------------------------------------------

    function start(f, trustHostKey) {
        if (!f)
            return;
        if (!depsChecked) {
            flash(i18n("Still checking requirements…"));
            return;
        }
        if (!ready) {
            flash(sshAvailable ? i18n("Requirements are missing: %1", missing.join(", "))
                               : i18n("ssh is not installed or not on PATH"));
            return;
        }
        // Every other active forward on the same local port goes down first.
        const others = [];
        for (let i = 0; i < forwards.length; i++) {
            const other = forwards[i];
            if (String(other.id) === String(f.id))
                continue;
            if (other.localPort === f.localPort && isActive(other.id)) {
                others.push(Logic.unitName(other.id));
                _touch(other.id);
                _setOne(other.id, "inactive", "");
            }
        }
        const description = i18n("Porthole: %1", forwardTitle(f));
        const started = Object.assign({}, _startedAt);
        started[String(f.id)] = Date.now();
        _startedAt = started;
        _touch(f.id);
        _setOne(f.id, "connecting", "");
        _runFor(f.id, Logic.startScript(f, others, trustHostKey === true, description), (code, stdout, stderr) => {
            // systemd-run itself failing (bus down, unit name clash) never
            // reaches the journal, so say it here.
            if (code !== 0) {
                const line = stderr.trim().split("\n").pop();
                flash(i18n("Could not start %1: %2", forwardTitle(f), line || i18n("systemd-run failed")));
            }
            schedulePoll(0);
        });
        schedulePoll(800);
    }

    function stop(id) {
        const key = String(id);
        const started = Object.assign({}, _startedAt);
        delete started[key];
        _startedAt = started;
        _touch(key);
        _runFor(key, Logic.stopScript(key), () => schedulePoll(0));
        _setOne(key, "inactive", "");
        schedulePoll(500);
    }

    function toggle(f) {
        if (!f)
            return;
        if (isActive(f.id))
            stop(f.id);
        else
            start(f);
    }

    // The waiting ssh carries on by itself once the user approves; the next
    // poll flips the row to active.
    function openAuth(id) {
        const url = authUrlOf(id);
        if (url === "")
            return;
        Qt.openUrlExternally(url);
        flash(i18n("Opened the approval page. Finish in the browser; the tunnel resumes by itself."));
    }

    // Retry once with StrictHostKeyChecking=accept-new. Never offered for a
    // CHANGED key.
    function trustAndRetry(f) {
        if (!f)
            return;
        flash(i18n("Accepting the new host key and retrying…"));
        start(f, true);
    }

    // --- polling -----------------------------------------------------------

    function schedulePoll(delayMs) {
        if (delayMs && delayMs > 0) {
            pollDelay.interval = delayMs;
            pollDelay.restart();
            return;
        }
        runPoll();
    }

    function runPoll() {
        if (!depsChecked || missing.indexOf("systemctl") >= 0 || missing.indexOf("systemd-user") >= 0)
            return;
        if (_pollRunning) {
            _pollPending = true;
            return;
        }
        _pollRunning = true;
        // Autostart may only trust a poll that already covered the loaded list.
        const afterLoad = loaded;
        const startSeq = _actionSeq;
        const saveSeq = _saveSeq;
        const cached = {};
        for (const key in _errCache)
            cached[key] = _errCache[key].inv;
        exec.run(Logic.pollScript(forwards, cached), (code, stdout) => {
            _pollRunning = false;
            _applyPoll(stdout, afterLoad, startSeq, saveSeq);
            if (_pollPending) {
                _pollPending = false;
                runPoll();
            }
        });
    }

    function _errorText(hostKey, msg) {
        switch (Logic.errorKind(hostKey, msg)) {
        case "hostkey-changed":
            return i18n("Host key CHANGED, possible man-in-the-middle attack. Verify the host and fix ~/.ssh/known_hosts.");
        case "hostkey-new":
            return i18n("Host key not trusted yet");
        case "publickey":
            return i18n("%1. No usable SSH key: add it to an agent with ssh-add, or start one with systemctl --user enable --now ssh-agent.socket", msg.replace(/\.\s*$/, ""));
        case "raw":
            return msg;
        default:
            return i18n("ssh forwarding failed");
        }
    }

    function _applyPoll(text, afterLoad, startSeq, saveSeq) {
        const result = Logic.parsePoll(text);
        const newStatus = {};
        const newErr = {};
        const newAuth = {};
        const newHk = {};
        const newWarn = {};
        const cache = Object.assign({}, _errCache);
        const now = Date.now();
        const keepCurrent = id => {
            if (statuses[id] !== undefined)
                newStatus[id] = statuses[id];
            if (errors[id])
                newErr[id] = errors[id];
            if (authUrls[id])
                newAuth[id] = authUrls[id];
            if (hostKeyIssues[id])
                newHk[id] = hostKeyIssues[id];
            if (warnings[id])
                newWarn[id] = warnings[id];
        };
        for (let i = 0; i < result.rows.length; i++) {
            const row = result.rows[i];
            const id = row.id;
            if (!findForward(id))
                continue; // deleted while the poll ran
            // Touched by the user since this poll began, or a command still
            // queued: this row is stale, keep the optimistic state.
            if ((_touched[id] || 0) > startSeq || _isBusy(id)) {
                keepCurrent(id);
                continue;
            }
            let msg = row.msg;
            let hk = row.hostKey;
            if (row.cached && cache[id]) {
                msg = cache[id].msg;
                hk = cache[id].hk;
            }
            let status = Logic.deriveStatus(row);
            // Grace window: a just-started unit may not be registered yet.
            if (status === "inactive" && _startedAt[id] && (now - _startedAt[id]) < 4000)
                status = "connecting";
            if (status === "error") {
                if (!row.cached && row.invocation !== "")
                    cache[id] = { inv: row.invocation, msg: msg, hk: hk };
                newErr[id] = _errorText(hk, msg);
                if (hk !== "")
                    newHk[id] = hk;
            } else {
                delete cache[id];
            }
            if (status === "auth")
                newAuth[id] = row.url;
            if (status === "active" && row.listen === "shared")
                newWarn[id] = i18n("Another program also listens on port %1; localhost may reach it instead of this tunnel", String(findForward(id).localPort));
            newStatus[id] = status;
        }
        // Forwards added while the poll ran keep their optimistic state.
        for (let k = 0; k < forwards.length; k++) {
            const fid = String(forwards[k].id);
            if (newStatus[fid] === undefined)
                keepCurrent(fid);
        }
        for (const key in cache)
            if (!findForward(key))
                delete cache[key];
        _errCache = cache;
        // Drop grace entries once a forward settles or is gone.
        const started = Object.assign({}, _startedAt);
        let pruned = false;
        for (const key in started) {
            const st = newStatus[key];
            if (st === undefined || st === "active" || st === "error") {
                delete started[key];
                pruned = true;
            }
        }
        if (pruned)
            _startedAt = started;
        _commit(newStatus, newErr, newAuth, newHk, newWarn);

        // The store changed on disk (hand edit, another instance): reload.
        // A save since the poll began makes its signature stale; skip then.
        if (saveSeq === _saveSeq && !_saving && !_savePending && result.cfg !== "") {
            if (_cfgSignature !== "" && result.cfg !== _cfgSignature)
                reload();
            _cfgSignature = result.cfg;
        }

        if (afterLoad)
            _maybeAutostart();
    }

    // Once per widget lifetime, after the store is loaded and the first poll
    // has told us what is already running, so a live tunnel is never started
    // twice.
    function _maybeAutostart() {
        if (_autostarted || !loaded)
            return;
        _autostarted = true;
        for (let i = 0; i < forwards.length; i++)
            if (forwards[i].autostart && statusOf(forwards[i].id) === "inactive")
                start(forwards[i]);
    }

    // Optimistic single-forward update; the next poll confirms or corrects.
    function _setOne(id, status, err) {
        const key = String(id);
        const s = Object.assign({}, statuses);
        s[key] = status;
        const e = Object.assign({}, errors);
        if (err && err !== "")
            e[key] = err;
        else
            delete e[key];
        const a = Object.assign({}, authUrls);
        delete a[key];
        const h = Object.assign({}, hostKeyIssues);
        delete h[key];
        const w = Object.assign({}, warnings);
        delete w[key];
        _commit(s, e, a, h, w);
    }

    function _commit(newStatus, newErr, newAuth, newHk, newWarn) {
        statuses = newStatus;
        errors = newErr;
        authUrls = newAuth || {};
        hostKeyIssues = newHk || {};
        warnings = newWarn || {};
        let count = 0;
        let auths = 0;
        let errs = 0;
        let warns = 0;
        for (const k in newStatus) {
            const s = newStatus[k];
            // "active" only once ssh listens, as on the row itself
            if (s === "active")
                count += 1;
            if (s === "auth")
                auths += 1;
            const sev = severityOf(k);
            if (sev === "error")
                errs += 1;
            else if (sev === "warning")
                warns += 1;
        }
        activeCount = count;
        authCount = auths;
        errorCount = errs;
        warningCount = warns;
        statusRevision += 1;
    }

    function flash(message) {
        notice = String(message || "");
        if (notice !== "")
            noticeTimer.restart();
    }

    // Re-read the store and the ssh config, then poll.
    function refresh() {
        reload();
        loadSshHosts();
        schedulePoll(0);
    }

    function loadSshHosts() {
        exec.run(Logic.sshConfigScript(), (code, stdout) => {
            sshHosts = Logic.parseSshHosts(stdout);
        });
    }

    function checkDependencies() {
        exec.run(Logic.dependencyScript(), (code, stdout) => {
            const words = stdout.trim().split(/\s+/).filter(w => w !== "");
            missing = words;
            depsChecked = true;
            if (words.length > 0)
                console.warn("porthole: missing requirements:", words.join(" "));
            schedulePoll(0);
        });
    }

    Component.onCompleted: {
        checkDependencies();
        reload();
        loadSshHosts();
    }

    Exec {
        id: exec
    }

    // Steady-state reconcile: catches tunnels that die on their own (network
    // drop, remote reboot) and changes made with systemctl by hand.
    Timer {
        interval: 4000
        repeat: true
        running: true
        onTriggered: root.runPoll()
    }

    Timer {
        id: pollDelay
        interval: 500
        repeat: false
        onTriggered: root.runPoll()
    }

    Timer {
        id: noticeTimer
        interval: 3200
        repeat: false
        onTriggered: root.notice = ""
    }
}
