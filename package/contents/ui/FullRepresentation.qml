pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

import "logic.js" as Logic

PlasmaExtras.Representation {
    id: full

    required property Service service
    required property PlasmoidItem plasmoidItem
    required property LocalPorts ports

    // Row state lives here, not in the delegates: the list is rebuilt
    // whenever the store is re-read.
    property string expandedId: ""
    property string pendingDeleteId: ""
    property bool formOpen: false
    property bool showDockerInfo: false
    property bool keyboardActive: false
    // Keyboard cursor over the tunnel rows, -1 for none.
    property int currentIndex: -1

    readonly property bool blocked: service.depsChecked && service.missing.length > 0
    // Remembered across sessions (contents/config/main.xml).
    readonly property bool showSystem: Plasmoid.configuration.showSystemServices

    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.minimumHeight: Kirigami.Units.gridUnit * 14
    Layout.preferredHeight: Kirigami.Units.gridUnit * 24

    collapseMarginsHint: true
    focus: true

    function toggleExpanded(id) {
        pendingDeleteId = "";
        expandedId = expandedId === id ? "" : id;
    }

    function openAddForm() {
        if (blocked || !service.storeOk)
            return;
        pendingDeleteId = "";
        formOpen = true;
        form.load(null);
    }

    function openEditForm(f) {
        if (!f || !service.storeOk)
            return;
        pendingDeleteId = "";
        formOpen = true;
        form.load(f);
    }

    function closeForm() {
        formOpen = false;
        sections.forceActiveFocus();
    }

    function requestDelete(id) {
        expandedId = id;
        pendingDeleteId = id;
    }

    function confirmDelete() {
        if (pendingDeleteId !== "")
            service.removeForward(pendingDeleteId);
        pendingDeleteId = "";
        expandedId = "";
        // keep the keyboard cursor on a row that still exists
        currentIndex = Math.min(currentIndex, service.forwards.length - 1);
    }

    function copyText(text) {
        clipboard.text = text;
        clipboard.selectAll();
        clipboard.copy();
        clipboard.text = "";
        service.flash(i18n("Copied %1", text));
    }

    function currentForward() {
        if (currentIndex < 0 || currentIndex >= service.forwards.length)
            return null;
        return service.forwards[currentIndex];
    }

    // Scrolls the list so `item` (a row) is fully visible.
    function ensureVisible(item) {
        if (!item)
            return;
        const y = item.mapToItem(sections, 0, 0).y;
        if (y < flick.contentY)
            flick.contentY = y;
        else if (y + item.height > flick.contentY + flick.height)
            flick.contentY = y + item.height - flick.height;
    }

    Connections {
        target: full.ports
        function onStopped(key, name, gone) {
            if (gone) {
                full.service.flash(i18n("Stopped %1", name));
                if (full.pendingDeleteId === "local:" + key)
                    full.pendingDeleteId = "";
            }
        }
    }

    Connections {
        target: full.plasmoidItem
        function onExpandedChanged() {
            if (full.plasmoidItem.expanded) {
                full.formOpen = false;
                full.pendingDeleteId = "";
                full.keyboardActive = false;
                full.currentIndex = -1;
                sections.forceActiveFocus();
            }
        }
        function onAddRequested() {
            full.openAddForm();
        }
    }

    // Copying goes through a hidden text editor: QML has no clipboard API.
    TextEdit {
        id: clipboard
        visible: false
    }

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.ToolButton {
                visible: full.formOpen
                icon.name: "go-previous-symbolic"
                onClicked: full.closeForm()
                Accessible.name: i18n("Back")
                PlasmaComponents3.ToolTip.text: i18n("Back")
                PlasmaComponents3.ToolTip.visible: hovered
            }

            PlasmaExtras.Heading {
                Layout.fillWidth: true
                Layout.leftMargin: full.formOpen ? 0 : Kirigami.Units.smallSpacing
                level: 5
                elide: Text.ElideRight
                text: {
                    if (full.formOpen)
                        return form.editing ? i18n("Edit Forward") : i18n("New Forward");
                    if (!full.service.loaded)
                        return "";
                    if (full.service.forwards.length === 0)
                        return i18n("No tunnels");
                    return i18n("%1 active · %2 total", full.service.activeCount, full.service.forwards.length);
                }
            }

            PlasmaComponents3.ToolButton {
                visible: !full.formOpen && !full.blocked
                enabled: full.service.storeOk
                icon.name: "list-add-symbolic"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                text: i18n("Add")
                onClicked: full.openAddForm()
                PlasmaComponents3.ToolTip.text: i18n("Add a forward (A)")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }

            PlasmaComponents3.ToolButton {
                visible: !full.formOpen
                icon.name: "view-refresh-symbolic"
                icon.width: Kirigami.Units.iconSizes.small
                icon.height: Kirigami.Units.iconSizes.small
                display: PlasmaComponents3.AbstractButton.IconOnly
                text: i18n("Refresh")
                onClicked: full.service.refresh()
                PlasmaComponents3.ToolTip.text: i18n("Re-read the forwards file and the tunnel states (R)")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }
    }

    contentItem: ColumnLayout {
        spacing: 0

        // The strip above the list is for what belongs to no single row:
        // feedback on an action, a store that cannot be read, entries that
        // could not be read. A forward's own error stays on its row.
        // InlineMessage renders rich text, so everything goes in escaped.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: !full.blocked && full.service.notice !== ""
            type: Kirigami.MessageType.Information
            text: Logic.richEscape(full.service.notice)
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: !full.service.storeOk && !full.blocked
            type: Kirigami.MessageType.Error
            text: Logic.richEscape(i18n("%1 could not be read (%2). Nothing is saved until it is fixed.",
                                        full.service.configPath, full.service.storeError))
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: full.service.storeOk && full.service.invalidCount > 0 && !full.blocked && !full.formOpen
            type: Kirigami.MessageType.Warning
            text: Logic.richEscape(i18np("%1 entry in %2 could not be read. It is kept in the file as written.",
                                         "%1 entries in %2 could not be read. They are kept in the file as written.",
                                         full.service.invalidCount, full.service.configPath))
        }

        // Missing requirements: say exactly what, instead of failing quietly.
        PlasmaExtras.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Kirigami.Units.gridUnit
            visible: full.blocked
            iconName: "dialog-warning"
            text: i18n("Porthole cannot run here")
            explanation: {
                const parts = [];
                const m = full.service.missing;
                const tools = m.filter(x => x !== "systemd-user");
                if (tools.length > 0)
                    parts.push(i18n("Not found on PATH: %1.", tools.join(", ")));
                if (m.indexOf("systemd-user") >= 0)
                    parts.push(i18n("No systemd user session is reachable (systemctl --user)."));
                parts.push(i18n("Tunnels run as systemd user services and need the OpenSSH client and iproute2 (ss)."));
                return parts.join(" ");
            }
        }

        PlasmaComponents3.ScrollView {
            id: formScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: full.formOpen && !full.blocked
            contentWidth: availableWidth

            ForwardForm {
                id: form
                width: formScroll.availableWidth - Kirigami.Units.largeSpacing * 2
                x: Kirigami.Units.largeSpacing
                y: Kirigami.Units.largeSpacing
                service: full.service
                onDone: full.closeForm()
            }
        }

        // Tunnels first, then everything else listening on this machine,
        // in one scrolling column.
        PlasmaComponents3.ScrollView {
            id: listScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !full.formOpen && !full.blocked
            PlasmaComponents3.ScrollBar.horizontal.policy: PlasmaComponents3.ScrollBar.AlwaysOff

            Flickable {
                id: flick
                contentWidth: width
                contentHeight: sections.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: sections

                    x: Kirigami.Units.smallSpacing
                    width: flick.width - Kirigami.Units.smallSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    focus: true

                    Keys.onPressed: event => {
                        const f = full.currentForward();
                        switch (event.key) {
                        case Qt.Key_Up:
                        case Qt.Key_Down:
                            // the first press only shows where the cursor is
                            if (!full.keyboardActive || full.currentIndex < 0) {
                                full.keyboardActive = true;
                                if (full.currentIndex < 0 && full.service.forwards.length > 0)
                                    full.currentIndex = 0;
                            } else {
                                const step = event.key === Qt.Key_Up ? -1 : 1;
                                full.currentIndex = Math.max(0, Math.min(full.service.forwards.length - 1, full.currentIndex + step));
                            }
                            full.ensureVisible(tunnelRows.itemAt(full.currentIndex));
                            event.accepted = true;
                            return;
                        case Qt.Key_Escape:
                            // Back out of a pending delete or an open row
                            // first; only then let the popup close.
                            if (full.pendingDeleteId !== "") {
                                full.pendingDeleteId = "";
                                event.accepted = true;
                            } else if (full.expandedId !== "") {
                                full.expandedId = "";
                                event.accepted = true;
                            }
                            return;
                        case Qt.Key_Return:
                        case Qt.Key_Enter:
                            // Delete asks first: Enter answers that question
                            // instead of switching the tunnel.
                            if (f && full.keyboardActive && full.pendingDeleteId === String(f.id)) {
                                full.confirmDelete();
                                event.accepted = true;
                                return;
                            }
                            // fall through
                        case Qt.Key_Space:
                            if (f && full.keyboardActive && full.pendingDeleteId !== String(f.id)) {
                                full.service.toggle(f);
                                event.accepted = true;
                            }
                            return;
                        case Qt.Key_Delete:
                        case Qt.Key_X:
                            if (f && full.keyboardActive && full.service.storeOk) {
                                full.requestDelete(String(f.id));
                                event.accepted = true;
                            }
                            return;
                        case Qt.Key_E:
                            if (f && full.keyboardActive) {
                                full.openEditForm(f);
                                event.accepted = true;
                            }
                            return;
                        case Qt.Key_A:
                        case Qt.Key_Plus:
                            full.openAddForm();
                            event.accepted = true;
                            return;
                        case Qt.Key_R:
                        case Qt.Key_F5:
                            full.service.refresh();
                            event.accepted = true;
                            return;
                        }
                    }

                    PlasmaExtras.ListSectionHeader {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        text: i18n("Tunnels")
                    }

                    // No forwards yet: one quiet line, the local ports below keep
                    // the popup useful.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing
                        visible: full.service.forwards.length === 0 && full.service.loaded
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            Layout.fillWidth: true
                            text: i18n("No SSH forwards yet.")
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            opacity: 0.75
                        }
                        PlasmaComponents3.ToolButton {
                            enabled: full.service.storeOk
                            icon.name: "list-add-symbolic"
                            text: i18n("Add a Forward…")
                            onClicked: full.openAddForm()
                        }
                    }

                    Repeater {
                        id: tunnelRows
                        model: full.service.forwards
                        delegate: ForwardItem {
                            Layout.fillWidth: true
                            service: full.service
                            view: full
                        }
                    }

                    PlasmaExtras.ListSectionHeader {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        text: i18n("Local ports")
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing
                        visible: full.ports.loaded && full.ports.entries.length === 0
                        text: i18n("Nothing of yours is listening right now.")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        opacity: 0.75
                    }

                    Repeater {
                        model: full.ports.entries
                        delegate: LocalPortItem {
                            Layout.fillWidth: true
                            ports: full.ports
                            view: full
                        }
                    }

                    // Everything that is neither the user's nor a container,
                    // folded away by default. The (i) button explains why a
                    // Docker container may be in here without a name.
                    RowLayout {
                        Layout.fillWidth: true
                        visible: full.ports.system.length > 0
                        spacing: 0

                        PlasmaComponents3.ToolButton {
                            Layout.fillWidth: true
                            text: full.showSystem ? i18np("Hide system service (%1)", "Hide system services (%1)", full.ports.system.length)
                                                  : i18np("Show system service (%1)", "Show system services (%1)", full.ports.system.length)
                            icon.name: full.showSystem ? "arrow-down" : "arrow-right"
                            onClicked: Plasmoid.configuration.showSystemServices = !full.showSystem
                        }

                        PlasmaComponents3.ToolButton {
                            visible: full.ports.dockerDenied
                            checkable: true
                            checked: full.showDockerInfo
                            icon.name: "help-about"
                            display: PlasmaComponents3.AbstractButton.IconOnly
                            onClicked: full.showDockerInfo = checked
                            PlasmaComponents3.ToolTip.text: i18n("Why is a Docker container listed here without a name?")
                            PlasmaComponents3.ToolTip.visible: hovered
                            PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                        }
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing
                        Layout.rightMargin: Kirigami.Units.largeSpacing
                        visible: full.ports.dockerDenied && full.showDockerInfo && full.ports.system.length > 0
                        wrapMode: Text.WordWrap
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        text: i18n("Docker containers are listed here without a name because your user is not allowed to use Docker. To see their names, add your user to the docker group and log in again.")
                    }

                    Repeater {
                        model: full.showSystem ? full.ports.system : []
                        delegate: LocalPortItem {
                            Layout.fillWidth: true
                            ports: full.ports
                            view: full
                        }
                    }

                    Item {
                        Layout.preferredHeight: Kirigami.Units.smallSpacing
                    }
                }
            }
        }
    }
}
