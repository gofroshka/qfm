//! Preview helpers: file URIs for media sources and bounded text reads.

use std::fs;
use std::io::Read;

use qmetaobject::prelude::*;

use crate::util::text::file_uri as make_file_uri;

#[derive(QObject, Default)]
pub struct Preview {
    base: qt_base_class!(trait QObject),

    // Build a `file://` URI for use with Image/MediaPlayer sources.
    file_uri: qt_method!(fn file_uri(&self, path: QString) -> QString {
        make_file_uri(&path.to_string()).into()
    }),

    // Read up to `max` bytes of a text file. Returns "" for binaries or errors.
    read_text: qt_method!(fn read_text(&self, path: QString, max: i32) -> QString {
        let limit = if max <= 0 { 262_144usize } else { max as usize };
        let file = match fs::File::open(path.to_string()) {
            Ok(f) => f,
            Err(_) => return QString::from(""),
        };
        let mut buf = Vec::new();
        let mut limited = file.take(limit as u64);
        if limited.read_to_end(&mut buf).is_err() {
            return QString::from("");
        }
        if buf.iter().take(8192).any(|&b| b == 0) {
            return QString::from("");
        }
        String::from_utf8_lossy(&buf).into_owned().into()
    }),
}
