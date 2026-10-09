//! End-to-end regressions for portal ownership and file chooser modes.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use zbus::blocking::{connection::Builder, Proxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const SERVICE: &str = "org.freedesktop.impl.portal.desktop.qfm";

struct Process(Child);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start_qfm(address: &str, portal: bool) -> (Process, Receiver<String>) {
    start_qfm_with_fixture(address, portal, "portal_mode.qml")
}

fn start_qfm_with_fixture(
    address: &str,
    portal: bool,
    fixture: &str,
) -> (Process, Receiver<String>) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_qfm"));
    command
        .env("DBUS_SESSION_BUS_ADDRESS", address)
        .env("QT_QPA_PLATFORM", "offscreen")
        .env("QT_QPA_PLATFORMTHEME", "")
        .env("QT_NO_XDG_DESKTOP_PORTAL", "1")
        .env("QT_QUICK_BACKEND", "software")
        .env("RUST_LOG", "warn")
        .env(
            "QFM_QML",
            format!("{}/tests/fixtures/{fixture}", env!("CARGO_MANIFEST_DIR")),
        )
        .arg(env!("CARGO_MANIFEST_DIR"))
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    if portal {
        command.arg("--portal");
    }
    let mut child = command.spawn().expect("start qfm");
    let stderr = child.stderr.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            if tx.send(line.expect("read qfm output")).is_err() {
                break;
            }
        }
    });
    (Process(child), rx)
}

fn wait_for_output(output: &Receiver<String>, marker: &str) -> String {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut lines = Vec::new();
    loop {
        let line = output
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .unwrap_or_else(|e| panic!("waiting for {marker}: {e}; output: {lines:?}"));
        assert!(!line.contains("qfm-test-failure:"), "{line}");
        if let Some((_, value)) = line.split_once(marker) {
            return value.to_owned();
        }
        lines.push(line);
    }
}

fn start_bus() -> (Process, String) {
    let mut bus = Process(
        Command::new("dbus-daemon")
            .arg(concat!(
                "--config-file=",
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/dbus-session.conf"
            ))
            .args(["--nofork", "--print-address=1"])
            .stdout(Stdio::piped())
            .spawn()
            .expect("start private dbus-daemon"),
    );
    let mut address = String::new();
    BufReader::new(bus.0.stdout.take().unwrap())
        .read_line(&mut address)
        .expect("read private D-Bus address");
    (bus, address.trim().to_owned())
}

#[test]
fn browser_leaves_file_chooser_to_dedicated_backend() {
    // Isolate service ownership from the user's real desktop portal.
    let (_bus, address) = start_bus();
    let address = address.as_str();
    let connection = Builder::address(address).unwrap().build().unwrap();
    let dbus = Proxy::new(
        &connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .unwrap();

    let (mut browser, browser_output) = start_qfm(address, false);
    let ready = wait_for_output(&browser_output, "qfm-test-ready:");
    assert!(ready.contains("\"shown\":true"), "{ready}");
    assert!(ready.contains("\"picker\":null"), "{ready}");
    assert!(ready.contains(env!("CARGO_MANIFEST_DIR")), "{ready}");
    assert!(ready.contains("\"dialog\":false"), "{ready}");
    let owned: bool = dbus.call("NameHasOwner", &(SERVICE,)).unwrap();
    assert!(!owned, "normal browser claimed the FileChooser service");

    let (mut backend, backend_output) = start_qfm(address, true);
    let ready = wait_for_output(&backend_output, "qfm-test-ready:");
    assert!(ready.contains("\"shown\":false"), "{ready}");
    assert!(ready.contains("\"dialog\":true"), "{ready}");
    // The D-Bus worker starts independently of the GUI thread.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let owner: String = loop {
        if let Ok(owner) = dbus.call("GetNameOwner", &(SERVICE,)) {
            break owner;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "portal service did not start"
        );
        std::thread::sleep(Duration::from_millis(20));
    };

    let chooser = Proxy::new(
        &connection,
        SERVICE,
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.impl.portal.FileChooser",
    )
    .unwrap();
    // Closing the first dialog must cancel promptly and keep the backend alive
    // so it can answer another request using the same D-Bus connection.
    for i in 0..2 {
        let handle =
            OwnedObjectPath::try_from(format!("/org/freedesktop/portal/desktop/request/test/{i}"))
                .unwrap();
        let (code, results): (u32, HashMap<String, OwnedValue>) = chooser
            .call(
                "OpenFile",
                &(
                    handle,
                    "qfm.test",
                    "",
                    "Choose a file",
                    HashMap::<String, OwnedValue>::new(),
                ),
            )
            .unwrap();
        assert_eq!(code, 1);
        assert!(results.is_empty());
        let cancelled = wait_for_output(&backend_output, "qfm-test-cancelled:");
        assert!(cancelled.contains("\"shown\":false"), "{cancelled}");
        assert!(cancelled.contains("\"picker\":null"), "{cancelled}");
        let current_owner: String = dbus.call("GetNameOwner", &(SERVICE,)).unwrap();
        assert_eq!(owner, current_owner);
        assert!(backend.0.try_wait().unwrap().is_none());
        assert!(browser.0.try_wait().unwrap().is_none());
    }
}

struct TempDirectory(PathBuf);

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn bytes_value(text: &str) -> OwnedValue {
    let mut bytes = text.as_bytes().to_vec();
    bytes.push(0);
    Value::from(bytes).try_into().unwrap()
}

fn choose(
    chooser: &Proxy<'_>,
    method: &str,
    title: &str,
    options: HashMap<String, OwnedValue>,
) -> (u32, Vec<String>) {
    let handle =
        OwnedObjectPath::try_from("/org/freedesktop/portal/desktop/request/test/chooser").unwrap();
    let (code, mut results): (u32, HashMap<String, OwnedValue>) = chooser
        .call(method, &(handle, "qfm.test", "", title, options))
        .unwrap();
    let uris = results
        .remove("uris")
        .map(|v| Vec::<String>::try_from(v).unwrap())
        .unwrap_or_default();
    (code, uris)
}

fn request_state(output: &Receiver<String>) -> String {
    let state = wait_for_output(output, "qfm-test-request:");
    wait_for_output(output, "qfm-test-finished:");
    state
}

#[test]
fn chooser_preserves_save_destinations_and_open_selections() {
    let temp = TempDirectory(std::env::temp_dir().join(format!(
        "qfm-picker-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    )));
    let folder = temp.0.join("Бэкапы с пробелами");
    std::fs::create_dir_all(folder.join("subfolder")).unwrap();
    std::fs::write(
        folder.join("subfolder/backup.dump"),
        "existing nested backup",
    )
    .unwrap();
    let folder_text = folder.to_str().unwrap();
    let folder_options =
        || HashMap::from([("current_folder".to_owned(), bytes_value(folder_text))]);
    let uri = |name: &str| qfm::util::text::file_uri(folder.join(name).to_str().unwrap());

    let (_bus, address) = start_bus();
    let connection = Builder::address(address.as_str()).unwrap().build().unwrap();
    let (mut backend, output) = start_qfm_with_fixture(&address, true, "portal_chooser.qml");
    wait_for_output(&output, "qfm-test-ready:");
    let dbus = Proxy::new(
        &connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let owned: bool = dbus.call("NameHasOwner", &(SERVICE,)).unwrap();
        if owned {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "portal did not start");
        std::thread::sleep(Duration::from_millis(20));
    }
    let chooser = Proxy::new(
        &connection,
        SERVICE,
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.impl.portal.FileChooser",
    )
    .unwrap();

    let name = "gofronet_2026-10-08.sql.gz";
    let mut options = folder_options();
    options.insert("current_name".into(), Value::from(name).try_into().unwrap());
    options.insert(
        "accept_label".into(),
        Value::from("_Save backup").try_into().unwrap(),
    );
    options.insert("directory".into(), true.into());
    options.insert("multiple".into(), true.into());
    assert_eq!(
        choose(&chooser, "SaveFile", "Save backup", options),
        (0, vec![uri(name)])
    );
    let state = request_state(&output);
    assert!(state.contains("\"mode\":\"save\""), "{state}");
    assert!(state.contains("\"label\":\"Save backup\""), "{state}");
    assert!(state.contains(folder_text), "{state}");
    assert!(state.contains(name), "{state}");
    assert!(!folder.join(name).exists(), "picker pre-created the backup");
    // The caller, rather than the picker, writes the backup after the reply.
    std::fs::write(folder.join(name), "database dump").unwrap();

    let mut options = folder_options();
    options.insert(
        "current_name".into(),
        Value::from("suggested.sql.gz").try_into().unwrap(),
    );
    assert_eq!(
        choose(&chooser, "SaveFile", "Edit filename", options),
        (0, vec![uri("Бэкап базы.sql.gz")])
    );
    request_state(&output);
    assert!(!folder.join("Бэкап базы.sql.gz").exists());

    assert_eq!(
        choose(&chooser, "SaveFile", "Validate filename", folder_options()),
        (0, vec![uri("valid.sql.gz")])
    );
    request_state(&output);

    for title in ["Choose folder with Enter", "Choose folder from search"] {
        let mut options = folder_options();
        options.insert("directory".into(), true.into());
        assert_eq!(
            choose(&chooser, "OpenFile", title, options),
            (0, vec![uri("subfolder")])
        );
        request_state(&output);
    }

    assert_eq!(
        choose(
            &chooser,
            "OpenFile",
            "Open backup with Enter",
            folder_options()
        ),
        (0, vec![uri(name)])
    );
    request_state(&output);

    let mut options = folder_options();
    options.insert(
        "current_name".into(),
        Value::from("enter.sql.gz").try_into().unwrap(),
    );
    assert_eq!(
        choose(&chooser, "SaveFile", "Save backup with Enter", options),
        (0, vec![uri("enter.sql.gz")])
    );
    request_state(&output);
    assert!(!folder.join("enter.sql.gz").exists());

    let mut options = folder_options();
    let files: Vec<Vec<u8>> = ["backup.dump", "new.dump"]
        .iter()
        .map(|name| name.as_bytes().iter().copied().chain([0]).collect())
        .collect();
    options.insert("files".into(), Value::from(files).try_into().unwrap());
    assert_eq!(
        choose(&chooser, "SaveFiles", "Save backups with Enter", options),
        (
            0,
            vec![uri("subfolder/backup 2.dump"), uri("subfolder/new.dump")]
        )
    );
    request_state(&output);
    assert_eq!(
        std::fs::read_to_string(folder.join("subfolder/backup.dump")).unwrap(),
        "existing nested backup"
    );
    assert!(!folder.join("subfolder/new.dump").exists());

    let options = HashMap::from([(
        "current_file".into(),
        bytes_value(folder.join(name).to_str().unwrap()),
    )]);
    assert_eq!(
        choose(&chooser, "SaveFile", "Replace backup", options),
        (0, vec![uri(name)])
    );
    let state = request_state(&output);
    assert!(state.contains(name), "{state}");
    assert!(state.contains(folder_text), "{state}");
    assert_eq!(
        std::fs::read_to_string(folder.join(name)).unwrap(),
        "database dump"
    );

    for title in ["Decline replacement", "Cancel saving"] {
        let mut options = folder_options();
        options.insert("current_name".into(), Value::from(name).try_into().unwrap());
        assert_eq!(choose(&chooser, "SaveFile", title, options), (1, vec![]));
        request_state(&output);
        assert_eq!(
            std::fs::read_to_string(folder.join(name)).unwrap(),
            "database dump"
        );
    }

    let mut options = folder_options();
    options.insert(
        "current_name".into(),
        Value::from("subfolder").try_into().unwrap(),
    );
    assert_eq!(
        choose(&chooser, "SaveFile", "Directory collision", options),
        (1, vec![])
    );
    request_state(&output);
    assert!(folder.join("subfolder").is_dir());

    let mut options = folder_options();
    let files: Vec<Vec<u8>> = [name, name, "another.dump"]
        .iter()
        .map(|name| name.as_bytes().iter().copied().chain([0]).collect())
        .collect();
    options.insert("files".into(), Value::from(files).try_into().unwrap());
    assert_eq!(
        choose(&chooser, "SaveFiles", "Save several backups", options),
        (
            0,
            vec![
                uri("gofronet_2026-10-08.sql 2.gz"),
                uri("gofronet_2026-10-08.sql 3.gz"),
                uri("another.dump")
            ]
        )
    );
    request_state(&output);
    assert!(!folder.join("another.dump").exists());

    std::fs::write(folder.join("second.dump"), "second backup").unwrap();
    for title in ["Open backups", "Open backups with Enter"] {
        let mut options = folder_options();
        options.insert("multiple".into(), true.into());
        assert_eq!(
            choose(&chooser, "OpenFile", title, options),
            (0, vec![uri(name), uri("second.dump")])
        );
        request_state(&output);
    }

    let mut options = folder_options();
    options.insert("directory".into(), true.into());
    assert_eq!(
        choose(&chooser, "OpenFile", "Choose backup folder", options),
        (0, vec![qfm::util::text::file_uri(folder_text)])
    );
    request_state(&output);

    let options = HashMap::from([(
        "current_name".into(),
        Value::from("default.sql.gz").try_into().unwrap(),
    )]);
    assert_eq!(
        choose(
            &chooser,
            "SaveFile",
            "Save without suggested folder",
            options
        ),
        (
            0,
            vec![qfm::util::text::file_uri(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/default.sql.gz"
            ))]
        )
    );
    let state = request_state(&output);
    assert!(state.contains("\"label\":\"Save\""), "{state}");
    assert!(!PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("default.sql.gz")
        .exists());
    assert!(backend.0.try_wait().unwrap().is_none());
}
