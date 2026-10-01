pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "../Utils.js" as Utils

// Modal trash browser with restore / delete / empty actions. Operations are
// delegated to the host through signals; `loadList` supplies the JSON listing.
Item {
    id: tp
    property bool shown: false
    property var items: []
    property var loadList: null

    signal restoreRequested(var names)
    signal deleteRequested(var names)
    signal emptyRequested()

    function reload() {
        let data = [];
        try { data = JSON.parse(tp.loadList ? tp.loadList() : "[]"); } catch (e) { data = []; }
        tp.items = data;
    }

    anchors.fill: parent
    z: 105
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    focus: shown
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    onShownChanged: if (shown) tp.forceActiveFocus()
    Keys.onEscapePressed: (e) => { tp.shown = false; e.accepted = true; }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: tp.shown = false }
    }

    Rectangle {
        id: tpPanel
        anchors.centerIn: parent
        width: Math.min(640, tp.parent ? tp.parent.width - 48 : 592)
        height: Math.min(520, tp.parent ? tp.parent.height - 80 : 440)
        radius: Theme.radiusLarge
        color: Theme.surface2
        border.width: 1
        border.color: Theme.border
        scale: tp.shown ? 1 : 0.96
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.04 }
        }
        MouseArea { anchors.fill: parent }

        Text {
            id: tpTitle
            anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 18 }
            text: "Trash"
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Text {
            anchors { left: tpTitle.right; leftMargin: 10; verticalCenter: tpTitle.verticalCenter }
            text: tp.items.length + (tp.items.length === 1 ? " item" : " items")
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 11
        }
        Row {
            anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 14 }
            spacing: 8
            ActionButton {
                visible: tp.items.length > 0
                label: "Empty Trash"
                danger: true
                onActivated: tp.emptyRequested()
            }
            ActionButton {
                label: "Close"
                onActivated: tp.shown = false
            }
        }

        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 52 }
            height: 1
            color: Theme.border
        }

        ListView {
            anchors {
                left: parent.left; right: parent.right
                top: parent.top; bottom: parent.bottom
                topMargin: 58; bottomMargin: 12
                leftMargin: 12; rightMargin: 12
            }
            clip: true
            model: tp.items
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: trow
                required property var modelData

                width: ListView.view.width
                height: 48
                radius: Theme.radiusSmall
                color: tMa.containsMouse ? Theme.hover : "transparent"

                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    text: trow.modelData.dir ? "\uf07b" : "\uf15b"
                    color: Theme.textDim
                    font.family: Theme.icon
                    font.pixelSize: 15
                }
                Column {
                    anchors {
                        left: parent.left; leftMargin: 40
                        right: tActions.left; rightMargin: 12
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 2
                    Text {
                        width: parent.width
                        text: trow.modelData.original !== "" ? trow.modelData.original : trow.modelData.name
                        color: Theme.text
                        font.family: Theme.font
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Text {
                        text: Utils.fmtTime(trow.modelData.deleted)
                        color: Theme.textDim
                        font.family: Theme.font
                        font.pixelSize: 10
                    }
                }
                Row {
                    id: tActions
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 6
                    ActionButton {
                        label: "Restore"
                        opacity: trow.modelData.known ? 1 : 0.4
                        onActivated: if (trow.modelData.known) tp.restoreRequested([trow.modelData.name])
                    }
                    ActionButton {
                        label: "Delete"
                        danger: true
                        onActivated: tp.deleteRequested([trow.modelData.name])
                    }
                }
                MouseArea {
                    id: tMa
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: tp.items.length === 0
            text: "Trash is empty"
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 13
        }
    }
}
