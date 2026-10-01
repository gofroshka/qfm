//! XDG Desktop Portal backend: `org.freedesktop.impl.portal.FileChooser`.
//!
//! xdg-desktop-portal (the frontend) calls us when an application asks for a
//! file/folder dialog. We park the request in a queue, the Qt thread polls it
//! and shows the picker window, then hands the chosen paths back here and we
//! answer the D-Bus call with `file://` URIs.

mod backend;

use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};

use crate::util::text::file_uri;

/// A FileChooser request waiting for the GUI to answer it.
pub struct Pending {
    pub handle: String,
    pub directory: bool,
    pub multiple: bool,
}

/// State shared between the D-Bus worker thread and the GUI thread.
pub(crate) struct Shared {
    pub(crate) pending: Mutex<VecDeque<Pending>>,
    pub(crate) waiting: Mutex<HashMap<String, Sender<(u32, Vec<String>)>>>,
}

static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

pub(crate) fn shared() -> Arc<Shared> {
    SHARED
        .get_or_init(|| {
            Arc::new(Shared {
                pending: Mutex::new(VecDeque::new()),
                waiting: Mutex::new(HashMap::new()),
            })
        })
        .clone()
}

/// Start the D-Bus backend on a background thread. The connection is kept
/// alive for the lifetime of the process.
pub fn serve() {
    let shared = shared();
    std::thread::spawn(move || {
        let built = zbus::blocking::connection::Builder::session()
            .and_then(|b| b.name("org.freedesktop.impl.portal.desktop.qfm"))
            .and_then(|b| b.serve_at("/org/freedesktop/portal/desktop", backend::Chooser { shared }))
            .and_then(|b| b.build());
        match built {
            Ok(_conn) => loop {
                std::thread::park();
            },
            Err(e) => eprintln!("qfm: portal backend unavailable: {e}"),
        }
    });
}

/// GUI side: take the next queued request, if any.
pub fn poll() -> Option<Pending> {
    shared().pending.lock().unwrap().pop_front()
}

/// GUI side: answer a request. `code` 0 = accept, 1 = cancel.
pub fn reply(handle: &str, code: u32, paths: Vec<String>) {
    let uris: Vec<String> = paths.iter().map(|p| file_uri(p)).collect();
    if let Some(tx) = shared().waiting.lock().unwrap().get(handle) {
        let _ = tx.send((code, uris));
    }
}
