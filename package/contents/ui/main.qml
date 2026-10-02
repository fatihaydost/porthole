pragma ComponentBehavior: Bound

import QtQuick

import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid

// SSH port forwards in the system tray. Tunnels run as transient systemd user
// units (see Service.qml); this item only shows their state and sends commands.
PlasmoidItem {
    id: root

    // Visible in the tray at all times. Never NeedsAttention: the tray answers
    // that with a scale bounce on the whole icon, which is too loud for a
    // failed tunnel. The icon's own status dot carries the signal instead.
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.icon: Qt.resolvedUrl("../icons/porthole-symbolic.svg")

    toolTipMainText: i18n("Porthole")
    toolTipSubText: {
        if (svc.depsChecked && svc.missing.length > 0)
            return i18n("Missing: %1", svc.missing.join(", "));
        const auth = svc.statusRevision >= 0 ? svc.currentAuthText() : "";
        if (auth !== "")
            return auth;
        const err = svc.statusRevision >= 0 ? svc.currentErrorText() : "";
        if (err !== "")
            return err;
        if (svc.forwards.length === 0)
            return i18n("No tunnels");
        return i18n("%1 active · %2 total", svc.activeCount, svc.forwards.length);
    }
    toolTipTextFormat: Text.PlainText

    // On the desktop show the list directly once there is room for it.
    switchWidth: Kirigami.Units.gridUnit * 14
    switchHeight: Kirigami.Units.gridUnit * 12

    // Re-read the store each time the popup opens, so hand edits show.
    onExpandedChanged: {
        if (root.expanded)
            svc.refresh();
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Add Forward…")
            icon.name: "list-add"
            enabled: svc.ready && svc.storeOk
            onTriggered: {
                root.expanded = true;
                root.addRequested();
            }
        },
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: svc.refresh()
        }
    ]

    signal addRequested

    Service {
        id: svc
    }

    compactRepresentation: CompactRepresentation {
        service: svc
        onActivated: root.expanded = !root.expanded
    }

    // Polled only while the popup is open; the tray icon counts tunnels only.
    LocalPorts {
        id: localPorts
        active: root.expanded
    }

    fullRepresentation: FullRepresentation {
        service: svc
        plasmoidItem: root
        ports: localPorts
    }
}
