//! Trash operations exposed to QML.

use qmetaobject::prelude::*;

use crate::trash;
use crate::util::text::esc;

#[derive(QObject, Default)]
pub struct Trash {
    base: qt_base_class!(trait QObject),

    // Move entries to the home trash. Returns the newline-separated stored
    // names on success (for Undo), or "error:..." (EXDEV when cross-device).
    trash: qt_method!(fn trash(&self, paths: QString) -> QString {
        let list = crate::util::path::parse_paths(&paths.to_string());
        if list.is_empty() {
            return QString::from("");
        }
        match trash::trash_paths(&list) {
            Ok(names) => names.join("\n").into(),
            Err(e) => format!("error:{e}").into(),
        }
    }),

    // Restore entries from trash by their stored names.
    trash_restore: qt_method!(fn trash_restore(&self, names: QString) -> QString {
        let list: Vec<String> = names
            .to_string()
            .lines()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        match trash::restore(&list) {
            Ok(_) => QString::from(""),
            Err(e) => e.into(),
        }
    }),

    // JSON array of trash entries: {name, original, deleted, bytes, dir, known}.
    trash_list: qt_method!(fn trash_list(&self) -> QString {
        let items = trash::list();
        let mut out = String::from("[");
        for (i, t) in items.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"name\":\"{}\",\"original\":\"{}\",\"deleted\":{},\"bytes\":{},\"dir\":{},\"known\":{}}}",
                esc(&t.name),
                esc(&t.original),
                t.deleted,
                t.bytes,
                t.is_dir,
                t.known
            ));
        }
        out.push(']');
        out.into()
    }),

    trash_empty: qt_method!(fn trash_empty(&self) -> QString {
        match trash::empty() {
            Ok(_) => QString::from(""),
            Err(e) => e.into(),
        }
    }),

    trash_count: qt_method!(fn trash_count(&self) -> i32 {
        trash::count()
    }),
}
