import QtQuick
import ".."

// Single-line text prompt used for New file / New folder / Rename.
Item {
    id: pd
    property bool shown: false
    property string title: ""
    property string glyph: "\uf15b"
    property string placeholder: "Name"
    property string value: ""
    property string confirmLabel: "Create"
    signal accepted(string text)
    signal cancelled()

    anchors.fill: parent
    z: 100
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    onShownChanged: if (shown) {
        pInput.text = pd.value;
        Qt.callLater(function() { pInput.forceActiveFocus(); pInput.selectAll(); });
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: pd.cancelled() }
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(420, pd.parent ? pd.parent.width - 48 : 372)
        height: 172
        radius: Theme.radiusLarge
        color: Theme.surface2
        border.width: 1
        border.color: Theme.border
        scale: pd.shown ? 1 : 0.94
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.06 }
        }
        MouseArea { anchors.fill: parent }

        Text {
            id: pIcon
            anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 20 }
            text: pd.glyph
            color: Theme.accent
            font.family: Theme.icon
            font.pixelSize: 18
        }
        Text {
            anchors {
                left: pIcon.right; leftMargin: 12
                right: parent.right; rightMargin: 20
                verticalCenter: pIcon.verticalCenter
            }
            text: pd.title
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 14
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }

        Rectangle {
            id: field
            anchors {
                left: parent.left; right: parent.right; top: parent.top
                leftMargin: 20; rightMargin: 20; topMargin: 62
            }
            height: 40
            radius: 10
            color: Theme.bg
            border.width: 1
            border.color: pInput.activeFocus ? Theme.accent : Theme.border
            Behavior on border.color { ColorAnimation { duration: 120 } }

            TextInput {
                id: pInput
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 13
                selectionColor: Theme.accent
                selectedTextColor: Theme.bg
                clip: true
                onAccepted: pd.accepted(text)
                Keys.onEscapePressed: (e) => { pd.cancelled(); e.accepted = true; }
            }
            Text {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                visible: pInput.text.length === 0
                text: pd.placeholder
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 13
            }
        }

        Row {
            anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 16 }
            spacing: 8
            ActionButton { label: "Cancel"; onActivated: pd.cancelled() }
            ActionButton {
                label: pd.confirmLabel
                primary: true
                onActivated: pd.accepted(pInput.text)
            }
        }
    }
}
