import QtQuick
import ".."

// Small circular icon button used across the toolbars.
Rectangle {
    id: btn
    property string glyph
    property bool active: false
    signal activated()

    width: 32
    height: 32
    radius: height / 2
    color: (ma.containsMouse || btn.active) ? Theme.hover : "transparent"
    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
        anchors.centerIn: parent
        text: btn.glyph
        color: btn.active ? Theme.text : Theme.textDim
        font.family: Theme.icon
        font.pixelSize: 14
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.activated()
    }
}
