//! Directory listing and filesystem mutations.

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::util::path::unique_name;
use crate::util::text::esc;

/// A single directory entry, ready to be serialised to the UI.
pub struct Entry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub hidden: bool,
    pub link: bool,
    pub bytes: u64,
    pub mtime: i64,
    pub readonly: bool,
}

/// Read a directory, directories first, then case-insensitive by name.
pub fn read_dir(path: &Path) -> Result<Vec<Entry>, String> {
    let rd = fs::read_dir(path).map_err(|e| e.to_string())?;
    let mut out: Vec<Entry> = Vec::new();
    for item in rd.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        let link = item.file_type().map(|t| t.is_symlink()).unwrap_or(false);
        // Follow symlinks for type/size but fall back to the raw entry so
        // broken links are still listed.
        let meta = match fs::metadata(item.path()).or_else(|_| item.metadata()) {
            Ok(m) => m,
            Err(_) => continue,
        };
        out.push(Entry {
            path: item.path().to_string_lossy().into_owned(),
            hidden: name.starts_with('.'),
            name,
            is_dir: meta.is_dir(),
            link,
            bytes: meta.len(),
            mtime: meta.mtime(),
            readonly: meta.permissions().mode() & 0o200 == 0,
        });
    }
    out.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(out)
}

/// JSON listing for a directory: `{path, parent, entries:[...]}` or `{error}`.
pub fn listing(path: &Path) -> String {
    let canonical = path.to_string_lossy().into_owned();
    let parent = path
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| canonical.clone());

    let entries = match read_dir(path) {
        Ok(e) => e,
        Err(err) => {
            return format!(
                "{{\"error\":\"{}\",\"path\":\"{}\"}}",
                esc(&err),
                esc(&canonical)
            )
        }
    };

    let mut items = String::new();
    for (i, e) in entries.iter().enumerate() {
        if i > 0 {
            items.push(',');
        }
        items.push_str(&format!(
            "{{\"name\":\"{}\",\"path\":\"{}\",\"dir\":{},\"hidden\":{},\"link\":{},\"bytes\":{},\"mtime\":{},\"readonly\":{}}}",
            esc(&e.name),
            esc(&e.path),
            e.is_dir,
            e.hidden,
            e.link,
            e.bytes,
            e.mtime,
            e.readonly
        ));
    }

    format!(
        "{{\"path\":\"{}\",\"parent\":\"{}\",\"entries\":[{}]}}",
        esc(&canonical),
        esc(&parent),
        items
    )
}

/// Recursively copy `src` to `dst`, preserving symlinks and permissions.
pub fn copy_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(src).map_err(|e| e.to_string())?;
    if meta.file_type().is_symlink() {
        let target = fs::read_link(src).map_err(|e| e.to_string())?;
        std::os::unix::fs::symlink(target, dst).map_err(|e| e.to_string())
    } else if meta.is_dir() {
        fs::create_dir_all(dst).map_err(|e| e.to_string())?;
        for item in fs::read_dir(src).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            copy_recursive(&item.path(), &dst.join(item.file_name()))?;
        }
        Ok(())
    } else {
        fs::copy(src, dst).map_err(|e| e.to_string())?;
        let _ = fs::set_permissions(dst, meta.permissions());
        Ok(())
    }
}

/// Copy `src` into `dest_dir` under a name that does not collide.
pub fn copy_into(dest_dir: &Path, src: &Path) -> Result<PathBuf, String> {
    let name = src
        .file_name()
        .ok_or_else(|| "Invalid source".to_owned())?
        .to_string_lossy()
        .into_owned();
    let (base, ext) = crate::util::path::split_name(&name);
    let dst = dest_dir.join(unique_name(dest_dir, &base, &ext));
    copy_recursive(src, &dst)?;
    Ok(dst)
}

/// Remove a file, symlink or directory tree, ignoring errors.
pub fn remove_path(path: &Path) {
    let link = fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    let _ = if !link && path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
}

/// Remove a path permanently, returning an error message on failure.
pub fn remove_path_checked(path: &Path) -> Result<(), String> {
    let link = fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    let res = if !link && path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    res.map_err(|e| e.to_string())
}

/// Recursive byte size; symlinks count as their own length.
pub fn dir_size(path: &Path) -> u64 {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return 0,
    };
    if meta.is_dir() {
        let mut total = 0;
        if let Ok(rd) = fs::read_dir(path) {
            for item in rd.flatten() {
                total += dir_size(&item.path());
            }
        }
        total
    } else {
        meta.len()
    }
}
