{
  pkgs ? import <nixpkgs> { },
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
  ];

  # qttypes' build script locates Qt through qmake -query.
  QMAKE = "${pkgs.qt6.qtbase}/bin/qmake6";

  # wrapQtAppsHook wires QT_PLUGIN_PATH / QML2_IMPORT_PATH into the wrapper so
  # `import QtQuick` resolves at runtime without a dev shell.
  dontWrapQtApps = false;

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
