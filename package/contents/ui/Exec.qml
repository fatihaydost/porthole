import QtQuick
import org.kde.plasma.plasma5support as P5Support

import "logic.js" as Logic

// Runs short bash scripts through the executable data engine and hands the
// result to a callback. The engine runs a source string through /bin/sh and
// will not start a second copy of a source that is still running, so every
// call gets a unique $0 tag. Long-lived work (the ssh tunnels) never runs
// here: it goes to systemd-run, which returns at once.
P5Support.DataSource {
    id: exec

    property int _seq: 0
    property var _callbacks: ({})
    // The engine is shared by every applet instance (tray and desktop, say):
    // a per-instance token keeps their source names apart.
    readonly property string _token: Date.now().toString(36) + Math.floor(Math.random() * 0x7fffffff).toString(36)

    engine: "executable"
    connectedSources: []

    function run(script, callback) {
        _seq += 1;
        const source = "bash -c " + Logic.shellQuote(script) + " porthole-" + _token + "-" + _seq;
        if (typeof callback === "function")
            _callbacks[source] = callback;
        connectSource(source);
    }

    onNewData: (source, data) => {
        const callback = _callbacks[source];
        delete _callbacks[source];
        disconnectSource(source);
        if (callback)
            callback(data["exit code"], data["stdout"] || "", data["stderr"] || "");
    }
}
