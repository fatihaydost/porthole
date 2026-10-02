import QtQuick

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

// Tray / panel icon. Colours come from the panel's own colour set (nothing is
// forced here), so the icon follows light, dark and mixed panels.
MouseArea {
    id: compact

    required property Service service

    signal activated

    readonly property bool hasError: service.errorCount > 0
    readonly property bool hasWarning: service.warningCount > 0

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    activeFocusOnTab: true

    Accessible.name: i18n("Porthole")
    Accessible.description: i18np("%1 active tunnel", "%1 active tunnels", service.activeCount)
    Accessible.role: Accessible.Button

    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton)
            service.refresh();
        else
            activated();
    }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Enter || event.key === Qt.Key_Return || event.key === Qt.Key_Select) {
            activated();
            event.accepted = true;
        }
    }

    Kirigami.Icon {
        id: icon
        anchors.fill: parent
        source: Qt.resolvedUrl("../icons/porthole-symbolic.svg")
        isMask: true
        color: Kirigami.Theme.textColor
        active: compact.containsMouse
        // Nothing running: step back a little, like an idle device.
        opacity: compact.service.activeCount > 0 || compact.hasError || compact.hasWarning ? 1 : 0.6
    }

    // Active tunnel count, in the user's accent colour.
    Rectangle {
        id: badge
        visible: compact.service.activeCount > 0 && compact.width >= Kirigami.Units.iconSizes.small
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(Math.round(compact.height * 0.5), Kirigami.Units.iconSizes.small * 0.75)
        width: Math.max(height, countLabel.implicitWidth + Kirigami.Units.smallSpacing)
        radius: height / 2
        color: Kirigami.Theme.highlightColor
        border.width: 1
        border.color: Kirigami.Theme.backgroundColor

        PlasmaComponents3.Label {
            id: countLabel
            anchors.centerIn: parent
            text: compact.service.activeCount > 99 ? "99+" : compact.service.activeCount
            color: Kirigami.Theme.highlightedTextColor
            font.pixelSize: Math.max(Math.round(badge.height * 0.7), 7)
            font.bold: true
        }
    }

    // Something needs the user: red for a failure, amber for a warning
    // (pending approval, untrusted new host key, shared port).
    Item {
        id: statusDot
        visible: compact.hasError || compact.hasWarning
        anchors.right: parent.right
        anchors.top: parent.top
        width: Math.max(Math.round(compact.height * 0.35), 6)
        height: width

        readonly property color tone: compact.hasError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor

        // A soft glow that breathes out from the dot a few times when a
        // failure appears, then rests. The icon itself never moves.
        Rectangle {
            id: glow
            anchors.centerIn: parent
            width: parent.width
            height: width
            radius: width / 2
            color: statusDot.tone
            opacity: 0
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: statusDot.tone
            border.width: 1
            border.color: Kirigami.Theme.backgroundColor
        }

        SequentialAnimation {
            id: breathe
            loops: 3
            // Animations off in System Settings: longDuration is 0, stay still.
            readonly property int span: Kirigami.Units.longDuration * 4
            ParallelAnimation {
                NumberAnimation { target: glow; property: "opacity"; from: 0.55; to: 0; duration: breathe.span; easing.type: Easing.OutQuad }
                NumberAnimation { target: glow; property: "scale"; from: 1; to: 2.2; duration: breathe.span; easing.type: Easing.OutQuad }
            }
            PauseAnimation { duration: breathe.span / 2 }
        }

        function pulse() {
            if (compact.hasError && Kirigami.Units.longDuration > 0)
                breathe.restart();
        }
    }

    // Breathe once more each time the number of failures grows, not on every poll.
    property int lastErrorCount: 0
    Connections {
        target: compact.service
        function onErrorCountChanged() {
            if (compact.service.errorCount > compact.lastErrorCount)
                statusDot.pulse();
            compact.lastErrorCount = compact.service.errorCount;
        }
    }
}
