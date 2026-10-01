import QtQuick

// Rewind / play-pause / forward transport used by audio and video previews.
Row {
    id: mc
    property bool playing: false
    property string rewindGlyph: "\uf048"
    property string forwardGlyph: "\uf051"
    signal rewind()
    signal forward()
    signal togglePlay()

    spacing: 10

    BarButton { glyph: mc.rewindGlyph; onActivated: mc.rewind() }
    BarButton {
        glyph: mc.playing ? "\uf04c" : "\uf04b"
        onActivated: mc.togglePlay()
    }
    BarButton { glyph: mc.forwardGlyph; onActivated: mc.forward() }
}
