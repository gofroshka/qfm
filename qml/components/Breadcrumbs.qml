pragma ComponentBehavior: Bound

import QtQuick
import ".."

// Horizontally scrolling breadcrumb bar. `model` is a list of {name, path}.
Flickable {
    id: crumbs
    property var model: []
    property string currentPath: ""
    signal navigate(string path)

    height: 28
    contentWidth: crumbRow.width
    clip: true
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds

    function toEnd() { contentX = Math.max(0, contentWidth - width); }
    onContentWidthChanged: toEnd()
    onWidthChanged: toEnd()
    onCurrentPathChanged: toEnd()

    Row {
        id: crumbRow
        height: crumbs.height
        spacing: 0

        Repeater {
            model: crumbs.model

            delegate: Item {
                id: crumb
                required property var modelData
                required property int index

                width: crumbBtn.width + crumbSep.width
                height: crumbs.height

                Rectangle {
                    id: crumbBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: crumbText.implicitWidth + 16
                    height: 24
                    radius: 12
                    color: crumbMa.containsMouse ? Theme.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: 90 } }

                    Text {
                        id: crumbText
                        anchors.centerIn: parent
                        text: crumb.modelData.name
                        color: crumb.modelData.path === crumbs.currentPath ? Theme.text : Theme.textDim
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: crumbMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: crumbs.navigate(crumb.modelData.path)
                    }
                }

                Text {
                    id: crumbSep
                    anchors { left: crumbBtn.right; verticalCenter: parent.verticalCenter }
                    visible: crumb.index < crumbs.model.length - 1
                    width: visible ? 14 : 0
                    text: "\uf105"
                    color: Theme.textDim
                    font.family: Theme.icon
                    font.pixelSize: 9
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
