import QtQuick
import ".."

// Reusable progress / seek bar. Emits an absolute target position on click.
Item {
    id: bar
    property real position: 0
    property real duration: 0
    signal seekRequested(real position)

    implicitHeight: 16

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 5
        radius: 2.5
        color: Theme.track
        Rectangle {
            height: parent.height
            radius: 2.5
            color: Theme.accent
            width: bar.duration > 0
                   ? track.width * Math.max(0, Math.min(1, bar.position / bar.duration))
                   : 0
        }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: (m) => {
            if (bar.duration > 0)
                bar.seekRequested(Math.max(0, Math.min(1, m.x / width)) * bar.duration);
        }
    }
}
