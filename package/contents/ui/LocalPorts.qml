import QtQuick

import "logic.js" as Logic

// Everything else listening on this machine: dev servers, containers, system
// services. Polled every 4 s only while `active` (the popup is open); while
// it is closed no ss runs at all. Porthole's own tunnels are left out.
Item {
    id: root

    visible: false

    property bool active: false

    // The user's own processes and Docker containers.
    property var entries: []
    // Other users' daemons and desktop services (kdeconnectd, resolved, cups…).
    property var system: []
    // Docker is installed but this user cannot talk to it, so containers'
    // ports sit unnamed among the system services.
    property bool dockerDenied: false
    property bool loaded: false

    // key -> "stopping" | "alive" (survived SIGTERM) | "killing"
    property var stopStates: ({})
    property int revision: 0

    signal stopped(string key, string name, bool gone)

    property bool _running: false
    property bool _pending: false

    function stopStateOf(key) { return stopStates[key] || ""; }

    function poll() {
        if (_running) {
            _pending = true;
            return;
        }
        _running = true;
        exec.run(Logic.localPortsScript(), (code, stdout) => {
            _running = false;
            const result = Logic.parseLocalPorts(stdout);
            entries = result.entries;
            system = result.system;
            dockerDenied = result.dockerDenied;
            loaded = true;
            revision += 1;
            if (_pending) {
                _pending = false;
                poll();
            }
        });
    }

    function _setStopState(key, state) {
        const s = Object.assign({}, stopStates);
        if (state === "")
            delete s[key];
        else
            s[key] = state;
        stopStates = s;
        revision += 1;
    }

    // SIGTERM (or SIGKILL with `force`) to the entry's process, only if it
    // is still the process the poll saw (same pid and start time).
    function stop(entry, force) {
        if (!entry || entry.kind !== "user" || entry.pid <= 0)
            return;
        const key = entry.key;
        _setStopState(key, force ? "killing" : "stopping");
        exec.run(Logic.killScript(entry.pid, entry.start, force === true), (code, stdout) => {
            const gone = stdout.trim() !== "alive";
            _setStopState(key, gone ? "" : "alive");
            stopped(key, entry.comm || entry.name, gone);
            poll();
        });
    }

    function cancelStop(key) {
        _setStopState(key, "");
    }

    onActiveChanged: {
        if (active)
            poll();
    }

    Exec {
        id: exec
    }

    Timer {
        interval: 4000
        repeat: true
        running: root.active
        onTriggered: root.poll()
    }
}
