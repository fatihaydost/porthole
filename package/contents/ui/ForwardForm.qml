pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

import "logic.js" as Logic

// Add / edit form, shown in place of the list.
ColumnLayout {
    id: form

    required property Service service
    // The forward being edited, or null for a new one.
    property var forward: null
    readonly property bool editing: forward !== null

    // A new forward's remote port follows the local one until it is edited.
    property bool remotePortTouched: false

    // The bind address as it would be saved: "" for the default (localhost),
    // null while the text is not an address. Its error shows once the field
    // is left or the form submitted, not while an address is being typed.
    readonly property var bindAddress: Logic.normalizeBindAddress(bindField.text)
    property bool bindChecked: false

    signal done

    spacing: Kirigami.Units.largeSpacing

    function load(f) {
        forward = f || null;
        labelField.text = f ? f.label : "";
        localPort.text = f ? String(f.localPort) : "3000";
        bindField.text = f ? (f.bindAddress || "") : "";
        bindChecked = false;
        hostField.text = f ? f.sshTarget : "";
        remoteHostField.text = f ? f.remoteHost : "localhost";
        remotePort.text = f ? String(f.remotePort) : "3000";
        extraField.text = f ? f.extraOptions : "";
        autostartBox.checked = f ? f.autostart : false;
        remotePortTouched = editing;
        labelField.forceActiveFocus();
    }

    function submit() {
        const lp = localPort.port;
        const rp = remotePort.port;
        if (lp === 0 || rp === 0) {
            service.flash(i18n("Ports are numbers from 1 to 65535"));
            (lp === 0 ? localPort : remotePort).forceActiveFocus();
            return;
        }
        if (bindAddress === null) {
            bindChecked = true;
            service.flash(i18n("The bind address must be an IP address, localhost or *"));
            bindField.forceActiveFocus();
            return;
        }
        if (hostField.text.trim().charAt(0) === "-") {
            service.flash(i18n("The SSH host cannot start with \"-\"; put ssh options under Extra options"));
            hostField.forceActiveFocus();
            return;
        }
        if (hostField.text.trim() === "") {
            service.flash(i18n("SSH host is required"));
            hostField.forceActiveFocus();
            return;
        }
        const def = {
            label: labelField.text,
            bindAddress: bindAddress,
            localPort: lp,
            sshTarget: hostField.text,
            remoteHost: remoteHostField.text,
            remotePort: rp,
            autostart: autostartBox.checked,
            extraOptions: extraField.text
        };
        const ok = editing ? service.updateForward(forward.id, def) : service.addForward(def) !== null;
        if (ok)
            done();
    }

    Keys.onEscapePressed: done()

    component FieldLabel: PlasmaComponents3.Label {
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        horizontalAlignment: Text.AlignRight
    }

    // A plain number field: no steppers, no locale grouping ("3000", never
    // "3.000"), digits right-aligned in a fixed-width font.
    component PortBox: PlasmaComponents3.TextField {
        // 0 while the text is not a valid port
        readonly property int port: {
            const v = parseInt(text, 10);
            return acceptableInput && v >= 1 && v <= 65535 ? v : 0;
        }
        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
        horizontalAlignment: TextInput.AlignRight
        font.family: Kirigami.Theme.fixedWidthFont.family
        inputMethodHints: Qt.ImhDigitsOnly
        maximumLength: 5
        validator: IntValidator {
            bottom: 1
            top: 65535
        }
        onAccepted: form.submit()
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Kirigami.Units.largeSpacing
        rowSpacing: Kirigami.Units.smallSpacing

        FieldLabel { text: i18n("Label:") }
        PlasmaComponents3.TextField {
            id: labelField
            Layout.fillWidth: true
            placeholderText: i18n("Optional, e.g. Staging database")
            onAccepted: form.submit()
        }

        // "3000 on localhost": the address is optional and reads as part
        // of the port, so it shares its row.
        FieldLabel { text: i18n("Local port:") }
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PortBox {
                id: localPort
                onTextChanged: {
                    if (!form.remotePortTouched)
                        remotePort.text = text;
                }
            }
            PlasmaComponents3.Label {
                text: i18nc("between the local port and the address it listens on, as in 3000 on localhost", "on")
                opacity: 0.75
            }
            PlasmaComponents3.TextField {
                id: bindField
                Layout.fillWidth: true
                placeholderText: "localhost"
                font.family: Kirigami.Theme.fixedWidthFont.family
                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                Accessible.name: i18n("Bind address")
                onTextEdited: form.bindChecked = false
                onEditingFinished: form.bindChecked = true
                onAccepted: form.submit()

                PlasmaComponents3.ToolTip.text: i18n("Bind address: where the tunnel listens on this machine. Leave empty for localhost; another loopback address such as 127.0.1.1 lets several tunnels use the same port.")
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
            }
        }

        // Shown only when it matters: a malformed address, or one other
        // machines can reach. Neither is a reason to refuse an exposed one.
        Item {
            visible: bindNote.visible
            implicitWidth: 1
        }
        PlasmaComponents3.Label {
            id: bindNote
            Layout.fillWidth: true
            readonly property bool invalid: form.bindAddress === null && form.bindChecked
            readonly property bool exposed: form.bindAddress !== null && !Logic.isLoopbackBind(form.bindAddress)
            visible: invalid || exposed
            text: invalid ? i18n("Use an IP address, localhost or *")
                          : i18n("Reachable from other machines on your network")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: invalid ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor
            font: Kirigami.Theme.smallFont
        }

        FieldLabel { text: i18n("SSH host:") }
        PlasmaComponents3.TextField {
            id: hostField
            Layout.fillWidth: true
            placeholderText: i18n("Host from ~/.ssh/config, or user@host")
            onAccepted: form.submit()
        }

        // Hosts from ~/.ssh/config that match what has been typed.
        Item {
            visible: suggestions.visible
            implicitWidth: 1
        }
        Flow {
            id: suggestions
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            readonly property var matches: {
                const typed = hostField.text.trim().toLowerCase();
                const hosts = form.service.sshHosts;
                const out = [];
                for (let i = 0; i < hosts.length && out.length < 12; i++) {
                    const h = hosts[i];
                    if (h.toLowerCase() === typed)
                        return [];
                    if (typed === "" || h.toLowerCase().indexOf(typed) >= 0)
                        out.push(h);
                }
                return out;
            }
            visible: matches.length > 0

            Repeater {
                model: suggestions.matches
                delegate: PlasmaComponents3.ToolButton {
                    required property string modelData
                    text: modelData
                    icon.name: "network-server-symbolic"
                    font: Kirigami.Theme.smallFont
                    onClicked: {
                        hostField.text = modelData;
                        remoteHostField.forceActiveFocus();
                    }
                }
            }
        }

        FieldLabel { text: i18n("Remote host:") }
        PlasmaComponents3.TextField {
            id: remoteHostField
            Layout.fillWidth: true
            placeholderText: "localhost"
            onAccepted: form.submit()
        }

        FieldLabel { text: i18n("Remote port:") }
        PortBox {
            id: remotePort
            onTextEdited: form.remotePortTouched = true
        }

        FieldLabel { text: i18n("Extra options:") }
        PlasmaComponents3.TextField {
            id: extraField
            Layout.fillWidth: true
            placeholderText: i18n("Optional ssh flags, e.g. -J bastion")
            onAccepted: form.submit()
        }

        Item {
            implicitWidth: 1
        }
        PlasmaComponents3.CheckBox {
            id: autostartBox
            Layout.fillWidth: true
            text: i18n("Start when Plasma starts")
        }
    }

    PlasmaComponents3.Label {
        Layout.fillWidth: true
        text: i18n("Options are split on spaces; anything that needs quoting belongs in ~/.ssh/config.").replace(/\//g, "/\u2060")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        font: Kirigami.Theme.smallFont
        opacity: 0.75
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        Item {
            Layout.fillWidth: true
        }
        PlasmaComponents3.Button {
            text: i18n("Cancel")
            icon.name: "dialog-cancel"
            onClicked: form.done()
        }
        PlasmaComponents3.Button {
            text: form.editing ? i18n("Save") : i18n("Add")
            icon.name: form.editing ? "document-save" : "list-add"
            onClicked: form.submit()
        }
    }
}
