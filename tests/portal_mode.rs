//! Regression: browser processes must not take over the FileChooser service.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use zbus::blocking::{connection::Builder, Proxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

const SERVICE: &str = "org.freedesktop.impl.portal.desktop.qfm";

struct Process(Child);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start_qfm(address: &str, portal: bool) -> (Process, Receiver<String>) {
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
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/portal_mode.qml"
            ),
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
        if let Some((_, value)) = line.split_once(marker) {
            return value.to_owned();
        }
        lines.push(line);
    }
}

#[test]
fn browser_leaves_file_chooser_to_dedicated_backend() {
    // Isolate service ownership from the user's real desktop portal.
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
    let address = address.trim();
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
