# qfm

A minimalist file manager for Linux desktops, written in Rust with a plain Qt
Quick (QML) frontend. The QML is compiled into the binary as a Qt resource, so
`qfm` ships as a single self-contained executable — no separate QML tree and no
Qt Widgets.

Beyond browsing, `qfm` also implements the XDG Desktop Portal `FileChooser`
interface, so the same binary can act as the system's file/folder picker and be
started on demand by `xdg-desktop-portal`.

## Why another file manager?

Most Qt file managers pull in Qt Widgets or a whole shell runtime. `qfm` keeps
the UI declarative and the backend small:

- **One binary.** The backend (filesystem, trash, clipboard,
  portal) is exposed to QML through a thin `Qfm` module and the frontend is
  embedded via `qrc!`, so there is nothing to install alongside the executable.
- **A picker and a browser in one.** Run it normally to browse, or let
  `xdg-desktop-portal` activate it as the `FileChooser` backend — same code
  paths, same look.
- **Correct trash semantics.** Deletions go to the freedesktop.org home trash
  with proper `.trashinfo` records, restore/undo and opportunistic purging.

## Features

- Directory listing with directories first, then case-insensitive by name.
- Toggle hidden files, live filter/search and keyboard type-ahead.
- Browser-style navigation history (back/forward), home and parent shortcuts.
- Multi-selection: Ctrl/Shift-click, rubber-band marquee, `Ctrl+A`, Space to
  toggle and step down.
- Copy/paste through the system clipboard (`text/uri-list` via `wl-copy`,
  `xclip` or `xsel`) with an in-app fallback so Paste works without a helper.
- Drag & drop: internal drags move entries, drags from other apps copy them;
  drop onto folder rows and breadcrumbs.
- freedesktop.org home trash: move to trash, restore, permanently delete, empty,
  count badge, single-level undo, and automatic cross-device fallback.
- Quick Look overlay with image zoom/pan, video/audio playback and a text/code
  viewer.
- Preview side panel for images, audio, text samples and file metadata.
- New file, new folder and rename dialogs with collision-free suggested names.
- Auto-refresh: external changes to the open directory are applied in place
  while keeping the filter, selection and cursor.
- Context menu, toasts, a custom status bar and edge/corner system resize.
- CLI: open a path from the command line and accept `file://` URIs.
- Portal picker: open files/folders, save a new file with an editable suggested
  name and overwrite confirmation, or choose a folder for saving several files.

## Architecture

```
        browse mode                         picker mode
            │                                   │
            ▼                                   ▼
   Qt Quick QML window  ◄───────────  xdg-desktop-portal
            │  Qfm module                (D-Bus FileChooser)
            ▼                                   ▲
   Rust backend: fs · trash · clipboard · preview · portal
```

The Rust side registers the `Qfm` QML module (`Fs`, `Clipboard`, `Preview`,
`Trash`, `Portal`); `Main.qml` owns the application state and layout, reusable
pieces live in `qml/components/`, and pure helpers in `qml/Utils.js`. Every
listing and trash entry crosses the boundary as JSON.

The dedicated `qfm --portal` process runs the `FileChooser` backend on a
background D-Bus thread and parks incoming requests in a queue; the GUI thread
polls it, shows the picker dialog and answers the original D-Bus call with
`file://` URIs. Normal browser processes do not claim the portal service, so
file chooser requests always open separately from existing browser windows.
Closing the picker cancels its request and hides the dialog until the next one.

## Building

With Cargo:

```sh
cargo build --release
```

Or with Nix:

```sh
nix build
```

For development, the repo ships a flake dev shell wired up for
[direnv](https://direnv.net/). After `direnv allow` the shell (cargo,
rust-analyzer, Qt 6 base/declarative/multimedia) loads automatically and sets
`CARGO_TARGET_DIR` to keep build artifacts out of the source tree.

Run the tests with:

```sh
cargo test
```

The test suite includes a smoke test that compiles and instantiates the
embedded QML, so it needs Qt's QML import paths and an offscreen or Wayland QPA
platform (the Nix `preCheck` sets these up). The portal regression test also
needs `dbus-daemon`; it runs browser and picker processes on a private session
bus to check service ownership and dialog cancellation.

## Running

```sh
qfm                 # open the home directory
qfm ~/Downloads     # open a directory (or file:// URI) directly
qfm --portal        # start hidden as the FileChooser backend
```

### Configuration

All configuration is via environment variables, so launchers and desktop files
stay declarative:

| Variable | Default | Meaning |
|---|---|---|
| `QFM_QML` | embedded `qrc:/qml/Main.qml` | Load the frontend from a file instead of the built-in resource. |
| `QFM_TRASH_DAYS` | `30` | Purge trash entries older than this many days (`0` disables). |
| `QFM_TRASH_MAX_MB` | `5000` | Maximum home-trash size in MiB (`0` disables). |

The trash lives in `$XDG_DATA_HOME/Trash` (or `~/.local/share/Trash`) and is
purged opportunistically on every trash mutation.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `↑` / `↓`, `Home` / `End`, `PageUp` / `PageDown` | Move the cursor |
| `Enter` | Open the entry in the browser; confirm the selection in a picker |
| `→` | Enter the folder / open the file |
| `←` / `Backspace` | Go to the parent directory |
| `Alt+←` / `Alt+→` / `Alt+↑` | History back / forward / parent |
| `Space` | Quick Look the current entry |
| `Ctrl+Space` | Toggle selection and step down |
| `Ctrl+A` | Select all |
| `Ctrl+C` / `Ctrl+Shift+C` | Copy selection / copy path |
| `Ctrl+V` | Paste into the current directory |
| `F2` | Rename |
| `Delete` / `Shift+Delete` | Move to trash / delete permanently |
| `Ctrl+N` / `Ctrl+Shift+N` | New file / new folder |
| `Ctrl+H` | Toggle hidden files |
| `Ctrl+F` | Focus search |
| `F3` | Toggle the preview panel |
| `F5` / `Ctrl+R` | Refresh |
| `Esc` | Close overlay, clear selection or quit |
| any printable key | Type-ahead jump to a matching name |

## Portal integration

The Nix package installs the portal definition, a D-Bus activation file and a
desktop entry:

- `share/xdg-desktop-portal/portals/qfm.portal` (interface `FileChooser`,
  currently `UseIn=niri`)
- `share/dbus-1/services/org.freedesktop.impl.portal.desktop.qfm.service`
- `share/applications/qfm.desktop`

The portal claims `org.freedesktop.impl.portal.desktop.qfm` and serves
`org.freedesktop.impl.portal.FileChooser`, implementing `OpenFile`, `SaveFile`
and `SaveFiles`. Requests time out after five minutes if the window is never
answered.

`SaveFile` shows a **File name** field populated from the application's suggested
name. Navigate to the destination folder and click **Save**; the calling
application writes the file after receiving its path. Existing files require
replacement confirmation. `SaveFiles` chooses the currently open folder and
returns a destination for each supplied filename, avoiding name collisions.
In folder pickers, **Enter** chooses the highlighted folder without entering it;
the accept button chooses the currently open folder. Use **→** to enter a folder
and **←** to return to its parent. In file pickers, Enter confirms the file
selection; in save dialogs, it confirms the destination filename. The
application's title, accept button label and suggested starting folder are
passed through to the UI.

## License

MIT — see [LICENSE](LICENSE).
