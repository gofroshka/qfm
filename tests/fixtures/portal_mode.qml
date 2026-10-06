import QtQuick
import "qrc:/qml" as Qfm

Qfm.Main {
    id: win

    property int requestsSeen: 0

    Component.onCompleted: Qt.callLater(function() {
        console.warn("qfm-test-ready:" + JSON.stringify({
            shown: win.shown,
            picker: win.picker,
            path: win.curPath,
            dialog: (win.flags & Qt.WindowType_Mask) === Qt.Dialog
        }));
    })

    onPickerChanged: {
        if (!win.picker) return;
        requestsSeen++;
        Qt.callLater(function() {
            // Exercise both the window-manager close button and Cancel.
            if (requestsSeen === 1) win.close();
            else win.pickerCancel();
            console.warn("qfm-test-cancelled:" + JSON.stringify({
                shown: win.shown,
                picker: win.picker
            }));
        });
    }
}
