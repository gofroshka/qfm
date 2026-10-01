import QtQuick

// Edge/corner hit zone that asks the compositor to resize the window.
MouseArea {
    id: rh
    property int edges: 0
    signal resizeRequested(int edges)

    acceptedButtons: Qt.LeftButton
    hoverEnabled: true
    cursorShape: {
        const t = edges & Qt.TopEdge, b = edges & Qt.BottomEdge;
        const l = edges & Qt.LeftEdge, r = edges & Qt.RightEdge;
        if (t && l) return Qt.SizeFDiagCursor;
        if (t && r) return Qt.SizeBDiagCursor;
        if (b && l) return Qt.SizeBDiagCursor;
        if (b && r) return Qt.SizeFDiagCursor;
        if (t || b) return Qt.SizeVerCursor;
        if (l || r) return Qt.SizeHorCursor;
        return Qt.ArrowCursor;
    }

    onPressed: rh.resizeRequested(rh.edges)
}
