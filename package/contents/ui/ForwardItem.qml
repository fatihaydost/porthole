pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

// One forward in the list: what it forwards, its live state and an on/off
// switch. Clicking the row reveals its actions.
PlasmaComponents3.ItemDelegate {
    id: item

    required property var modelData
    required property int index
    required property Service service
    required property var view

    readonly property var forward: modelData
    readonly property string fid: String(forward.id)
    readonly property string status: service.statusRevision >= 0 ? service.statusOf(fid) : ""
    readonly property string hostKeyIssue: service.statusRevision >= 0 ? service.hostKeyIssueOf(fid) : ""
    readonly property string errorText: service.statusRevision >= 0 ? service.errorOf(fid) : ""
    readonly property string warningText: service.statusRevision >= 0 ? service.warningOf(fid) : ""
    // "error" only for a real failure; approval, an untrusted new host key and
    // a shared port are warnings.
    readonly property string severity: service.statusRevision >= 0 ? service.severityOf(fid) : ""
    readonly property bool activeState: status === "active" || status === "connecting" || status === "auth"
    readonly property bool busy: status === "connecting" || status === "auth"
    readonly property bool needsAuth: status === "auth"
    readonly property bool canTrustHostKey: status === "error" && hostKeyIssue === "new"
    readonly property bool expanded: view.expandedId === fid
    readonly property bool confirmingDelete: view.pendingDeleteId === fid

    // The state is told by the dot and the status line only.
    readonly property color statusColor: {
        if (severity === "error")
            return Kirigami.Theme.negativeTextColor;
        if (severity === "warning" || status === "connecting")
            return Kirigami.Theme.neutralTextColor;
        if (status === "active")
            return Kirigami.Theme.positiveTextColor;
        return Kirigami.Theme.disabledTextColor;
    }

    readonly property string statusText: {
        switch (status) {
        case "active":
            return warningText !== "" ? warningText : i18n("Active");
        case "connecting":
            return i18n("Connecting…");
        case "auth":
            return i18n("Waiting for approval in the browser");
        case "error":
            return errorText;
        default:
            return i18n("Off");
        }
    }

    hoverEnabled: true
    highlighted: view.keyboardActive && view.currentIndex === index

    Accessible.name: service.forwardTitle(forward)
    Accessible.description: statusText

    onClicked: {
        view.currentIndex = index;
        view.toggleExpanded(fid);
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            // Neutral: the text colour, faded while the forward is off.
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Math.round(Kirigami.Units.smallSpacing / 2)
                source: Qt.resolvedUrl("../icons/porthole-symbolic.svg")
                isMask: true
                color: Kirigami.Theme.textColor
                opacity: item.activeState ? 1 : 0.5
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: item.service.forwardTitle(item.forward)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.weight: item.activeState ? Font.DemiBold : Font.Normal
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: i18nc("local address → remote address via ssh host", "%1 → %2 via %3",
                                item.service.localAddress(item.forward),
                                item.service.remoteAddress(item.forward),
                                item.forward.sshTarget)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    wrapMode: item.expanded ? Text.Wrap : Text.NoWrap
                    maximumLineCount: item.expanded ? 1000 : 1
                    font: Kirigami.Theme.smallFont
                    opacity: 0.75
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Math.round(Kirigami.Units.smallSpacing / 2)
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        id: dot
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: Math.round((statusLabel.font.pixelSize > 0 ? statusLabel.font.pixelSize : Kirigami.Theme.smallFont.pixelSize) * 0.45)
                        implicitWidth: Math.round(Kirigami.Units.smallSpacing * 1.5)
                        implicitHeight: implicitWidth
                        radius: width / 2
                        color: item.statusColor

                        // Gentle pulse while a tunnel comes up or waits on
                        // approval. Off when animations are off (duration 0).
                        SequentialAnimation on opacity {
                            running: item.busy && Kirigami.Units.longDuration > 0
                            loops: Animation.Infinite
                            alwaysRunToEnd: true
                            NumberAnimation { to: 0.3; duration: Kirigami.Units.veryLongDuration * 2; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 1; duration: Kirigami.Units.veryLongDuration * 2; easing.type: Easing.InOutQuad }
                        }
                    }

                    PlasmaComponents3.Label {
                        id: statusLabel
                        Layout.fillWidth: true
                        text: item.statusText
                        // Error text quotes the remote's stderr: never markup.
                        textFormat: Text.PlainText
                        color: item.statusColor
                        font: Kirigami.Theme.smallFont
                        // One line in the list, except an error: its reason
                        // wraps (up to three lines) so it never ends mid-sentence.
                        // The whole text once expanded.
                        wrapMode: item.expanded || item.status === "error" ? Text.Wrap : Text.NoWrap
                        maximumLineCount: item.expanded ? 1000 : item.status === "error" ? 3 : 1
                        elide: item.expanded ? Text.ElideNone : Text.ElideRight
                    }
                }
            }

            PlasmaComponents3.Switch {
                id: toggleSwitch
                Layout.alignment: Qt.AlignVCenter
                checked: item.activeState
                enabled: item.service.ready
                Accessible.name: item.activeState ? i18n("Turn off %1", item.service.forwardTitle(item.forward))
                                                  : i18n("Turn on %1", item.service.forwardTitle(item.forward))
                onToggled: {
                    item.service.toggle(item.forward);
                    // the poll owns the state; keep following it
                    checked = Qt.binding(() => item.activeState);
                }

                PlasmaComponents3.ToolTip.text: item.activeState ? i18n("Turn off") : i18n("Turn on")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }

        // What the user has to do next, shown without expanding.
        PlasmaComponents3.Button {
            Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
            visible: item.needsAuth || item.canTrustHostKey
            icon.name: item.needsAuth ? "internet-web-browser-symbolic" : "security-medium-symbolic"
            text: item.needsAuth ? i18n("Open Approval Page") : i18n("Trust Host Key and Retry")
            onClicked: {
                if (item.needsAuth)
                    item.service.openAuth(item.fid);
                else
                    item.service.trustAndRetry(item.forward);
            }
        }

        Flow {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
            visible: item.expanded && !item.confirmingDelete
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.ToolButton {
                icon.name: "internet-web-browser-symbolic"
                text: i18n("Open in Browser")
                enabled: item.status === "active"
                onClicked: Qt.openUrlExternally("http://" + item.service.localAddress(item.forward) + "/")
            }
            PlasmaComponents3.ToolButton {
                icon.name: "edit-copy-symbolic"
                text: i18n("Copy Address")
                onClicked: item.view.copyText(item.service.localAddress(item.forward))
            }
            PlasmaComponents3.ToolButton {
                icon.name: "document-edit-symbolic"
                text: i18n("Edit")
                enabled: item.service.storeOk
                onClicked: item.view.openEditForm(item.forward)
            }
            PlasmaComponents3.ToolButton {
                icon.name: "edit-delete-symbolic"
                text: i18n("Delete")
                enabled: item.service.storeOk
                onClicked: item.view.requestDelete(item.fid)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing
            visible: item.confirmingDelete
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: i18n("Delete “%1”?", item.service.forwardTitle(item.forward))
                textFormat: Text.PlainText
                elide: Text.ElideRight
            }
            PlasmaComponents3.Button {
                icon.name: "edit-delete-symbolic"
                text: i18n("Delete")
                onClicked: item.view.confirmDelete()
            }
            PlasmaComponents3.Button {
                text: i18n("Cancel")
                onClicked: item.view.pendingDeleteId = ""
            }
        }
    }
}
