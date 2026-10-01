import QtQuick
import ".."
import "../Utils.js" as Utils

// A single file/folder row in the main list.
Rectangle {
    id: row
    required property var modelData
    required property int index
    property bool selected: false
    // Hover is tracked by the list overlay, not by a MouseArea here.
    property bool hovered: false

    signal rowContext(int index, real x, real y)
    // A drop landed on this (folder) row: move/copy `uris` into `target`.
    signal dropRequested(string target, var uris, bool internal)

    width: ListView.view.width
    height: Theme.rowHeight
    radius: Theme.radiusSmall
    color: row.dropActive ? Qt.rgba(0.84, 0.84, 0.86, 0.18)
         : row.selected ? Qt.rgba(1, 1, 1, 0.11)
         : row.hovered ? Theme.hover
         : "transparent"
    border.width: row.dropActive ? 1 : 0
    border.color: Theme.accent
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

    // Drop target for folder rows: move the dragged selection inside.
    DropArea {
        id: dropTarget
        anchors.fill: parent
        enabled: row.modelData.dir
        onDropped: drop => {
            if (!drop.hasUrls)
                return;
            const uris = [];
            for (let i = 0; i < drop.urls.length; i++) uris.push(String(drop.urls[i]));
            drop.accept(Qt.MoveAction);
            row.dropRequested(row.modelData.path, uris,
                              drop.formats.indexOf("application/x-qfm-internal") >= 0);
        }
    }

    readonly property bool dropActive: dropTarget.containsDrag

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

    // Right-click only; left-button interaction lives in the list overlay.
    MouseArea {
        id: rowMa
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => {
            const p = rowMa.mapToItem(null, mouse.x, mouse.y);
            row.rowContext(row.index, p.x, p.y);
        }
    }
}
