import QtQuick
import ".."
import "../Utils.js" as Utils

// A single file/folder row in the main list.
Rectangle {
    id: row
    required property var modelData
    required property int index
    property bool selected: false

    signal rowActivated(int index)
    signal rowClicked(int index, int modifiers)
    signal rowContext(int index, real x, real y)

    width: ListView.view.width
    height: Theme.rowHeight
    radius: Theme.radiusSmall
    color: row.selected ? Qt.rgba(1, 1, 1, 0.11) : rowMa.containsMouse ? Theme.hover : "transparent"
    Behavior on color {
        ColorAnimation {
            duration: 100
        }
    }

    opacity: 0
    SequentialAnimation {
        id: entrance
        PauseAnimation {
            duration: Math.min(row.index, 10) * 12
        }
        NumberAnimation {
            target: row
            property: "opacity"
            to: 1
            duration: 200
            easing.type: Easing.OutCubic
        }
    }
    Component.onCompleted: entrance.start()

    Row {
        anchors {
            fill: parent
            leftMargin: 10
            rightMargin: 14
        }
        spacing: 12

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Utils.iconFor(row.modelData)
            color: row.modelData.link ? Theme.link : row.modelData.dir ? Theme.accent : Theme.textDim
            font.family: Theme.icon
            font.pixelSize: 15
            width: 20
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 20 - 90 - 130 - 36
            text: row.modelData.name
            color: row.modelData.hidden ? Theme.textDim : Theme.text
            font.family: Theme.font
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 90
            horizontalAlignment: Text.AlignRight
            text: Utils.fmtSize(row.modelData)
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 11
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 130
            horizontalAlignment: Text.AlignRight
            text: Utils.fmtTime(row.modelData.mtime)
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 11
        }
    }

    MouseArea {
        id: rowMa
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                const p = rowMa.mapToItem(null, mouse.x, mouse.y);
                row.rowContext(row.index, p.x, p.y);
            } else {
                row.rowClicked(row.index, mouse.modifiers);
            }
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton)
                row.rowActivated(row.index);
        }
    }
}
