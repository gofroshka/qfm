use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

use cstr::cstr;
use qmetaobject::prelude::*;

mod portal;

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

/// Accept either a plain path or a `file://` URI and return a local path.
fn from_uri(s: &str) -> String {
    let rest = match s.strip_prefix("file://") {
        Some(r) => r,
        None => return s.to_owned(),
    };
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(h) = u8::from_str_radix(&rest[i + 1..i + 3], 16) {
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

    // Delete an entry: move to trash, or remove permanently when `permanent`.
    delete_item: qt_method!(fn delete_item(&self, path: QString, permanent: bool) -> QString {
        let p = PathBuf::from(path.to_string());
        if !permanent {
            return Command::new("gio")
                .arg("trash")
                .arg("--")
                .arg(&p)
                .output()
                .map(|o| {
                    if o.status.success() {
                        QString::from("")
                    } else {
                        QString::from(String::from_utf8_lossy(&o.stderr).trim())
                    }
                })
                .unwrap_or_else(|e| e.to_string().into());
        }
        let link = fs::symlink_metadata(&p)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false);
        let res = if !link && p.is_dir() {
            fs::remove_dir_all(&p)
        } else {
            fs::remove_file(&p)
        };
        match res {
            Ok(_) => QString::from(""),
            Err(e) => format!("{}", e).into(),
        }
    }),

    // Open a file/dir with the desktop default handler. Returns "" on success.
    open: qt_method!(fn open(&self, path: QString) -> QString {
        match Command::new("xdg-open").arg(path.to_string()).spawn() {
            Ok(_) => QString::from(""),
            Err(e) => e.to_string().into(),
        }
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
