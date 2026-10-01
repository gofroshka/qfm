import QtQuick
import ".."

// Transient bottom toast with an optional single action (e.g. Undo).
Rectangle {
    id: tst
    property bool shown: false
    property string message: ""
    property string actionLabel: ""
    property var action: null

    function show(t) {
        tst.actionLabel = "";
        tst.action = null;
        tst.message = t;
        tst.shown = true;
        timer.restart();
    }
    function showUndo(t, cb) {
        tst.actionLabel = "Undo";
        tst.action = cb;
        tst.message = t;
        tst.shown = true;
        timer.restart();
    }

    z: 130
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min((parent ? parent.width : 960) - 40, content.implicitWidth + 44)
    height: 36
    radius: height / 2
    color: Theme.elevated
    border.width: 1
    border.color: Theme.border
    opacity: shown ? 1 : 0
    scale: shown ? 1 : 0.96
    y: shown ? parent.height - height - 46 : parent.height - height - 26
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 1.04 } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 14

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: tst.message
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 12
        }
        ActionButton {
            visible: tst.actionLabel.length > 0
            anchors.verticalCenter: parent.verticalCenter
            label: tst.actionLabel
            primary: true
            onActivated: {
                const fn = tst.action;
                tst.shown = false;
                if (fn) fn();
            }
        }
    }
    Timer { id: timer; interval: 4200; repeat: false; onTriggered: tst.shown = false }
}
