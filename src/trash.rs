//! freedesktop.org "home trash" implementation.
//!
//! Files are moved into `$XDG_DATA_HOME/Trash/files` with a matching
//! `.trashinfo` record in `Trash/info`. Cross-device moves are refused (the UI
//! falls back to permanent deletion).

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::fs_ops::{dir_size, remove_path};
use crate::util::path::{split_name, unique_name, valid_name};
use crate::util::text::{percent_decode, uri_encode};
use crate::util::time::{env_i64, env_u64, fmt_iso, now_secs};

/// Sentinel returned to the UI when a file cannot be trashed because it lives on
/// a different filesystem than the home trash.
pub const EXDEV: &str = "error:EXDEV";

const TRASHINFO_EXT: &str = ".trashinfo";

/// `$XDG_DATA_HOME/Trash` (or `~/.local/share/Trash`).
pub fn root() -> PathBuf {
    let data = std::env::var("XDG_DATA_HOME")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
            Path::new(&home).join(".local/share")
        });
    data.join("Trash")
}

/// Ensure `Trash/files` and `Trash/info` exist with private permissions.
fn ensure(root: &Path) -> Result<(PathBuf, PathBuf), String> {
    let files = root.join("files");
    let info = root.join("info");
    fs::create_dir_all(&files).map_err(|e| e.to_string())?;
    fs::create_dir_all(&info).map_err(|e| e.to_string())?;
    for dir in [&files, &info] {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    Ok((files, info))
}

fn write_trashinfo(path: &Path, original: &Path) -> Result<(), String> {
    let body = format!(
        "[Trash Info]\nPath={}\nDeletionDate={}\n",
        uri_encode(&original.to_string_lossy()),
        fmt_iso(now_secs())
    );
    fs::write(path, body).map_err(|e| e.to_string())
}

fn read_trashinfo(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("Path=") {
            return Some(percent_decode(v.trim()));
        }
    }
    None
}

fn remove_item(files: &Path, info: &Path, name: &str) {
    remove_path(&files.join(name));
    let _ = fs::remove_file(info.join(format!("{name}{TRASHINFO_EXT}")));
}

/// Opportunistically prune the trash by age and total size on every mutation.
fn purge() {
    let root = root();
    let (files, info) = match ensure(&root) {
        Ok(v) => v,
        Err(_) => return,
    };
    let days = env_i64("QFM_TRASH_DAYS", 30);
    let max_bytes = env_u64("QFM_TRASH_MAX_MB", 5000).saturating_mul(1024 * 1024);
    if days <= 0 && max_bytes == 0 {
        return;
    }
    let now = now_secs();

    let mut kept: Vec<(String, i64, u64)> = Vec::new();
    for item in fs::read_dir(&info).into_iter().flatten().flatten() {
        let fname = item.file_name().to_string_lossy().into_owned();
        let name = match fname.strip_suffix(TRASHINFO_EXT) {
            Some(n) => n.to_owned(),
            None => continue,
        };
        let mtime = item.metadata().map(|m| m.mtime()).unwrap_or(now);
        if days > 0 && now.saturating_sub(mtime) > days * 86400 {
            remove_item(&files, &info, &name);
        } else {
            let size = dir_size(&files.join(&name));
            kept.push((name, mtime, size));
        }
    }

    if max_bytes > 0 {
        let total: u64 = kept.iter().map(|t| t.2).sum();
        if total > max_bytes {
            kept.sort_by_key(|t| t.1);
            let mut cur = total;
            for (name, _mtime, size) in kept {
                if cur <= max_bytes {
                    break;
                }
                remove_item(&files, &info, &name);
                cur = cur.saturating_sub(size);
            }
        }
    }
}

/// Move `paths` into the home trash. Returns the stored names on success, or
/// [`EXDEV`] / an error string.
pub fn trash_paths(paths: &[PathBuf]) -> Result<Vec<String>, String> {
    let root = root();
    let (files, info) = ensure(&root)?;
    let root_dev = fs::metadata(&root).map(|m| m.dev()).map_err(|e| e.to_string())?;
    for p in paths {
        let dev = fs::symlink_metadata(p)
            .map(|m| m.dev())
            .map_err(|e| format!("{}: {e}", p.display()))?;
        if dev != root_dev {
            return Err(EXDEV.to_owned());
        }
    }
    let mut names = Vec::with_capacity(paths.len());
    for p in paths {
        let fname = p
            .file_name()
            .ok_or_else(|| "Invalid path".to_owned())?
            .to_string_lossy()
            .into_owned();
        let (base, ext) = split_name(&fname);
        let name = unique_name(&files, &base, &ext);
        let dst = files.join(&name);
        fs::rename(p, &dst).map_err(|e| format!("{}: {e}", p.display()))?;
        if let Err(e) = write_trashinfo(&info.join(format!("{name}{TRASHINFO_EXT}")), p) {
            let _ = fs::rename(&dst, p);
            return Err(e);
        }
        names.push(name);
    }
    purge();
    Ok(names)
}

/// Restore entries (by stored trash name) back to their original locations.
pub fn restore(names: &[String]) -> Result<(), String> {
    let root = root();
    let (files, info) = ensure(&root)?;
    for name in names {
        if !valid_name(name) {
            return Err(format!("Invalid name: {name}"));
        }
        let src = files.join(name);
        let info_path = info.join(format!("{name}{TRASHINFO_EXT}"));
        let original = read_trashinfo(&info_path)
            .ok_or_else(|| format!("No trash info for \u{201c}{name}\u{201d}"))?;
        let orig = PathBuf::from(&original);
        let parent = orig.parent().ok_or_else(|| "Invalid path".to_owned())?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let dst = if orig.exists() {
            let fname = orig.file_name().unwrap_or_default().to_string_lossy();
            let (base, ext) = split_name(&fname);
            parent.join(unique_name(parent, &base, &ext))
        } else {
            orig.clone()
        };
        fs::rename(&src, &dst).map_err(|e| format!("{name}: {e}"))?;
        let _ = fs::remove_file(&info_path);
    }
    Ok(())
}

pub fn empty() -> Result<(), String> {
    let root = root();
    let (files, info) = ensure(&root)?;
    for item in fs::read_dir(&files).into_iter().flatten().flatten() {
        remove_path(&item.path());
    }
    for item in fs::read_dir(&info).into_iter().flatten().flatten() {
        let _ = fs::remove_file(item.path());
    }
    Ok(())
}

pub fn count() -> i32 {
    fs::read_dir(root().join("info"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(TRASHINFO_EXT))
        .count() as i32
}

/// A row in the trash panel.
pub struct TrashItem {
    pub name: String,
    pub original: String,
    pub deleted: i64,
    pub bytes: u64,
    pub is_dir: bool,
    pub known: bool,
}

/// List trash entries, most recently deleted first.
pub fn list() -> Vec<TrashItem> {
    let root = root();
    let (files, info) = match ensure(&root) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for item in fs::read_dir(&info).into_iter().flatten().flatten() {
        let fname = item.file_name().to_string_lossy().into_owned();
        let name = match fname.strip_suffix(TRASHINFO_EXT) {
            Some(n) => n.to_owned(),
            None => continue,
        };
        let deleted = item.metadata().map(|m| m.mtime()).unwrap_or(0);
        let stored = files.join(&name);
        let meta = fs::symlink_metadata(&stored);
        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        let bytes = meta.as_ref().map(|_| dir_size(&stored)).unwrap_or(0);
        let original = read_trashinfo(&item.path()).unwrap_or_default();
        out.push(TrashItem {
            known: !original.is_empty() && meta.is_ok(),
            name,
            original,
            deleted,
            bytes,
            is_dir,
        });
    }
    out.sort_by(|a, b| b.deleted.cmp(&a.deleted));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // XDG_DATA_HOME is process-global, so serialise the env-dependent tests.
    static LOCK: Mutex<()> = Mutex::new(());

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("qfm-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn roundtrip() {
        let _guard = LOCK.lock().unwrap();
        let base = tmp("roundtrip");
        std::env::set_var("XDG_DATA_HOME", base.join("data"));
        let work = base.join("work");
        fs::create_dir_all(&work).unwrap();
        let file = work.join("hello.txt");
        fs::write(&file, b"hi").unwrap();

        let names = trash_paths(&[file.clone()]).unwrap();
        assert_eq!(names.len(), 1);
        assert!(!file.exists());
        assert_eq!(count(), 1);

        let items = list();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].original, file.to_string_lossy());
        assert!(items[0].known);

        restore(&names).unwrap();
        assert!(file.exists());
        assert_eq!(count(), 0);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn dir_and_empty() {
        let _guard = LOCK.lock().unwrap();
        let base = tmp("dir");
        std::env::set_var("XDG_DATA_HOME", base.join("data"));
        let work = base.join("work");
        let sub = work.join("sub");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("a.txt"), b"a").unwrap();

        trash_paths(&[sub.clone()]).unwrap();
        assert!(!sub.exists());
        assert_eq!(count(), 1);

        empty().unwrap();
        assert_eq!(count(), 0);
        assert_eq!(dir_size(&root().join("files")), 0);
        let _ = fs::remove_dir_all(&base);
    }
}
