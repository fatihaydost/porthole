pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "logic.js" as Logic

// One listening port that is not one of Porthole's tunnels: a dev server, a
// container, a system service. Clicking the row reveals its actions.
PlasmaComponents3.ItemDelegate {
    id: item

    required property var modelData
    required property LocalPorts ports
    required property var view

    readonly property var entry: modelData
    readonly property string rowId: "local:" + entry.key
    readonly property bool expanded: view.expandedId === rowId
    readonly property bool confirming: view.pendingDeleteId === rowId
    readonly property string stopState: ports.revision >= 0 ? ports.stopStateOf(entry.key) : ""
    readonly property bool canStop: entry.kind === "user" && entry.pid > 0
    readonly property string address: Logic.browseHost(entry) + ":" + entry.port

    readonly property string title: {
        if (entry.kind === "system")
            return i18n("System service");
        return entry.project !== "" ? i18nc("program · project", "%1 · %2", entry.name, entry.project) : entry.name;
    }

    readonly property string details: {
        const shown = entry.hosts.slice(0, 2).map(h => Logic.formatAddress(h, entry.port));
        let text = shown.join(", ");
        if (entry.hosts.length > 2)
            text += ", …";
        if (entry.pid > 0)
            text = i18nc("listening address · process id", "%1 · pid %2", text, String(entry.pid));
        return text;
    }

    hoverEnabled: true

    Accessible.name: title
    Accessible.description: details

    onClicked: view.toggleExpanded(rowId)

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Math.round(Kirigami.Units.smallSpacing / 2)
                source: item.entry.kind === "user" ? "utilities-terminal-symbolic"
                      : item.entry.kind === "docker" ? "package-x-generic-symbolic"
                      : "network-server-symbolic"
                fallback: "network-server-symbolic"
                isMask: true
                color: Kirigami.Theme.textColor
                opacity: 0.8
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: item.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: item.details
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    wrapMode: item.expanded ? Text.Wrap : Text.NoWrap
                    maximumLineCount: item.expanded ? 1000 : 1
                    font.family: Kirigami.Theme.fixedWidthFont.family
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.75
                }

                // Worth knowing, not an error: anyone on the network can connect.
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    visible: item.entry.scope !== "loopback"
                    text: item.entry.scope === "all" ? i18n("Reachable from your network")
                                                     : i18n("Reachable from your network on %1", item.entry.hosts[0])
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Kirigami.Theme.neutralTextColor
                    font: Kirigami.Theme.smallFont
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
            visible: item.expanded && !item.confirming
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.ToolButton {
                icon.name: "internet-web-browser-symbolic"
                text: i18n("Open in Browser")
                onClicked: Qt.openUrlExternally("http://" + item.address + "/")
            }
            PlasmaComponents3.ToolButton {
                icon.name: "edit-copy-symbolic"
                text: i18n("Copy Address")
                onClicked: item.view.copyText(item.address)
            }
            PlasmaComponents3.ToolButton {
                visible: item.canStop
                icon.name: "process-stop-symbolic"
                text: i18n("Stop")
                onClicked: item.view.pendingDeleteId = item.rowId
            }
        }

        // Inline confirmation; a process that survives SIGTERM gets a second
        // question for SIGKILL.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
            visible: item.confirming
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: {
                    switch (item.stopState) {
                    case "stopping":
                    case "killing":
                        return i18n("Stopping %1 (pid %2)…", item.entry.name, String(item.entry.pid));
                    case "alive":
                        return i18n("%1 (pid %2) is still running after 3 seconds.", item.entry.name, String(item.entry.pid));
                    default:
                        return i18n("Stop %1 (pid %2)?", item.entry.name, String(item.entry.pid));
                    }
                }
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
            }
            PlasmaComponents3.Button {
                visible: item.stopState === "" || item.stopState === "alive"
                icon.name: "process-stop-symbolic"
                text: item.stopState === "alive" ? i18n("Force Stop") : i18n("Stop")
                onClicked: item.ports.stop(item.entry, item.stopState === "alive")
            }
            PlasmaComponents3.Button {
                visible: item.stopState === "" || item.stopState === "alive"
                text: i18n("Cancel")
                onClicked: {
                    item.ports.cancelStop(item.entry.key);
                    item.view.pendingDeleteId = "";
                }
            }
        }
    }
}
