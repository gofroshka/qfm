//! D-Bus interface implementation for the FileChooser portal.

use std::collections::HashMap;
use std::path::Path;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use super::{Mode, Pending, Shared};

pub(crate) struct Chooser {
    pub(crate) shared: Arc<Shared>,
}

fn opt_bool(options: &HashMap<String, OwnedValue>, key: &str) -> bool {
    options
        .get(key)
        .and_then(|v| v.downcast_ref::<bool>().ok())
        .unwrap_or(false)
}

fn opt_string(options: &HashMap<String, OwnedValue>, key: &str) -> String {
    options
        .get(key)
        .and_then(|v| v.downcast_ref::<&str>().ok())
        .unwrap_or_default()
        .to_owned()
}

// Portal paths and SaveFiles names are NUL-terminated byte arrays, not strings.
fn decode_path(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn opt_path(options: &HashMap<String, OwnedValue>, key: &str) -> String {
    options
        .get(key)
        .and_then(|v| Vec::<u8>::try_from(v.try_clone().ok()?).ok())
        .map(|bytes| decode_path(&bytes))
        .unwrap_or_default()
}

impl Pending {
    fn new(
        handle: String,
        mode: Mode,
        title: String,
        options: &HashMap<String, OwnedValue>,
    ) -> Self {
        let mut current_folder = opt_path(options, "current_folder");
        let mut current_name = opt_string(options, "current_name");
        if mode == Mode::SaveFile {
            let current_file = opt_path(options, "current_file");
            if !current_file.is_empty() {
                let path = Path::new(&current_file);
                if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                    current_folder = parent.to_string_lossy().into_owned();
                }
                if current_name.is_empty() {
                    current_name = path
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_default();
                }
            }
        }
        let files = options
            .get("files")
            .and_then(|v| Vec::<Vec<u8>>::try_from(v.try_clone().ok()?).ok())
            .unwrap_or_default()
            .iter()
            .map(|bytes| decode_path(bytes))
            .filter(|name| !name.is_empty())
            .collect();

        Self {
            handle,
            mode,
            title,
            accept_label: opt_string(options, "accept_label"),
            directory: mode == Mode::SaveFiles
                || (mode == Mode::OpenFile && opt_bool(options, "directory")),
            multiple: mode == Mode::OpenFile && opt_bool(options, "multiple"),
            current_folder,
            current_name,
            files,
        }
    }
}

impl Chooser {
    fn choose(
        &self,
        handle: String,
        mode: Mode,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let request = Pending::new(handle.clone(), mode, title, &options);
        log::debug!("FileChooser {mode:?}: {}", request.title);

        let (tx, rx) = mpsc::channel();
        self.shared
            .waiting
            .lock()
            .unwrap()
            .insert(handle.clone(), tx);
        self.shared.pending.lock().unwrap().push_back(request);

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
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), Mode::OpenFile, title, options)
    }

    fn save_file(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), Mode::SaveFile, title, options)
    }

    fn save_files(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.choose(handle.to_string(), Mode::SaveFiles, title, options)
    }
}
