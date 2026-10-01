//! D-Bus interface implementation for the FileChooser portal.

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use super::{Pending, Shared};

pub(crate) struct Chooser {
    pub(crate) shared: Arc<Shared>,
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
