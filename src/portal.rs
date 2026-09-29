// XDG Desktop Portal backend: org.freedesktop.impl.portal.FileChooser.
//
// xdg-desktop-portal (the frontend) calls us when an application asks for a
// file/folder dialog. We park the request in a queue, the Qt thread polls it
// and shows the picker window, then hands the chosen paths back here and we
// answer the D-Bus call with `file://` URIs.
use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

pub struct Pending {
    pub handle: String,
    pub directory: bool,
    pub multiple: bool,
}

struct Shared {
    pending: Mutex<VecDeque<Pending>>,
    waiting: Mutex<HashMap<String, Sender<(u32, Vec<String>)>>>,
}

static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

fn shared() -> Arc<Shared> {
    SHARED
        .get_or_init(|| {
            Arc::new(Shared {
                pending: Mutex::new(VecDeque::new()),
                waiting: Mutex::new(HashMap::new()),
            })
        })
        .clone()
}

struct Chooser {
    shared: Arc<Shared>,
}

fn opt_bool(options: &HashMap<String, OwnedValue>, key: &str) -> bool {
    options
        .get(key)
        .and_then(|v| v.downcast_ref::<bool>().ok())
        .unwrap_or(false)
}

impl Chooser {
    fn choose(
        &self,
        handle: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let directory = opt_bool(&options, "directory");
        let multiple = opt_bool(&options, "multiple");

        let (tx, rx) = mpsc::channel();
        self.shared
            .waiting
            .lock()
            .unwrap()
            .insert(handle.clone(), tx);
        self.shared.pending.lock().unwrap().push_back(Pending {
            handle: handle.clone(),
            directory,
            multiple,
        });

        // Blocks this D-Bus worker until the GUI answers (or times out).
        let result = rx.recv_timeout(Duration::from_secs(300));
        self.shared.waiting.lock().unwrap().remove(&handle);

        match result {
            Ok((code, uris)) => {
                let mut out: HashMap<String, OwnedValue> = HashMap::new();
                if code == 0 {
                    if let Ok(v) = Value::from(uris).try_into() {
                        out.insert("uris".to_owned(), v);
                    }
                }
                (code, out)
            }
            Err(_) => (1, HashMap::new()),
        }
    }
}

#[zbus::interface(name = "org.freedesktop.impl.portal.FileChooser")]
impl Chooser {
    fn open_file(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        _title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), options)
    }

    fn save_file(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        _title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), options)
    }

    fn save_files(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        _title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), options)
    }
}

/// Start the D-Bus backend on a background thread. The connection is kept
/// alive for the lifetime of the process.
pub fn serve() {
    let shared = shared();
    std::thread::spawn(move || {
        let built = zbus::blocking::connection::Builder::session()
            .and_then(|b| b.name("org.freedesktop.impl.portal.desktop.qfm"))
            .and_then(|b| b.serve_at("/org/freedesktop/portal/desktop", Chooser { shared }))
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
    let uris: Vec<String> = paths.iter().map(|p| to_uri(p)).collect();
    if let Some(tx) = shared().waiting.lock().unwrap().get(handle) {
        let _ = tx.send((code, uris));
    }
}

fn to_uri(path: &str) -> String {
    let mut s = String::from("file://");
    for b in path.bytes() {
        let unreserved = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'/');
        if unreserved {
            s.push(b as char);
        } else {
            s.push_str(&format!("%{b:02X}"));
        }
    }
    s
}
