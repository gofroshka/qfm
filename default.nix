{
  pkgs,
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "qfm";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = with pkgs; [
    pkg-config
    qt6.wrapQtAppsHook
  ];

  buildInputs = with pkgs; [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtmultimedia
  ];

  nativeCheckInputs = [ pkgs.dbus ];

  # qttypes' build script locates Qt through qmake -query.
  QMAKE = "${pkgs.qt6.qtbase}/bin/qmake6";

  # The QML smoke test compiles the embedded frontend, so `cargo test` needs
  # Qt's QML import paths (the wrapper only sets these for the installed bin).
  preCheck = ''
    export QML2_IMPORT_PATH="${pkgs.qt6.qtdeclarative}/lib/qt-6/qml:${pkgs.qt6.qtmultimedia}/lib/qt-6/qml"
    export QT_PLUGIN_PATH="${pkgs.qt6.qtbase}/lib/qt-6/plugins:${pkgs.qt6.qtmultimedia}/lib/qt-6/plugins"
    export QT_QPA_PLATFORM=offscreen
    export XDG_CACHE_HOME="$(mktemp -d)"
  '';

  # wrapQtAppsHook wires QT_PLUGIN_PATH / QML2_IMPORT_PATH into the wrapper so
  # `import QtQuick` resolves at runtime without a dev shell.
  dontWrapQtApps = false;

  # QtMultimedia ships its QML module separately from qtdeclarative; make it
  # importable (and its ffmpeg backend discoverable) in the wrapped binary.
  preFixup = ''
    qtWrapperArgs+=(--prefix QML2_IMPORT_PATH : ${pkgs.qt6.qtmultimedia}/lib/qt-6/qml)
    qtWrapperArgs+=(--prefix QT_PLUGIN_PATH : ${pkgs.qt6.qtmultimedia}/lib/qt-6/plugins)
  '';

  postInstall = ''
    install -Dm644 assets/qfm.desktop $out/share/applications/qfm.desktop

    # Tells xdg-desktop-portal which interfaces this backend implements.
    install -Dm644 assets/qfm.portal \
      $out/share/xdg-desktop-portal/portals/qfm.portal

    # D-Bus activation so xdg-desktop-portal can start the FileChooser backend
    # on demand (without a running instance).
    mkdir -p $out/share/dbus-1/services
    substitute assets/org.freedesktop.impl.portal.desktop.qfm.service \
      $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.qfm.service \
      --replace-fail '@QFM@' "$out/bin/qfm"
  '';

  meta = with pkgs.lib; {
    description = "Minimalist file manager (Rust backend + Qt Quick QML)";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "qfm";
  };
}
