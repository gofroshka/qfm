use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use cstr::cstr;
use qmetaobject::prelude::*;

mod portal;

/// Paths copied in-app, kept so Paste works without a system clipboard helper.
static CLIPBOARD: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// Escape a string for embedding in a JSON string literal.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Decode `%XX` escapes (and `+` left as-is, per URI path rules).
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(h) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(h);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Accept either a plain path or a `file://` URI and return a local path.
fn from_uri(s: &str) -> String {
    match s.strip_prefix("file://") {
        Some(r) => percent_decode(r),
        None => s.to_owned(),
    }
}

/// Percent-encode a filesystem path for embedding in a `file://` URI.
fn uri_encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Feed `data` to a clipboard helper over stdin; true when it exits cleanly.
fn pipe_to(cmd: &str, args: &[&str], data: &str) -> bool {
    let child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(_) => return false,
    };
    if let Some(mut si) = child.stdin.take() {
        if si.write_all(data.as_bytes()).is_err() {
            return false;
        }
    }
    child.wait().map(|s| s.success()).unwrap_or(false)
}

/// Publish `data` under `mime` on the system clipboard, trying wl-copy then
/// the classic X11 helpers. Returns false when no helper is available.
fn clipboard_write(mime: &str, data: &str) -> bool {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let x11 = std::env::var_os("DISPLAY").is_some();
    let mut attempts: Vec<(&str, Vec<&str>)> = Vec::new();
    if wayland {
        attempts.push(("wl-copy", vec!["--type", mime]));
    }
    if x11 {
        attempts.push(("xclip", vec!["-selection", "clipboard", "-t", mime, "-i"]));
    }
    if !wayland {
        attempts.push(("wl-copy", vec!["--type", mime]));
    }
    attempts.push(("xsel", vec!["--clipboard", "--input"]));
    attempts.into_iter().any(|(cmd, args)| pipe_to(cmd, &args, data))
}

/// Split a file name into (stem, extension) for collision-free naming.
fn split_name(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_owned(), name[i + 1..].to_owned()),
        _ => (name.to_owned(), String::new()),
    }
}

/// Recursively copy `src` to `dst`, preserving symlinks and permissions.
fn copy_recursive(src: &Path, dst: &Path) -> Result<(), String> {
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
fn copy_into(dest_dir: &Path, src: &Path) -> Result<PathBuf, String> {
    let name = src
        .file_name()
        .ok_or_else(|| "Invalid source".to_owned())?
        .to_string_lossy()
        .into_owned();
    let (base, ext) = split_name(&name);
    let dst = dest_dir.join(unique_name(dest_dir, &base, &ext));
    copy_recursive(src, &dst)?;
    Ok(dst)
}

/// Parse a newline-separated list of paths from the UI.
fn parse_paths(s: &str) -> Vec<PathBuf> {
    s.lines()
        .filter(|l| !l.is_empty())
        .map(PathBuf::from)
        .collect()
}

/// Resolve a user-supplied path: `~` / empty -> home, then canonicalize.
fn resolve(input: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let raw = input.trim();
    let path = if raw.is_empty() || raw == "~" {
        PathBuf::from(&home)
    } else if let Some(rest) = raw.strip_prefix("~/") {
        Path::new(&home).join(rest)
    } else {
        PathBuf::from(raw)
    };
    fs::canonicalize(&path).unwrap_or(path)
}

struct Entry {
    name: String,
    path: String,
    is_dir: bool,
    hidden: bool,
    link: bool,
    bytes: u64,
    mtime: i64,
    readonly: bool,
}

fn read_dir(path: &Path) -> Result<Vec<Entry>, String> {
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
        let is_dir = meta.is_dir();
        out.push(Entry {
            path: item.path().to_string_lossy().into_owned(),
            hidden: name.starts_with('.'),
            name,
            is_dir,
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

/// Return a name that does not collide with an existing child of `parent`.
/// `ext` is appended as `.ext` when non-empty; numeric suffixes are inserted
/// before the extension ("New File.txt", "New File 2.txt", ...).
fn unique_name(parent: &Path, base: &str, ext: &str) -> String {
    let make = |n: usize| -> String {
        let stem = if n == 0 {
            base.to_owned()
        } else {
            format!("{base} {}", n + 1)
        };
        if ext.is_empty() {
            stem
        } else {
            format!("{stem}.{ext}")
        }
    };
    for n in 0..10_000 {
        let candidate = make(n);
        if !parent.join(&candidate).exists() {
            return candidate;
        }
    }
    make(0)
}

/// Reject names that cannot be a single path component.
fn valid_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty() && name != "." && name != ".." && !name.contains('/')
}

// ---- trash (freedesktop.org home trash) ------------------------------------

/// Sentinel returned to the UI when a file cannot be trashed because it lives on
/// a different filesystem than the home trash.
const TRASH_EXDEV: &str = "error:EXDEV";
const TRASHINFO_EXT: &str = ".trashinfo";

fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

/// `$XDG_DATA_HOME/Trash` (or `~/.local/share/Trash`).
fn trash_root() -> PathBuf {
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
fn ensure_trash(root: &Path) -> Result<(PathBuf, PathBuf), String> {
    let files = root.join("files");
    let info = root.join("info");
    fs::create_dir_all(&files).map_err(|e| e.to_string())?;
    fs::create_dir_all(&info).map_err(|e| e.to_string())?;
    for dir in [&files, &info] {
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    Ok((files, info))
}

/// Format a Unix timestamp as a UTC ISO-8601 string for `.trashinfo`.
fn fmt_iso(secs: i64) -> String {
    // civil_from_days (Howard Hinnant).
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn write_trashinfo(path: &Path, original: &Path) -> Result<(), String> {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let body = format!(
        "[Trash Info]\nPath={}\nDeletionDate={}\n",
        uri_encode(&original.to_string_lossy()),
        fmt_iso(secs)
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

/// Recursive byte size; symlinks count as their own length.
fn dir_size(path: &Path) -> u64 {
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

/// Remove a file, symlink or directory tree, ignoring errors.
fn remove_path(path: &Path) {
    let link = fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    let _ = if !link && path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
}

fn remove_trash_item(files: &Path, info: &Path, name: &str) {
    remove_path(&files.join(name));
    let _ = fs::remove_file(info.join(format!("{name}{TRASHINFO_EXT}")));
}

/// Opportunistically prune the trash by age and total size on every mutation.
fn purge_trash() {
    let root = trash_root();
    let (files, info) = match ensure_trash(&root) {
        Ok(v) => v,
        Err(_) => return,
    };
    let days = env_i64("QFM_TRASH_DAYS", 30);
    let max_bytes = env_u64("QFM_TRASH_MAX_MB", 5000).saturating_mul(1024 * 1024);
    if days <= 0 && max_bytes == 0 {
        return;
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let mut kept: Vec<(String, i64, u64)> = Vec::new();
    for item in fs::read_dir(&info).into_iter().flatten().flatten() {
        let fname = item.file_name().to_string_lossy().into_owned();
        let name = match fname.strip_suffix(TRASHINFO_EXT) {
            Some(n) => n.to_owned(),
            None => continue,
        };
        let mtime = item.metadata().map(|m| m.mtime()).unwrap_or(now);
        if days > 0 && now.saturating_sub(mtime) > days * 86400 {
            remove_trash_item(&files, &info, &name);
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
                remove_trash_item(&files, &info, &name);
                cur = cur.saturating_sub(size);
            }
        }
    }
}

/// Move `paths` into the home trash. Returns the stored names on success, or
/// `TRASH_EXDEV` / an error string.
fn trash_paths(paths: &[PathBuf]) -> Result<Vec<String>, String> {
    let root = trash_root();
    let (files, info) = ensure_trash(&root)?;
    let root_dev = fs::metadata(&root).map(|m| m.dev()).map_err(|e| e.to_string())?;
    for p in paths {
        let dev = fs::symlink_metadata(p)
            .map(|m| m.dev())
            .map_err(|e| format!("{}: {e}", p.display()))?;
        if dev != root_dev {
            return Err(TRASH_EXDEV.to_owned());
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
    purge_trash();
    Ok(names)
}

/// Restore entries (by stored trash name) back to their original locations.
fn restore_trash(names: &[String]) -> Result<(), String> {
    let root = trash_root();
    let (files, info) = ensure_trash(&root)?;
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

fn empty_trash() -> Result<(), String> {
    let root = trash_root();
    let (files, info) = ensure_trash(&root)?;
    for item in fs::read_dir(&files).into_iter().flatten().flatten() {
        remove_path(&item.path());
    }
    for item in fs::read_dir(&info).into_iter().flatten().flatten() {
        let _ = fs::remove_file(item.path());
    }
    Ok(())
}

fn count_trash() -> i32 {
    fs::read_dir(trash_root().join("info"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(TRASHINFO_EXT))
        .count() as i32
}

struct TrashItem {
    name: String,
    original: String,
    deleted: i64,
    bytes: u64,
    is_dir: bool,
    known: bool,
}

fn list_trash() -> Vec<TrashItem> {
    let root = trash_root();
    let (files, info) = match ensure_trash(&root) {
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

fn listing(path: &Path) -> String {
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

#[derive(QObject, Default)]
struct Fs {
    base: qt_base_class!(trait QObject),

    // List a directory. Returns JSON: {path, parent, entries:[...]} or {error}.
    list_json: qt_method!(fn list_json(&self, path: QString) -> QString {
        listing(&resolve(&path.to_string())).into()
    }),

    home: qt_method!(fn home(&self) -> QString {
        std::env::var("HOME").unwrap_or_else(|_| "/".into()).into()
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

    // Move entries to the home trash. Returns the newline-separated stored
    // names on success (for Undo), or "error:..." (EXDEV when cross-device).
    trash: qt_method!(fn trash(&self, paths: QString) -> QString {
        let list = parse_paths(&paths.to_string());
        if list.is_empty() {
            return QString::from("");
        }
        match trash_paths(&list) {
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
        match restore_trash(&list) {
            Ok(_) => QString::from(""),
            Err(e) => e.into(),
        }
    }),

    // JSON array of trash entries: {name, original, deleted, bytes, dir, known}.
    trash_list: qt_method!(fn trash_list(&self) -> QString {
        let items = list_trash();
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
        match empty_trash() {
            Ok(_) => QString::from(""),
            Err(e) => e.into(),
        }
    }),

    trash_count: qt_method!(fn trash_count(&self) -> i32 {
        count_trash()
    }),

    // Remove entries permanently. Returns "" on success or an error message.
    delete_permanent: qt_method!(fn delete_permanent(&self, paths: QString) -> QString {
        for p in parse_paths(&paths.to_string()) {
            let link = fs::symlink_metadata(&p)
                .map(|m| m.file_type().is_symlink())
                .unwrap_or(false);
            let res = if !link && p.is_dir() {
                fs::remove_dir_all(&p)
            } else {
                fs::remove_file(&p)
            };
            if let Err(e) = res {
                return format!("{e}").into();
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

    // ---- clipboard / copy-paste -------------------------------------------
    // Build a `file://` URI for use with Image/MediaPlayer sources.
    file_uri: qt_method!(fn file_uri(&self, path: QString) -> QString {
        format!("file://{}", uri_encode(&path.to_string())).into()
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

    // Copy paths (newline separated) to the clipboard as a file list and
    // remember them for in-app Paste. Returns "".
    copy_to_clipboard: qt_method!(fn copy_to_clipboard(&self, paths: QString) -> QString {
        let list: Vec<PathBuf> = paths
            .to_string()
            .lines()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .collect();
        if list.is_empty() {
            return QString::from("");
        }
        let mut uri_list = String::new();
        for p in &list {
            uri_list.push_str(&format!("file://{}\r\n", uri_encode(&p.to_string_lossy())));
        }
        clipboard_write("text/uri-list", &uri_list);
        if let Ok(mut clip) = CLIPBOARD.lock() {
            *clip = list;
        }
        QString::from("")
    }),

    // Put arbitrary text (e.g. a path) on the clipboard as plain text.
    copy_text: qt_method!(fn copy_text(&self, text: QString) -> QString {
        clipboard_write("text/plain", &text.to_string());
        QString::from("")
    }),

    // Number of paths currently held in the in-app clipboard.
    clipboard_count: qt_method!(fn clipboard_count(&self) -> i32 {
        CLIPBOARD.lock().map(|c| c.len() as i32).unwrap_or(0)
    }),

    // Copy the clipboard contents into `dest`, avoiding name collisions.
    // Returns "" on success or an error message.
    paste: qt_method!(fn paste(&self, dest: QString) -> QString {
        let dest = PathBuf::from(dest.to_string());
        if !dest.is_dir() {
            return QString::from("Not a directory");
        }
        let items = CLIPBOARD.lock().map(|c| c.clone()).unwrap_or_default();
        for src in &items {
            if let Err(e) = copy_into(&dest, src) {
                return e.into();
            }
        }
        QString::from("")
    }),

    // ---- portal picker bridge ---------------------------------------------
    // Returns the next pending FileChooser request as JSON, or "".
    poll_portal: qt_method!(fn poll_portal(&self) -> QString {
        match portal::poll() {
            Some(p) => format!(
                "{{\"handle\":\"{}\",\"directory\":{},\"multiple\":{}}}",
                esc(&p.handle),
                p.directory,
                p.multiple
            )
            .into(),
            None => QString::from(""),
        }
    }),

    // Answer a request. `paths` is a newline separated list.
    portal_reply: qt_method!(fn portal_reply(&self, handle: QString, code: i32, paths: QString) {
        let list: Vec<String> = paths
            .to_string()
            .split('\n')
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        portal::reply(&handle.to_string(), code as u32, list);
    }),
}

fn main() {
    qmetaobject::log::init_qt_to_rust();
    env_logger::builder()
        .parse_env(env_logger::Env::default().default_filter_or("warn"))
        .init();

    let args: Vec<String> = std::env::args().collect();
    let portal_mode = args.iter().any(|a| a == "--portal");
    let initial = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with("--"))
        .map(|a| from_uri(a))
        .unwrap_or_default();

    qml_register_type::<Fs>(cstr!("Qfm"), 1, 0, cstr!("Fs"));

    // Serve the FileChooser portal regardless of mode so the running instance
    // can act as the system picker.
    portal::serve();

    let mut engine = QmlEngine::new();
    engine.set_property("qfmInitialPath".into(), QString::from(initial.as_str()).into());
    engine.set_property("qfmPortalMode".into(), portal_mode.into());
    match std::env::var("QFM_QML") {
        Ok(path) => engine.load_file(path.into()),
        Err(_) => engine.load_data(include_str!("../qml/Main.qml").into()),
    }
    engine.exec();
}

#[cfg(test)]
mod tests {
    use super::*;

    // XDG_DATA_HOME is process-global, so serialise the env-dependent tests.
    static LOCK: Mutex<()> = Mutex::new(());

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("qfm-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn iso_format() {
        assert_eq!(fmt_iso(0), "1970-01-01T00:00:00");
        assert_eq!(fmt_iso(1_000_000_000), "2001-09-09T01:46:40");
    }

    #[test]
    fn trash_roundtrip() {
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
        assert_eq!(count_trash(), 1);

        let items = list_trash();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].original, file.to_string_lossy());
        assert!(items[0].known);

        restore_trash(&names).unwrap();
        assert!(file.exists());
        assert_eq!(count_trash(), 0);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn trash_dir_and_empty() {
        let _guard = LOCK.lock().unwrap();
        let base = tmp("dir");
        std::env::set_var("XDG_DATA_HOME", base.join("data"));
        let work = base.join("work");
        let sub = work.join("sub");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("a.txt"), b"a").unwrap();

        trash_paths(&[sub.clone()]).unwrap();
        assert!(!sub.exists());
        assert_eq!(count_trash(), 1);

        empty_trash().unwrap();
        assert_eq!(count_trash(), 0);
        assert_eq!(dir_size(&trash_root().join("files")), 0);
        let _ = fs::remove_dir_all(&base);
    }
}
