import QtQuick
import ".."

// Rounded search input for filtering the current directory.
Rectangle {
    id: sf
    property alias text: sInput.text
    signal accepted()
    signal moveUp()
    signal moveDown()
    signal escaped()

    function focusInput() { sInput.forceActiveFocus(); sInput.selectAll(); }

    height: 32
    radius: height / 2
    color: Theme.surface2
    border.width: 1
    border.color: sInput.activeFocus ? Theme.accent : Theme.border
    Behavior on border.color { ColorAnimation { duration: 120 } }

    Text {
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
        text: "\uf002"
        color: Theme.textDim
        font.family: Theme.icon
        font.pixelSize: 12
    }
    TextInput {
        id: sInput
        anchors {
            left: parent.left; leftMargin: 32
            right: parent.right; rightMargin: 12
            verticalCenter: parent.verticalCenter
        }
        color: Theme.text
        font.family: Theme.font
        font.pixelSize: 12
        selectionColor: Theme.accent
        selectedTextColor: Theme.bg
        clip: true
        onAccepted: sf.accepted()
        Keys.onDownPressed: (e) => { sf.moveDown(); e.accepted = true; }
        Keys.onUpPressed: (e) => { sf.moveUp(); e.accepted = true; }
        Keys.onEscapePressed: (e) => { sInput.text = ""; sf.escaped(); e.accepted = true; }
    }
}
