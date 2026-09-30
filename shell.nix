{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  name = "qfm";

  nativeBuildInputs = with pkgs; [
    cargo
    rustc
    pkg-config
  ];

  buildInputs = with pkgs; [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtmultimedia
  ];

  # qttypes' build script locates Qt via qmake -query.
  QMAKE = "${pkgs.qt6.qtbase}/bin/qmake6";

  shellHook = ''
    # Keep build artifacts out of the source tree (it is also used as a flake
    # input, where the whole directory gets copied to the store).
    export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$HOME/.cache/qfm-target}"

    # mkShell does not pull in Qt's setup-hook env, wire the import/plugin
    # paths manually so `import QtQuick` resolves at runtime.
    export QML2_IMPORT_PATH="${pkgs.qt6.qtdeclarative}/lib/qt-6/qml:${pkgs.qt6.qtmultimedia}/lib/qt-6/qml''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
    export QT_PLUGIN_PATH="${pkgs.qt6.qtbase}/lib/qt-6/plugins:${pkgs.qt6.qtmultimedia}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    export QT_QPA_PLATFORM="''${QT_QPA_PLATFORM:-wayland}"

    echo "qfm dev shell — build with: cargo build --release"
    echo "run: $CARGO_TARGET_DIR/release/qfm"
  '';
}
