//! Core filesystem operations exposed to QML.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

use qmetaobject::prelude::*;

use crate::fs_ops::{listing, remove_path_checked};
use crate::util::path::{home as home_path, resolve, unique_name, valid_name};

#[derive(QObject, Default)]
pub struct Fs {
    base: qt_base_class!(trait QObject),

    // List a directory. Returns JSON: {path, parent, entries:[...]} or {error}.
    list_json: qt_method!(fn list_json(&self, path: QString) -> QString {
        listing(&resolve(&path.to_string())).into()
    }),

    home: qt_method!(fn home(&self) -> QString {
        home_path().to_string_lossy().into_owned().into()
    }),

    // Create a directory; returns "" on success or an error message.
    create_dir: qt_method!(fn create_dir(&self, parent: QString, name: QString) -> QString {
        let name = name.to_string();
        if !valid_name(&name) {
            return QString::from("Invalid name");
        }
        let mut p = PathBuf::from(parent.to_string());
        p.push(name.trim());
        match fs::create_dir(&p) {
            Ok(_) => QString::from(""),
            Err(e) => format!("{}", e).into(),
        }
    }),

    // Create an empty file; returns "" on success or an error message.
    create_file: qt_method!(fn create_file(&self, parent: QString, name: QString) -> QString {
        let name = name.to_string();
        if !valid_name(&name) {
            return QString::from("Invalid name");
        }
        let mut p = PathBuf::from(parent.to_string());
        p.push(name.trim());
        match fs::OpenOptions::new().write(true).create_new(true).open(&p) {
            Ok(_) => QString::from(""),
            Err(e) => format!("{}", e).into(),
        }
    }),

    // Rename an entry in place; returns "" on success or an error message.
    rename: qt_method!(fn rename(&self, path: QString, name: QString) -> QString {
        let name = name.to_string();
        if !valid_name(&name) {
            return QString::from("Invalid name");
        }
        let name = name.trim();
        let src = PathBuf::from(path.to_string());
        if src.file_name().map(|n| n.to_string_lossy() == name).unwrap_or(false) {
            return QString::from("");
        }
        let dst = match src.parent() {
            Some(p) => p.join(name),
            None => PathBuf::from(name),
        };
        match fs::rename(&src, &dst) {
            Ok(_) => QString::from(""),
            Err(e) => format!("{}", e).into(),
        }
    }),

    // A collision-free child name for "New Folder"/"New File.txt" style creation.
    suggest_name: qt_method!(fn suggest_name(&self, parent: QString, base: QString, ext: QString) -> QString {
        unique_name(
            &PathBuf::from(parent.to_string()),
            &base.to_string(),
            &ext.to_string(),
        )
        .into()
    }),

    // Remove entries permanently. Returns "" on success or an error message.
    delete_permanent: qt_method!(fn delete_permanent(&self, paths: QString) -> QString {
        for p in crate::util::path::parse_paths(&paths.to_string()) {
            if let Err(e) = remove_path_checked(&p) {
                return e.into();
            }
        }
        QString::from("")
    }),

    // Open a file/dir with the desktop default handler. Returns "" on success.
    open: qt_method!(fn open(&self, path: QString) -> QString {
        match Command::new("xdg-open").arg(path.to_string()).spawn() {
            Ok(_) => QString::from(""),
            Err(e) => e.to_string().into(),
        }
    }),
}
