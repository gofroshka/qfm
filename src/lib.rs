//! qfm backend: filesystem operations, trash, clipboard and the QML bridge.

pub mod bridge;
pub mod clipboard;
pub mod fs_ops;
pub mod portal;
pub mod trash;
pub mod util;

use qmetaobject::prelude::*;

// Embed the QML frontend into the binary as a Qt resource so the app is a
// single self-contained executable. `QFM_QML` can override it with a path.
qrc!(pub register_resources,
    "qml" as "qml" {
        "Main.qml",
        "Theme.qml",
        "Utils.js",
        "qmldir",
        "components/ActionButton.qml",
        "components/BarButton.qml",
        "components/Breadcrumbs.qml",
        "components/ConfirmDialog.qml",
        "components/ContextMenu.qml",
        "components/EmptyState.qml",
        "components/FileRow.qml",
        "components/MediaControls.qml",
        "components/PreviewPanel.qml",
        "components/PromptDialog.qml",
        "components/QuickLook.qml",
        "components/ResizeHandle.qml",
        "components/SearchField.qml",
        "components/SeekBar.qml",
        "components/Toast.qml",
        "components/TrashPanel.qml",
    }
);

/// Register the embedded QML resources and every `Qfm` bridge type.
pub fn register_qml() {
    register_resources();
    bridge::register();
}
