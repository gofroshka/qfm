import QtQuick
import ".."

// Centered placeholder shown when the visible listing is empty.
Column {
    id: empty
    property bool filtered: false

    spacing: 8

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: empty.filtered ? "\uf002" : "\uf07b"
        color: Theme.track
        font.family: Theme.icon
        font.pixelSize: 34
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: empty.filtered ? "No matches" : "Empty folder"
        color: Theme.textDim
        font.family: Theme.font
        font.pixelSize: 13
    }
}
