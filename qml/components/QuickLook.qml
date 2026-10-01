import QtQuick
import QtMultimedia
import ".."
import "../Utils.js" as Utils

// Full-window preview overlay with image zoom/pan, video and audio playback
// and a text/code viewer. Navigation is delegated to the host via
// `stepRequested`.
Item {
    id: ql
    property bool shown: false
    property var entry: null
    property int index: 0
    property int total: 0
    // Injected backend functions: (path) -> uri, (path, max) -> text.
    property var fileUri: null
    property var readText: null

    property string source: ""
    property string text: ""
    property real zoom: 1
    property real panX: 0
    property real panY: 0

    readonly property bool image: Utils.isImage(entry)
    readonly property bool video: Utils.isVideo(entry)
    readonly property bool audio: Utils.isAudio(entry)
    readonly property bool textMode: Utils.isText(entry) && text !== ""
    readonly property bool fallback: entry !== null && !image && !video && !audio && !textMode

    signal stepRequested(int delta)
    signal closed()

    function open(e) {
        qlVideo.stop();
        qlAudio.stop();
        ql.entry = e;
        ql.source = "";
        ql.text = "";
        ql.zoom = 1;
        ql.panX = 0;
        ql.panY = 0;
        if (e && !e.dir) {
            if (Utils.isImage(e) || Utils.isVideo(e) || Utils.isAudio(e)) {
                ql.source = ql.fileUri ? ql.fileUri(e.path) : "";
                if (Utils.isVideo(e)) qlVideo.play();
            } else if (Utils.isText(e)) {
                ql.text = ql.readText ? ql.readText(e.path, 300000) : "";
            }
        }
        ql.shown = true;
        ql.forceActiveFocus();
    }
    function close() {
        qlVideo.stop();
        qlAudio.stop();
        ql.shown = false;
        ql.closed();
    }
    function step(d) { ql.stepRequested(d); }

    anchors.fill: parent
    z: 108
    focus: shown
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 140 } }

    Keys.onEscapePressed: (e) => { ql.close(); e.accepted = true; }
    Keys.onReturnPressed: (e) => { ql.close(); e.accepted = true; }
    Keys.onEnterPressed: (e) => { ql.close(); e.accepted = true; }
    Keys.onLeftPressed: (e) => { ql.step(-1); e.accepted = true; }
    Keys.onRightPressed: (e) => { ql.step(1); e.accepted = true; }
    Keys.onUpPressed: (e) => { ql.step(-1); e.accepted = true; }
    Keys.onDownPressed: (e) => { ql.step(1); e.accepted = true; }
    Keys.onSpacePressed: (e) => { ql.close(); e.accepted = true; }
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Plus || e.key === Qt.Key_Equal) {
            ql.zoom = Math.min(8, ql.zoom * 1.25); e.accepted = true;
        } else if (e.key === Qt.Key_Minus) {
            ql.zoom = Math.max(0.2, ql.zoom / 1.25); e.accepted = true;
        } else if (e.key === Qt.Key_0) {
            ql.zoom = 1; ql.panX = 0; ql.panY = 0; e.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        MouseArea { anchors.fill: parent; onClicked: ql.close() }
    }

    // image: zoom + pan
    Item {
        id: imageStage
        anchors.fill: parent
        anchors.margins: 48
        anchors.bottomMargin: 44
        visible: ql.image
        clip: true

        Image {
            id: qlImage
            source: ql.image ? ql.source : ""
            asynchronous: true
            cache: false
            sourceSize.width: 4096
            sourceSize.height: 4096
            fillMode: Image.PreserveAspectFit
            width: parent.width
            height: parent.height
            scale: ql.zoom
            transformOrigin: Item.Center
            x: (parent.width - width) / 2 + ql.panX
            y: (parent.height - height) / 2 + ql.panY
            Behavior on scale { NumberAnimation { duration: 120 } }
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            property real lastX
            property real lastY
            cursorShape: (pressed && ql.zoom > 1) ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: (m) => { lastX = m.x; lastY = m.y; }
            onPositionChanged: (m) => {
                if (pressed && ql.zoom > 1) {
                    ql.panX += m.x - lastX;
                    ql.panY += m.y - lastY;
                    lastX = m.x;
                    lastY = m.y;
                }
            }
            onDoubleClicked: { ql.zoom = ql.zoom > 1 ? 1 : 2; ql.panX = 0; ql.panY = 0; }
            onWheel: (w) => {
                ql.zoom = Math.max(0.2, Math.min(8, ql.zoom * (w.angleDelta.y > 0 ? 1.15 : 0.87)));
            }
        }
    }

    // video
    Video {
        id: qlVideo
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -26
        width: Math.min(parent.width - 96, 1280)
        height: Math.min(parent.height - 168, width * 9 / 16)
        visible: ql.video
        source: ql.video ? ql.source : ""
        fillMode: VideoOutput.PreserveAspectFit
        autoPlay: true
        onSourceChanged: if (source !== "") play()

        MouseArea {
            anchors.fill: parent
            onClicked: qlVideo.playbackState === MediaPlayer.PlayingState ? qlVideo.pause() : qlVideo.play()
        }
    }

    // video controls
    Column {
        id: videoControls
        visible: ql.video
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 96, 900)
        spacing: 10

        Row {
            width: parent.width
            spacing: 10
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 52
                text: Utils.fmtClock(qlVideo.position)
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 10
            }
            SeekBar {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 52 - 52 - 20
                position: qlVideo.position
                duration: qlVideo.duration
                onSeekRequested: (pos) => qlVideo.position = pos
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 52
                horizontalAlignment: Text.AlignRight
                text: Utils.fmtClock(qlVideo.duration)
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 10
            }
        }

        MediaControls {
            anchors.horizontalCenter: parent.horizontalCenter
            playing: qlVideo.playbackState === MediaPlayer.PlayingState
            rewindGlyph: "\uf051"
            forwardGlyph: "\uf050"
            onRewind: qlVideo.position = Math.max(0, qlVideo.position - 10000)
            onForward: qlVideo.position = Math.min(qlVideo.duration, qlVideo.position + 10000)
            onTogglePlay: qlVideo.playbackState === MediaPlayer.PlayingState
                          ? qlVideo.pause() : qlVideo.play()
        }
    }

    // audio
    MediaPlayer {
        id: qlAudio
        audioOutput: AudioOutput {}
        source: ql.audio ? ql.source : ""
        onSourceChanged: stop()
    }
    Rectangle {
        visible: ql.audio
        anchors.centerIn: parent
        width: Math.min(parent.width - 96, 460)
        height: 220
        radius: Theme.radiusLarge
        color: Theme.surface2
        border.width: 1
        border.color: Theme.border

        Column {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 14

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\uf1c7"
                color: Theme.accent
                font.family: Theme.icon
                font.pixelSize: 44
            }
            Text {
                width: parent.width
                text: ql.entry ? ql.entry.name : ""
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
            }
            SeekBar {
                width: parent.width
                position: qlAudio.position
                duration: qlAudio.duration
                onSeekRequested: (pos) => qlAudio.position = pos
            }
            Row {
                width: parent.width
                Text {
                    width: parent.width / 2
                    text: Utils.fmtClock(qlAudio.position)
                    color: Theme.textDim
                    font.family: Theme.font
                    font.pixelSize: 10
                }
                Text {
                    width: parent.width / 2
                    horizontalAlignment: Text.AlignRight
                    text: Utils.fmtClock(qlAudio.duration)
                    color: Theme.textDim
                    font.family: Theme.font
                    font.pixelSize: 10
                }
            }
            MediaControls {
                anchors.horizontalCenter: parent.horizontalCenter
                playing: qlAudio.playbackState === MediaPlayer.PlayingState
                onRewind: qlAudio.position = Math.max(0, qlAudio.position - 10000)
                onForward: qlAudio.position = Math.min(qlAudio.duration, qlAudio.position + 10000)
                onTogglePlay: qlAudio.playbackState === MediaPlayer.PlayingState
                              ? qlAudio.pause() : qlAudio.play()
            }
        }
    }

    // text / code
    Flickable {
        id: textStage
        visible: ql.textMode
        anchors.fill: parent
        anchors.margins: 40
        anchors.topMargin: 64
        anchors.bottomMargin: 44
        clip: true
        contentWidth: qlTextEdit.contentWidth + 8
        contentHeight: qlTextEdit.contentHeight + 8
        boundsBehavior: Flickable.StopAtBounds

        TextEdit {
            id: qlTextEdit
            x: 4; y: 4
            width: textStage.width
            text: ql.text
            readOnly: true
            wrapMode: TextEdit.NoWrap
            color: Theme.text
            selectionColor: Theme.accent
            selectedTextColor: Theme.bg
            font.family: Theme.mono
            font.pixelSize: 12
        }
    }

    // fallback: dirs, binaries, empty text
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: ql.fallback
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ql.entry ? Utils.iconFor(ql.entry) : "\uf15b"
            color: Theme.track
            font.family: Theme.icon
            font.pixelSize: 72
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ql.entry ? ql.entry.name : ""
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 15
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Utils.describe(ql.entry)
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 11
        }
    }

    // header + hint
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 48
        color: Qt.rgba(0, 0, 0, 0.35)
        Text {
            anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
            width: parent.width - 260
            text: ql.entry ? ql.entry.name : ""
            color: Theme.text
            font.family: Theme.font
            font.pixelSize: 13
            elide: Text.ElideMiddle
        }
        Text {
            anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
            text: (ql.index + 1) + " / " + ql.total
                  + "   \u2190\u2192 next \u00b7 +/\u2212 zoom \u00b7 Esc close"
            color: Theme.textDim
            font.family: Theme.font
            font.pixelSize: 10
        }
    }
}
