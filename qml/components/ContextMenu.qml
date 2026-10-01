pragma ComponentBehavior: Bound

import QtQuick
import ".."

// Floating right-click menu driven by an `items` model of
// {label, glyph, act, key, danger, sep} objects.
Rectangle {
    id: menuPopup
    property bool shown: false
    property var items: []
    readonly property int rowHeight: 30
    readonly property int sepHeight: 9
    signal chosen(string act)

    width: 218
    implicitHeight: {
        let h = 8;
        for (let i = 0; i < items.length; i++) h += items[i].sep ? sepHeight : rowHeight;
        return h;
    }
    height: implicitHeight
    radius: Theme.radiusMedium
    color: Theme.elevated
    border.width: 1
    border.color: Theme.border
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    scale: shown ? 1 : 0.97
    transformOrigin: Item.TopLeft
    z: 95
    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Column {
        id: menuCol
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
        Repeater {
            model: menuPopup.items
            delegate: Item {
                id: menuRow
                required property var modelData
                width: menuCol.width
                height: menuRow.modelData.sep ? menuPopup.sepHeight : menuPopup.rowHeight

                Rectangle {
                    visible: menuRow.modelData.sep === true
                    anchors {
                        left: parent.left; right: parent.right
                        leftMargin: 10; rightMargin: 10
                        verticalCenter: parent.verticalCenter
                    }
                    height: 1
                    color: Theme.border
                }

                Rectangle {
                    visible: menuRow.modelData.sep !== true
                    anchors.fill: parent
                    radius: Theme.radiusSmall
                    color: itemMa.containsMouse ? Theme.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: 90 } }

                    Text {
                        id: rowIcon
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        width: 16
                        text: menuRow.modelData.glyph || ""
                        color: menuRow.modelData.danger ? Theme.danger : Theme.textDim
                        font.family: Theme.icon
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        id: rowHint
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: menuRow.modelData.key || ""
                        color: Theme.textDim
                        font.family: Theme.font
                        font.pixelSize: 10
                        opacity: 0.75
                    }
                    Text {
                        anchors {
                            left: rowIcon.right; leftMargin: 10
                            right: rowHint.left; rightMargin: 10
                            verticalCenter: parent.verticalCenter
                        }
                        text: menuRow.modelData.label
                        color: menuRow.modelData.danger ? Theme.danger : Theme.text
                        font.family: Theme.font
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: menuPopup.chosen(menuRow.modelData.act)
                    }
                }
            }
        }
    }
}
