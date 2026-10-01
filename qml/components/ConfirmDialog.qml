import QtQuick
import ".."

// Modal confirmation for destructive actions.
Item {
    id: cd
    property bool shown: false
    property string title: ""
    property string message: ""
    property string confirmLabel: "OK"
    property bool danger: false
    signal confirmed()
    signal cancelled()

    anchors.fill: parent
    z: 110
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    focus: shown
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    onShownChanged: if (shown) cd.forceActiveFocus()
    Keys.onEscapePressed: (e) => { cd.cancelled(); e.accepted = true; }
    Keys.onReturnPressed: (e) => { cd.confirmed(); e.accepted = true; }
    Keys.onEnterPressed: (e) => { cd.confirmed(); e.accepted = true; }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: cd.cancelled() }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(420, cd.parent ? cd.parent.width - 48 : 372)
        height: 168
        radius: Theme.radiusLarge
        color: Theme.surface2
        border.width: 1
        border.color: Theme.border
        scale: cd.shown ? 1 : 0.94
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.06 }
        }
        MouseArea { anchors.fill: parent }

        Text {
            id: cIcon
            anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 20 }
            text: cd.danger ? "\uf2ed" : "\uf1f8"
            color: cd.danger ? Theme.danger : Theme.accent
            font.family: Theme.icon
            font.pixelSize: 18
        }
        Text {
            anchors {
                left: cIcon.right; leftMargin: 12
                right: parent.right; rightMargin: 20
                verticalCenter: cIcon.verticalCenter
            }
            text: cd.title
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 14
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Text {
            anchors {
                left: parent.left; right: parent.right; top: parent.top
                leftMargin: 20; rightMargin: 20; topMargin: 58
            }
            text: cd.message
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
        Row {
            anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 16 }
            spacing: 8
            ActionButton { label: "Cancel"; onActivated: cd.cancelled() }
            ActionButton {
                label: cd.confirmLabel
                primary: !cd.danger
                danger: cd.danger
                onActivated: cd.confirmed()
            }
        }
    }
}
