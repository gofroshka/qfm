import QtQuick
import ".."

// Pill-shaped labelled button for dialogs and the status bar.
Rectangle {
    id: ab
    property string label
    property bool primary: false
    property bool danger: false
    signal activated()

    implicitWidth: abText.implicitWidth + 30
    implicitHeight: 28
    radius: height / 2
    color: ab.primary ? Theme.accent
         : ab.danger ? Qt.rgba(0.9, 0.42, 0.39, 0.14)
         : Theme.hover
    border.width: 1
    border.color: ab.primary ? "transparent"
                : ab.danger ? Qt.rgba(0.9, 0.42, 0.39, 0.35)
                : Theme.border
    Behavior on color { ColorAnimation { duration: 110 } }
    Behavior on border.color { ColorAnimation { duration: 110 } }

    Text {
        id: abText
        anchors.centerIn: parent
        text: ab.label
        color: ab.primary ? Theme.bg : ab.danger ? Theme.danger : Theme.text
        font.family: Theme.font
        font.pixelSize: 12
        font.weight: Font.Medium
    }
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ab.activated()
    }
}
