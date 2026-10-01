//! Clipboard operations exposed to QML.

use std::path::PathBuf;

use qmetaobject::prelude::*;

use crate::clipboard;

#[derive(QObject, Default)]
pub struct Clipboard {
    base: qt_base_class!(trait QObject),

    // Copy paths (newline separated) to the clipboard as a file list and
    // remember them for in-app Paste. Returns "".
    copy_to_clipboard: qt_method!(fn copy_to_clipboard(&self, paths: QString) -> QString {
        let list: Vec<PathBuf> = crate::util::path::parse_paths(&paths.to_string());
        clipboard::set_files(list);
        QString::from("")
    }),

    // Put arbitrary text (e.g. a path) on the clipboard as plain text.
    copy_text: qt_method!(fn copy_text(&self, text: QString) -> QString {
        clipboard::set_text(&text.to_string());
        QString::from("")
    }),

    // Number of paths currently held in the in-app clipboard.
    clipboard_count: qt_method!(fn clipboard_count(&self) -> i32 {
        clipboard::count() as i32
    }),

    // Copy the clipboard contents into `dest`, avoiding name collisions.
    // Returns "" on success or an error message.
    paste: qt_method!(fn paste(&self, dest: QString) -> QString {
        let dest = PathBuf::from(dest.to_string());
        if !dest.is_dir() {
            return QString::from("Not a directory");
        }
        match clipboard::paste_into(&dest) {
            Ok(_) => QString::from(""),
            Err(e) => e.into(),
        }
    }),
}
