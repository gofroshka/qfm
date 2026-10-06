//! Smoke test: the embedded QML frontend must compile and load.

use qmetaobject::prelude::*;
use qmetaobject::{CompilationMode, ComponentStatus, QUrl, QmlComponent, QmlEngine};

#[test]
fn main_qml_loads() {
    // A QmlEngine owns the process-wide QApplication, so this must be the only
    // test creating one.
    if std::env::var_os("QT_QPA_PLATFORM").is_none() {
        std::env::set_var("QT_QPA_PLATFORM", "offscreen");
    }

    qfm::register_qml();

    let mut engine = QmlEngine::new();
    engine.set_property("qfmInitialPath".into(), QString::from("").into());
    engine.set_property("qfmPortalMode".into(), false.into());
    let mut component = QmlComponent::new(&engine);
    component.load_url(
        QUrl::from(QString::from("qrc:/qml/Main.qml")),
        CompilationMode::PreferSynchronous,
    );

    assert_eq!(
        component.status(),
        ComponentStatus::Ready,
        "qrc:/qml/Main.qml failed to compile (see Qt errors above)"
    );

    // Instantiating evaluates the bindings; a null pointer means creation failed.
    let object = component.create();
    assert!(!object.is_null(), "qrc:/qml/Main.qml failed to instantiate");
}
