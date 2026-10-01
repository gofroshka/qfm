{
  description = "qfm — minimalist file manager (Rust backend + Qt Quick QML)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system: {
        default = (pkgsFor system).callPackage ./default.nix { };
      });

      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = with pkgsFor system; [
            cargo
            rustc
            pkg-config
            qt6.qtbase
            qt6.qtdeclarative
            qt6.qtmultimedia

            # Editor tooling, surfaced to Zed via direnv (see .envrc).
            nixd
            rust-analyzer
            nixfmt
          ];

          # qttypes' build script locates Qt via qmake -query.
          QMAKE = "${(pkgsFor system).qt6.qtbase}/bin/qmake6";

          shellHook = ''
            # Keep build artifacts out of the source tree (it is also used as a
            # flake input, where the whole directory gets copied to the store).
            export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$HOME/.cache/qfm-target}"

            # mkShell does not pull in Qt's setup-hook env, wire the import/plugin
            # paths manually so `import QtQuick` resolves at runtime.
            # QML_IMPORT_PATH is the modern name qmllint/qmlls read via `-E`;
            # QML2_IMPORT_PATH is kept for compatibility.
            export QML_IMPORT_PATH="${(pkgsFor system).qt6.qtdeclarative}/lib/qt-6/qml:${(pkgsFor system).qt6.qtmultimedia}/lib/qt-6/qml''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
            export QML2_IMPORT_PATH="$QML_IMPORT_PATH''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
            export QT_PLUGIN_PATH="${(pkgsFor system).qt6.qtbase}/lib/qt-6/plugins:${(pkgsFor system).qt6.qtmultimedia}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
            export QT_QPA_PLATFORM="''${QT_QPA_PLATFORM:-wayland}"

            echo "qfm dev shell — build with: cargo build --release"
            echo "run: $CARGO_TARGET_DIR/release/qfm"
          '';
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
