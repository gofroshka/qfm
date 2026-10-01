import QtQuick
import QtMultimedia
import ".."
import "../Utils.js" as Utils

// Right-hand preview panel: photo, audio player, text snippet or metadata.
Rectangle {
    id: panel
    property bool shown: true
    property var entry: null
    property string imageSource: ""
    property string audioSource: ""
    property string textSample: ""

    readonly property bool image: Utils.isImage(entry)
    readonly property bool audio: Utils.isAudio(entry)
    readonly property bool text: Utils.isText(entry) && textSample !== ""

    width: shown ? 320 : 0
    radius: Theme.radiusSmall
    color: Theme.surface2
    border.width: 1
    border.color: Theme.border
    clip: true
    visible: width > 1
    opacity: shown ? 1 : 0
    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 140 } }

    // Declared here so playback state survives selection changes.
    MediaPlayer {
        id: player
        source: panel.audio ? panel.audioSource : ""
        audioOutput: AudioOutput { volume: 1.0 }
        onSourceChanged: player.stop()
    }
    onShownChanged: if (!shown) player.stop()

    Flickable {
        anchors.fill: parent
        anchors.margins: 12
        contentWidth: width
        contentHeight: body.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: body
            width: parent.width
            spacing: 12

            // photo
            Rectangle {
                width: parent.width
                height: panel.image ? Math.round(width * 0.72) : 0
                visible: panel.image
                radius: Theme.radiusSmall
                color: Theme.bg
                clip: true
                Image {
                    anchors.fill: parent
                    anchors.margins: 2
                    source: panel.imageSource
                    asynchronous: true
                    cache: false
                    sourceSize.width: 1024
                    sourceSize.height: 1024
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }
            }

            // audio
            Rectangle {
                width: parent.width
                height: 208
                visible: panel.audio
                radius: Theme.radiusSmall
                color: Theme.bg

                Column {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "\uf1c7"
                        color: Theme.accent
                        font.family: Theme.icon
                        font.pixelSize: 38
                    }
                    Text {
                        width: parent.width
                        text: panel.entry ? panel.entry.name : ""
                        color: Theme.text
                        font.family: Theme.font
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideMiddle
                    }

                    SeekBar {
                        width: parent.width
                        position: player.position
                        duration: player.duration
                        onSeekRequested: (pos) => player.position = pos
                    }

                    Row {
                        width: parent.width
                        Text {
                            width: parent.width / 2
                            text: Utils.fmtClock(player.position)
                            color: Theme.textDim
                            font.family: Theme.font
                            font.pixelSize: 10
                        }
                        Text {
                            width: parent.width / 2
                            horizontalAlignment: Text.AlignRight
                            text: Utils.fmtClock(player.duration)
                            color: Theme.textDim
                            font.family: Theme.font
                            font.pixelSize: 10
                        }
                    }

                    MediaControls {
                        anchors.horizontalCenter: parent.horizontalCenter
                        playing: player.playbackState === MediaPlayer.PlayingState
                        onRewind: player.position = Math.max(0, player.position - 10000)
                        onForward: player.position = Math.min(player.duration, player.position + 10000)
                        onTogglePlay: player.playbackState === MediaPlayer.PlayingState
                                      ? player.pause() : player.play()
                    }
                }
            }

            // text / code snippet
            Rectangle {
                width: parent.width
                height: 200
                visible: panel.text
                radius: Theme.radiusSmall
                color: Theme.bg
                clip: true
                Flickable {
                    anchors.fill: parent
                    anchors.margins: 10
                    clip: true
                    contentWidth: panelText.contentWidth
                    contentHeight: panelText.contentHeight
                    boundsBehavior: Flickable.StopAtBounds
                    TextEdit {
                        id: panelText
                        width: parent.width
                        text: panel.textSample
                        readOnly: true
                        wrapMode: TextEdit.NoWrap
                        color: Theme.textDim
                        selectionColor: Theme.accent
                        selectedTextColor: Theme.bg
                        font.family: Theme.mono
                        font.pixelSize: 10
                    }
                }
            }

            // generic file
            Column {
                width: parent.width
                spacing: 10
                visible: panel.entry !== null && !panel.image && !panel.audio && !panel.text
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Utils.iconFor(panel.entry)
                    color: Theme.track
                    font.family: Theme.icon
                    font.pixelSize: 44
                }
            }

            // details
            Column {
                width: parent.width
                spacing: 6
                visible: panel.entry !== null
                Text {
                    width: parent.width
                    text: panel.entry ? panel.entry.name : ""
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    wrapMode: Text.WrapAnywhere
                }
                Text {
                    width: parent.width
                    text: Utils.describe(panel.entry)
                    color: Theme.textDim
                    font.family: Theme.font
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    visible: panel.entry !== null
                    text: panel.entry ? panel.entry.path : ""
                    color: Theme.textDim
                    font.family: Theme.font
                    font.pixelSize: 10
                    opacity: 0.7
                    wrapMode: Text.WrapAnywhere
                }
            }

            // no selection
            Text {
                width: parent.width
                visible: panel.entry === null
                text: "Nothing selected"
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 12
                horizontalAlignment: Text.AlignHCenter
            }

            Item { width: 1; height: 4 }
        }
    }
}
