pragma Singleton

import QtQuick

// Shared visual language for qfm: near-black surfaces, muted greys, a single
// light-grey accent and a small radius scale.
QtObject {
    readonly property color bg: "#0b0b0c"
    readonly property color surface: "#0b0b0c"
    readonly property color surface2: "#171719"
    readonly property color elevated: "#1e1e22"
    readonly property color track: "#2a2a2e"
    readonly property color hover: Qt.rgba(1, 1, 1, 0.08)
    readonly property color border: Qt.rgba(1, 1, 1, 0.08)
    readonly property color text: "#f3f3f4"
    readonly property color textDim: "#8a8a92"
    readonly property color accent: "#d7d7db"
    readonly property color link: "#7fb8d8"
    readonly property color danger: "#e5786d"

    readonly property int radiusSmall: 8
    readonly property int radiusMedium: 12
    readonly property int radiusLarge: 16

    readonly property string font: "Inter"
    readonly property string icon: "JetBrainsMono Nerd Font"
    readonly property string mono: "JetBrainsMono Nerd Font"

    readonly property int rowHeight: 38
}
