//! System clipboard integration plus an in-app clipboard of copied paths.
//!
//! The in-app list lets Paste work without a system clipboard helper; the
//! system clipboard is best-effort via `wl-copy`/`xclip`/`xsel`.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

use crate::fs_ops::copy_into;
use crate::util::text::file_uri;

/// Paths copied in-app, kept so Paste works without a system clipboard helper.
static CLIPBOARD: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

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
pub fn write(mime: &str, data: &str) -> bool {
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
    attempts
        .into_iter()
        .any(|(cmd, args)| pipe_to(cmd, &args, data))
}

/// Copy paths to the system clipboard as a `text/uri-list` and remember them
/// for in-app Paste.
pub fn set_files(paths: Vec<PathBuf>) {
    if paths.is_empty() {
        return;
    }
    let mut uri_list = String::new();
    for p in &paths {
        uri_list.push_str(&file_uri(&p.to_string_lossy()));
        uri_list.push_str("\r\n");
    }
    write("text/uri-list", &uri_list);
    if let Ok(mut clip) = CLIPBOARD.lock() {
        *clip = paths;
    }
}

/// Put arbitrary text (e.g. a path) on the system clipboard as plain text.
pub fn set_text(text: &str) {
    write("text/plain", text);
}

/// Number of paths currently held in the in-app clipboard.
pub fn count() -> usize {
    CLIPBOARD.lock().map(|c| c.len()).unwrap_or(0)
}

/// Copy the in-app clipboard contents into `dest`, avoiding name collisions.
pub fn paste_into(dest: &Path) -> Result<(), String> {
    let items = CLIPBOARD.lock().map(|c| c.clone()).unwrap_or_default();
    for src in &items {
        copy_into(dest, src)?;
    }
    Ok(())
}
