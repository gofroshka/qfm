//! Filesystem path helpers: parsing, resolution and collision-free naming.

use std::fs;
use std::path::{Path, PathBuf};

/// Parse a newline-separated list of paths coming from the UI.
pub fn parse_paths(s: &str) -> Vec<PathBuf> {
    s.lines()
        .filter(|l| !l.is_empty())
        .map(PathBuf::from)
        .collect()
}

/// The user's home directory (`$HOME`, falling back to `/`).
pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

/// Resolve a user-supplied path: `~` / empty -> home, then canonicalize.
pub fn resolve(input: &str) -> PathBuf {
    let home = home();
    let raw = input.trim();
    let path = if raw.is_empty() || raw == "~" {
        home
    } else if let Some(rest) = raw.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(raw)
    };
    fs::canonicalize(&path).unwrap_or(path)
}

/// Split a file name into (stem, extension) for collision-free naming.
pub fn split_name(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_owned(), name[i + 1..].to_owned()),
        _ => (name.to_owned(), String::new()),
    }
}

/// Return a name that does not collide with an existing child of `parent`.
/// `ext` is appended as `.ext` when non-empty; numeric suffixes are inserted
/// before the extension ("New File.txt", "New File 2.txt", ...).
pub fn unique_name(parent: &Path, base: &str, ext: &str) -> String {
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
pub fn valid_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty() && name != "." && name != ".." && !name.contains('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_extension() {
        assert_eq!(split_name("a.txt"), ("a".into(), "txt".into()));
        assert_eq!(split_name(".bashrc"), (".bashrc".into(), String::new()));
        assert_eq!(split_name("archive.tar.gz"), ("archive.tar".into(), "gz".into()));
        assert_eq!(split_name("noext"), ("noext".into(), String::new()));
    }

    #[test]
    fn validates_component_names() {
        assert!(valid_name("file.txt"));
        assert!(!valid_name(""));
        assert!(!valid_name("."));
        assert!(!valid_name(".."));
        assert!(!valid_name("a/b"));
    }
}
