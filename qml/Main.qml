// qfm — minimalist file manager (plain Qt Quick, no Quickshell).
// Styling mirrors the graphite shell theme: near-black surfaces, muted greys,
// a single light-grey accent and a small radius scale (20 / 12 / 8, pills h/2).
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtMultimedia
import Qfm 1.0

Window {
    id: win

    width: 960
    height: 620
    minimumWidth: 520
    minimumHeight: 360
    visible: shown
    title: win.picker ? "Choose" : "Files"
    color: theme.bg

    // Hidden when started as a portal backend until a request arrives.
    property bool shown: !qfmPortalMode
    // Active FileChooser request from the Rust portal backend, or null.
    property var picker: null

    QtObject {
        id: theme
        readonly property color bg: "#0b0b0c"
        readonly property color surface: "#0b0b0c"
        readonly property color surface2: "#171719"
        readonly property color elevated: "#1e1e22"
        readonly property color track: "#2a2a2e"
        readonly property color hover: Qt.rgba(1, 1, 1, 0.08)
        readonly property color border: Qt.rgba(1, 1, 1, 0.08)
        readonly property color text: "#f3f3f4"
        readonly property color textDim: "#8a8a92"
        readonly property color accent: "#d7d7db"
        readonly property color link: "#7fb8d8"
        readonly property color danger: "#e5786d"
        readonly property int radiusSmall: 8
        readonly property string font: "Inter"
        readonly property string icon: "JetBrainsMono Nerd Font"
    }

    // Rust backend, registered from main.rs as the QML type `Fs` in module `Qfm`.
    Fs { id: fs }

    // ---- state -------------------------------------------------------------
    property string curPath: ""
    property string curParent: ""
    property var entries: []
    property int index: 0
    property string status: ""
    property bool showHidden: false
    property string filter: ""
    // Preview side panel (photos / audio / metadata).
    property bool preview: true
    // Multi-selection: path -> true. `anchor` is the shift-click origin.
    property var selected: ({})
    property int anchor: -1
    // Raw JSON of the last listing, used to detect external changes.
    property string listingRaw: ""
    // Number of items currently in the trash (for the toolbar badge).
    property int trashCount: 0
    // Pending operation launched from a prompt/confirm dialog.
    property var pendingOp: ({})

    readonly property bool overlayOpen: menu.shown || prompt.shown || confirm.shown || trashPanel.shown

    readonly property var visibleEntries: {
        const q = win.filter.toLowerCase();
        const src = win.entries || [];
        const out = [];
        for (let i = 0; i < src.length; i++) {
            const e = src[i];
            if (!win.showHidden && e.hidden) continue;
            if (q.length > 0 && e.name.toLowerCase().indexOf(q) < 0) continue;
            out.push(e);
        }
        return out;
    }

    // Number of selected entries that are currently visible.
    readonly property int selectedCount: {
        const sel = win.selected || {};
        const list = win.visibleEntries;
        let n = 0;
        for (let i = 0; i < list.length; i++) if (sel[list[i].path]) n++;
        return n;
    }

    // Entry under the cursor, and the one shown in the preview panel.
    readonly property var activeEntry: {
        const list = win.visibleEntries;
        return (win.index >= 0 && win.index < list.length) ? list[win.index] : null;
    }
    readonly property var previewEntry: win.activeEntry

    readonly property string imageSource:
        win.isImage(win.previewEntry) ? fs.file_uri(win.previewEntry.path) : ""
    readonly property string mediaSource:
        (win.isAudio(win.previewEntry) || win.isVideo(win.previewEntry))
            ? fs.file_uri(win.previewEntry.path) : ""

    readonly property var crumbs: {
        const p = win.curPath || "";
        const out = [];
        if (p === "") return out;
        out.push({ name: "/", path: "/" });
        const parts = p.split("/").filter(s => s.length > 0);
        let acc = "";
        for (let i = 0; i < parts.length; i++) {
            acc += "/" + parts[i];
            out.push({ name: parts[i], path: acc });
        }
        return out;
    }

    onIndexChanged: if (index >= 0) list.positionViewAtIndex(index, ListView.Contain)
    onVisibleEntriesChanged: if (win.index >= win.visibleEntries.length)
                                 win.index = Math.max(0, win.visibleEntries.length - 1)

    // ---- navigation --------------------------------------------------------
    function navigate(path, keepFilter) {
        const raw = fs.list_json(path);
        let data;
        try { data = JSON.parse(raw); } catch (e) { data = { error: "parse error" }; }
        if (data.error !== undefined) {
            win.status = data.error;
            win.toastMsg(data.error);
            return;
        }
        win.listingRaw = raw;
        win.curPath = data.path;
        win.curParent = data.parent;
        win.entries = data.entries;
        win.index = 0;
        win.selected = ({});
        win.anchor = -1;
        if (!keepFilter) { win.filter = ""; search.text = ""; }
        win.status = (data.entries ? data.entries.length : 0) + " items";
    }

    function refresh(selectPath) {
        const sel = win.visibleEntries[win.index];
        const want = selectPath !== undefined ? selectPath : (sel ? sel.path : null);
        win.navigate(win.curPath, true);
        if (want) {
            const list = win.visibleEntries;
            for (let i = 0; i < list.length; i++) {
                if (list[i].path === want) { win.index = i; break; }
            }
        }
    }

    // Poll the current directory and apply external changes in place, keeping
    // the filter, multi-selection and cursor position.
    function autoRefresh() {
        if (win.overlayOpen || win.curPath === "") return;
        const raw = fs.list_json(win.curPath);
        if (raw === win.listingRaw) return;
        let data;
        try { data = JSON.parse(raw); } catch (e) { return; }
        if (data.error !== undefined || data.path !== win.curPath) return;

        // Snapshot where the user is before the model changes.
        const activePath = win.activeEntry ? win.activeEntry.path : null;
        const prev = win.selected || {};
        const wasSelected = [];
        for (const k in prev) if (prev[k]) wasSelected.push(k);

        win.listingRaw = raw;
        win.curParent = data.parent;
        win.entries = data.entries;

        const present = {};
        for (let i = 0; i < data.entries.length; i++) present[data.entries[i].path] = true;

        const next = {};
        let any = false;
        for (let i = 0; i < wasSelected.length; i++) {
            if (present[wasSelected[i]]) { next[wasSelected[i]] = true; any = true; }
        }
        win.selected = any ? next : ({});

        if (activePath !== null && present[activePath]) {
            const list = win.visibleEntries;
            for (let i = 0; i < list.length; i++) {
                if (list[i].path === activePath) { win.index = i; break; }
            }
        } else if (win.index >= win.visibleEntries.length) {
            win.index = Math.max(0, win.visibleEntries.length - 1);
        }
    }

    function goHome() { win.navigate(fs.home()); }
    function goUp() { if (win.curPath !== win.curParent) win.navigate(win.curParent); }

    function move(delta) {
        if (win.visibleEntries.length === 0) { win.index = 0; return; }
        if (win.selectedCount > 0) win.selected = ({});
        win.index = Math.max(0, Math.min(win.visibleEntries.length - 1, win.index + delta));
    }

    // ---- selection ---------------------------------------------------------
    function isSelected(path) { return !!(win.selected && win.selected[path]); }

    function selectOnly(i) {
        const e = win.visibleEntries[i];
        if (!e) return;
        const next = {};
        next[e.path] = true;
        win.selected = next;
        win.anchor = i;
    }

    function toggleSelect(i) {
        const e = win.visibleEntries[i];
        if (!e) return;
        const next = {};
        const cur = win.selected || {};
        for (const k in cur) if (cur[k]) next[k] = true;
        if (next[e.path]) delete next[e.path]; else next[e.path] = true;
        win.selected = next;
        win.anchor = i;
    }

    function selectRange(i) {
        const list = win.visibleEntries;
        if (win.anchor < 0 || win.anchor >= list.length) { win.selectOnly(i); return; }
        const a = Math.min(win.anchor, i);
        const b = Math.max(win.anchor, i);
        const next = {};
        for (let k = a; k <= b; k++) if (list[k]) next[list[k].path] = true;
        win.selected = next;
    }

    function selectAll() {
        const next = {};
        const list = win.visibleEntries;
        for (let k = 0; k < list.length; k++) next[list[k].path] = true;
        win.selected = next;
    }

    // Selected paths in list order, falling back to the entry under the cursor.
    function selectedPaths() {
        const out = [];
        const sel = win.selected || {};
        const list = win.visibleEntries;
        for (let i = 0; i < list.length; i++) if (sel[list[i].path]) out.push(list[i].path);
        if (out.length === 0 && win.activeEntry) out.push(win.activeEntry.path);
        return out;
    }

    // ---- copy / paste ------------------------------------------------------
    function copySelection() {
        const paths = win.selectedPaths();
        if (paths.length === 0) return;
        fs.copy_to_clipboard(paths.join("\n"));
        win.toastMsg(paths.length === 1 ? "Copied" : ("Copied " + paths.length + " items"));
    }

    function copyPath() {
        if (!win.activeEntry) return;
        fs.copy_text(win.activeEntry.path);
        win.toastMsg("Path copied");
    }

    function pasteClipboard() {
        if (fs.clipboard_count() === 0) { win.toastMsg("Clipboard is empty"); return; }
        const err = fs.paste(win.curPath);
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Pasted");
        win.refresh();
    }

    // ---- file kinds --------------------------------------------------------
    function isImage(e) {
        return !!e && !e.dir && /\.(png|jpe?g|gif|webp|svg|bmp|avif|ico|tiff?)$/i.test(e.name);
    }
    function isAudio(e) {
        return !!e && !e.dir && /\.(mp3|flac|wav|ogg|oga|m4a|opus|aac|wma|alac)$/i.test(e.name);
    }
    function isVideo(e) {
        return !!e && !e.dir && /\.(mp4|mkv|webm|mov|avi|m4v|ogv)$/i.test(e.name);
    }

    function openIndex(i) {
        const list = win.visibleEntries;
        if (i < 0 || i >= list.length) return;
        const e = list[i];
        if (e.dir) { win.navigate(e.path); return; }
        if (win.picker) {
            win.index = i;
            if (!win.picker.directory) win.pickerAccept();
            return;
        }
        const err = fs.open(e.path);
        if (err) win.toastMsg(err);
    }

    // ---- toast -------------------------------------------------------------
    function toastMsg(t) { toast.show(t); }
    function toastUndo(t, names) {
        toast.showUndo(t, function() { win.undoTrash(names); });
    }

    // ---- create / rename ---------------------------------------------------
    function openNewFile() {
        win.pendingOp = { type: "newfile" };
        prompt.title = "New file";
        prompt.glyph = "\uf15b";
        prompt.placeholder = "File name";
        prompt.value = fs.suggest_name(win.curPath, "New File", "txt");
        prompt.confirmLabel = "Create";
        prompt.shown = true;
    }

    function openNewFolder() {
        win.pendingOp = { type: "newfolder" };
        prompt.title = "New folder";
        prompt.glyph = "\uf07b";
        prompt.placeholder = "Folder name";
        prompt.value = fs.suggest_name(win.curPath, "New Folder", "");
        prompt.confirmLabel = "Create";
        prompt.shown = true;
    }

    function startRename(i) {
        const e = win.visibleEntries[i];
        if (!e) return;
        win.pendingOp = { type: "rename", path: e.path };
        prompt.title = "Rename";
        prompt.glyph = e.dir ? "\uf07b" : "\uf15b";
        prompt.placeholder = "New name";
        prompt.value = e.name;
        prompt.confirmLabel = "Rename";
        prompt.shown = true;
    }

    function promptAccept(text) {
        const name = (text || "").trim();
        if (name.length === 0 || name === "." || name === ".." || name.indexOf("/") >= 0) {
            win.toastMsg("Invalid name");
            return;
        }
        const op = win.pendingOp || {};
        let err = "";
        let selectPath = null;
        if (op.type === "newfile") {
            err = fs.create_file(win.curPath, name);
            selectPath = win.joinPath(win.curPath, name);
        } else if (op.type === "newfolder") {
            err = fs.create_dir(win.curPath, name);
            selectPath = win.joinPath(win.curPath, name);
        } else if (op.type === "rename") {
            err = fs.rename(op.path, name);
            const parent = op.path.substring(0, op.path.lastIndexOf("/"));
            selectPath = win.joinPath(parent, name);
        }
        if (err) { win.toastMsg(err); return; }
        win.toastMsg(op.type === "rename" ? "Renamed" : "Created");
        win.refresh(selectPath);
    }

    function joinPath(dir, name) {
        if (!dir || dir === "/") return "/" + name;
        return dir.replace(/\/+$/, "") + "/" + name;
    }

    // ---- delete ------------------------------------------------------------
    function deleteIndex(i, permanent) {
        const e = win.visibleEntries[i];
        if (!e) return;
        win.startDelete([e.path], [e.name], permanent);
    }

    function deleteSelection(permanent) {
        const paths = win.selectedPaths();
        if (paths.length === 0) return;
        const names = [];
        for (let i = 0; i < paths.length; i++) names.push(paths[i].split("/").pop());
        win.startDelete(paths, names, permanent);
    }

    function startDelete(paths, names, permanent) {
        win.pendingOp = { type: "delete", paths: paths, names: names, permanent: !!permanent };
        confirm.title = permanent ? "Delete permanently?" : "Move to Trash?";
        const what = paths.length > 1
            ? (paths.length + " items")
            : ("\u201c" + names[0] + "\u201d");
        confirm.message = permanent
            ? what + " will be permanently deleted. This cannot be undone."
            : what + " will be moved to the trash.";
        confirm.confirmLabel = permanent ? "Delete" : "Trash";
        confirm.danger = permanent;
        confirm.shown = true;
    }

    function confirmAccept() {
        const op = win.pendingOp || {};
        if (op.type !== "delete") return;
        if (op.permanent) {
            const err = fs.delete_permanent(op.paths.join("\n"));
            if (err) { win.toastMsg(err); return; }
            win.toastMsg(op.paths.length > 1 ? "Deleted " + op.paths.length + " items" : "Deleted");
            win.refresh();
            return;
        }
        const res = fs.trash(op.paths.join("\n"));
        if (res === "error:EXDEV") {
            win.startDelete(op.paths, op.names, true);
            win.toastMsg("This volume has no trash");
            return;
        }
        if (res.indexOf("error:") === 0) { win.toastMsg(res.slice(6)); return; }
        const names = res;
        win.refresh();
        win.trashCount = fs.trash_count();
        win.toastUndo(names.split("\n").length > 1
                      ? ("Trashed " + names.split("\n").length + " items") : "Trashed",
                      names);
    }

    // Undo the most recent trash operation.
    function undoTrash(names) {
        if (!names) return;
        const err = fs.trash_restore(names);
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Restored");
        win.refresh();
        win.trashCount = fs.trash_count();
    }

    // ---- trash panel -------------------------------------------------------
    function openTrash() {
        trashPanel.reload();
        trashPanel.shown = true;
    }

    function trashRestore(names) {
        const err = fs.trash_restore(names.join("\n"));
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Restored");
        win.refresh();
        win.trashCount = fs.trash_count();
        trashPanel.reload();
    }

    function trashDelete(names) {
        const err = fs.delete_permanent(names.join("\n"));
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Deleted");
        win.trashCount = fs.trash_count();
        trashPanel.reload();
    }

    function trashEmpty() {
        const err = fs.trash_empty();
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Trash emptied");
        win.trashCount = 0;
        trashPanel.reload();
    }

    // ---- context menu ------------------------------------------------------
    function openMenu(i, mx, my) {
        if (i >= 0) {
            win.index = i;
            const entry = win.visibleEntries[i];
            if (entry && !win.isSelected(entry.path)) win.selectOnly(i);
        }
        const e = i >= 0 ? win.visibleEntries[i] : null;
        const n = win.selectedCount;
        const items = [];
        if (e) {
            items.push({ label: "Open", glyph: e.dir ? "\uf07c" : "\uf15b", act: "open" });
            items.push({
                label: n > 1 ? ("Copy " + n + " items") : "Copy",
                glyph: "\uf0c5", act: "copy", key: "Ctrl+C"
            });
            items.push({ label: "Copy Path", glyph: "\uf0c1", act: "copypath", key: "Ctrl+\u21e7C" });
            if (n <= 1) items.push({ label: "Rename", glyph: "\uf044", act: "rename", key: "F2" });
            items.push({ sep: true });
            if (n > 1) items.push({
                label: "Move " + n + " items to Trash", glyph: "\uf1f8", act: "trash", key: "Del"
            });
            else {
                items.push({ label: "Move to Trash", glyph: "\uf1f8", act: "trash", key: "Del" });
                items.push({ label: "Delete Permanently", glyph: "\uf2ed", act: "delete", danger: true, key: "\u21e7Del" });
            }
            items.push({ sep: true });
        }
        if (fs.clipboard_count() > 0)
            items.push({ label: "Paste", glyph: "\uf0ea", act: "paste", key: "Ctrl+V" });
        items.push({ label: "New Folder", glyph: "\uf115", act: "newfolder", key: "Ctrl+\u21e7N" });
        items.push({ label: "New File", glyph: "\uf15b", act: "newfile", key: "Ctrl+N" });
        items.push({ label: "Refresh", glyph: "\uf021", act: "refresh", key: "F5" });

        let h = 8;
        for (let k = 0; k < items.length; k++) h += items[k].sep ? menu.sepHeight : menu.rowHeight;
        menu.items = items;
        menu.x = Math.max(8, Math.min(mx, win.width - menu.width - 8));
        menu.y = Math.max(8, Math.min(my, win.height - h - 8));
        menu.shown = true;
    }

    function menuChoose(act) {
        const i = win.index;
        if (act === "open") win.openIndex(i);
        else if (act === "copy") win.copySelection();
        else if (act === "copypath") win.copyPath();
        else if (act === "paste") win.pasteClipboard();
        else if (act === "rename") win.startRename(i);
        else if (act === "trash") {
            if (win.selectedCount > 1) win.deleteSelection(false);
            else win.deleteIndex(i, false);
        } else if (act === "delete") {
            if (win.selectedCount > 1) win.deleteSelection(true);
            else win.deleteIndex(i, true);
        }
        else if (act === "newfolder") win.openNewFolder();
        else if (act === "newfile") win.openNewFile();
        else if (act === "refresh") win.refresh();
    }

    // ---- formatting --------------------------------------------------------
    function fmtSize(e) {
        if (e.dir || e.link) return "--";
        const b = e.bytes;
        if (b < 1024) return b + " B";
        if (b < 1048576) return (b / 1024).toFixed(1) + " KB";
        if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB";
        return (b / 1073741824).toFixed(1) + " GB";
    }

    function fmtTime(sec) {
        const d = new Date(sec * 1000);
        function p(n) { return (n < 10 ? "0" : "") + n; }
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
             + " " + p(d.getHours()) + ":" + p(d.getMinutes());
    }

    function fmtClock(ms) {
        const total = Math.floor(Math.max(0, ms || 0) / 1000);
        const m = Math.floor(total / 60);
        const s = total % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    function describe(e) {
        if (!e) return "";
        const parts = [];
        if (e.link) parts.push("Symlink");
        else if (e.dir) parts.push("Folder");
        else if (win.isImage(e)) parts.push("Image");
        else if (win.isAudio(e)) parts.push("Audio");
        else if (win.isVideo(e)) parts.push("Video");
        else parts.push("File");
        if (!e.dir && !e.link) parts.push(win.fmtSize(e));
        parts.push(win.fmtTime(e.mtime));
        return parts.join("  \u00b7  ");
    }

    function iconFor(e) {
        if (e.link) return "\uf481";
        if (e.dir) return "\uf07b";
        const n = e.name.toLowerCase();
        if (/\.(png|jpe?g|gif|webp|svg|bmp|avif)$/.test(n)) return "\uf1c5";
        if (/\.(mp3|flac|wav|ogg|m4a|opus)$/.test(n)) return "\uf1c7";
        if (/\.(mp4|mkv|webm|mov|avi)$/.test(n)) return "\uf1c8";
        if (/\.(zip|tar|gz|xz|zst|7z|rar)$/.test(n)) return "\uf1c6";
        if (/\.(rs|py|js|ts|qml|c|cpp|h|go|sh|kdl|toml|json|yaml|yml)$/.test(n)) return "\uf1c9";
        if (/\.(pdf)$/.test(n)) return "\uf1c1";
        return "\uf15b";
    }

    // ---- portal picker -----------------------------------------------------
    function pollPortal() {
        const raw = fs.poll_portal();
        if (!raw) return;
        let req;
        try { req = JSON.parse(raw); } catch (e) { return; }
        win.picker = req;
        win.shown = true;
        win.raise();
        win.requestActivate();
        const start = (qfmInitialPath && qfmInitialPath !== "") ? qfmInitialPath : fs.home();
        win.navigate(start);
    }

    function pickerAccept() {
        if (!win.picker) return;
        const list = win.visibleEntries;
        const e = list[win.index];
        const paths = [];
        if (win.picker.directory) {
            paths.push((e && e.dir) ? e.path : win.curPath);
        } else {
            if (e && !e.dir) paths.push(e.path);
            else return;
        }
        win.pickerAnswer(0, paths);
    }

    function pickerCancel() { win.pickerAnswer(1, []); }

    function pickerAnswer(code, paths) {
        if (win.picker && win.picker.handle) fs.portal_reply(win.picker.handle, code, paths.join("\n"));
        win.picker = null;
        if (qfmPortalMode) win.shown = false;
    }

    // ---- root container ----------------------------------------------------
    Item {
        id: root
        anchors.fill: parent
        focus: true

        Component.onCompleted: win.navigate(
            (qfmInitialPath && qfmInitialPath !== "") ? qfmInitialPath : fs.home())

        // subtle top glow for depth
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 140
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.035) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        // Poll the Rust portal backend for pending FileChooser requests.
        Timer {
            interval: 200
            running: true
            repeat: true
            onTriggered: win.pollPortal()
        }

        // Watch the current directory so the listing stays in sync with the
        // filesystem without a manual refresh.
        Timer {
            interval: 1000
            running: win.shown
            repeat: true
            onTriggered: {
                win.autoRefresh();
                win.trashCount = fs.trash_count();
            }
        }

        // ---- top bar -------------------------------------------------------
        Item {
            id: top
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 52

            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: theme.border
            }

            Row {
                id: navButtons
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 6

                BarButton { glyph: "\uf060"; onActivated: win.goUp() }
                BarButton { glyph: "\uf015"; onActivated: win.goHome() }
                BarButton { glyph: "\uf021"; onActivated: win.refresh() }
            }

            // ---- breadcrumb ------------------------------------------------
            Flickable {
                id: crumbs
                anchors {
                    left: navButtons.right; leftMargin: 10
                    right: tools.left; rightMargin: 12
                    verticalCenter: parent.verticalCenter
                }
                height: 28
                contentWidth: crumbRow.width
                clip: true
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds

                function toEnd() { contentX = Math.max(0, contentWidth - width); }
                onContentWidthChanged: toEnd()
                onWidthChanged: toEnd()

                Connections {
                    target: win
                    function onCurPathChanged() { crumbs.toEnd(); }
                }

                Row {
                    id: crumbRow
                    height: crumbs.height
                    spacing: 0

                    Repeater {
                        model: win.crumbs

                        delegate: Item {
                            id: crumb
                            required property var modelData
                            required property int index

                            width: crumbBtn.width + crumbSep.width
                            height: crumbs.height

                            Rectangle {
                                id: crumbBtn
                                anchors.verticalCenter: parent.verticalCenter
                                width: crumbText.implicitWidth + 16
                                height: 24
                                radius: 12
                                color: crumbMa.containsMouse ? theme.hover : "transparent"
                                Behavior on color { ColorAnimation { duration: 90 } }

                                Text {
                                    id: crumbText
                                    anchors.centerIn: parent
                                    text: crumb.modelData.name
                                    color: crumb.modelData.path === win.curPath ? theme.text : theme.textDim
                                    font.family: theme.font
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: crumbMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.navigate(crumb.modelData.path)
                                }
                            }

                            Text {
                                id: crumbSep
                                anchors { left: crumbBtn.right; verticalCenter: parent.verticalCenter }
                                visible: crumb.index < win.crumbs.length - 1
                                width: visible ? 14 : 0
                                text: "\uf105"
                                color: theme.textDim
                                font.family: theme.icon
                                font.pixelSize: 9
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }

            // ---- tools -----------------------------------------------------
            Row {
                id: tools
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 6

                SearchField {
                    id: search
                    width: 180
                    onTextChanged: win.filter = search.text
                }
                BarButton {
                    glyph: win.showHidden ? "\uf06e" : "\uf070"
                    active: win.showHidden
                    onActivated: win.showHidden = !win.showHidden
                }
                BarButton {
                    glyph: "\uf03e"
                    active: win.preview
                    onActivated: win.preview = !win.preview
                }
                BarButton {
                    glyph: "\uf1f8"
                    active: win.trashCount > 0
                    onActivated: win.openTrash()
                }
            }
        }

        // ---- column header -------------------------------------------------
        Item {
            id: header
            anchors { left: parent.left; right: previewPanel.left; top: top.bottom }
            anchors.leftMargin: 8; anchors.rightMargin: 8
            height: 24

            Text {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                anchors.leftMargin: 10
                text: win.crumbs.length > 0 ? "Name" : ""
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 10
                font.letterSpacing: 0.6
            }
            Text {
                anchors { right: parent.right; rightMargin: 14 + 130 + 12; verticalCenter: parent.verticalCenter }
                width: 90
                horizontalAlignment: Text.AlignRight
                text: "Size"
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 10
                font.letterSpacing: 0.6
            }
            Text {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                width: 130
                horizontalAlignment: Text.AlignRight
                text: "Modified"
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 10
                font.letterSpacing: 0.6
            }
        }

        // ---- list ----------------------------------------------------------
        // Right-click on empty space opens the background context menu
        // (New File / New Folder live there now).
        MouseArea {
            id: listBackground
            anchors.fill: list
            acceptedButtons: Qt.RightButton
            onClicked: (mouse) => {
                const p = listBackground.mapToItem(root, mouse.x, mouse.y);
                win.openMenu(-1, p.x, p.y);
            }
        }

        ListView {
            id: list
            anchors {
                left: parent.left; right: previewPanel.left
                top: header.bottom; bottom: status.top
                leftMargin: 8; rightMargin: 8
                topMargin: 2; bottomMargin: 8
            }
            clip: true
            model: win.visibleEntries
            currentIndex: win.index
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 2000

            highlightMoveDuration: 150
            highlightResizeDuration: 0
            highlight: Rectangle {
                color: Qt.rgba(1, 1, 1, 0.06)
                radius: theme.radiusSmall

                Rectangle {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    anchors.leftMargin: 2
                    width: 3
                    height: Math.max(0, parent.height - 14)
                    radius: 1.5
                    color: theme.accent
                }
            }

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index

                width: ListView.view.width
                height: 38
                radius: theme.radiusSmall
                color: win.isSelected(row.modelData.path) ? Qt.rgba(1, 1, 1, 0.11)
                     : rowMa.containsMouse ? theme.hover
                     : "transparent"
                Behavior on color { ColorAnimation { duration: 100 } }

                opacity: 0
                SequentialAnimation {
                    id: entrance
                    PauseAnimation { duration: Math.min(row.index, 10) * 12 }
                    NumberAnimation {
                        target: row; property: "opacity"; to: 1
                        duration: 200; easing.type: Easing.OutCubic
                    }
                }
                Component.onCompleted: entrance.start()

                Row {
                    anchors { fill: parent; leftMargin: 10; rightMargin: 14 }
                    spacing: 12

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.iconFor(row.modelData)
                        color: row.modelData.link ? theme.link
                             : row.modelData.dir ? theme.accent
                             : theme.textDim
                        font.family: theme.icon
                        font.pixelSize: 15
                        width: 20
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 20 - 90 - 130 - 36
                        text: row.modelData.name
                        color: row.modelData.hidden ? theme.textDim : theme.text
                        font.family: theme.font
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 90
                        horizontalAlignment: Text.AlignRight
                        text: win.fmtSize(row.modelData)
                        color: theme.textDim
                        font.family: theme.font
                        font.pixelSize: 11
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 130
                        horizontalAlignment: Text.AlignRight
                        text: win.fmtTime(row.modelData.mtime)
                        color: theme.textDim
                        font.family: theme.font
                        font.pixelSize: 11
                    }
                }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton) {
                            const p = rowMa.mapToItem(root, mouse.x, mouse.y);
                            win.openMenu(row.index, p.x, p.y);
                        } else if (mouse.modifiers & Qt.ControlModifier) {
                            win.index = row.index;
                            win.toggleSelect(row.index);
                        } else if (mouse.modifiers & Qt.ShiftModifier) {
                            win.index = row.index;
                            win.selectRange(row.index);
                        } else {
                            win.selected = ({});
                            win.anchor = row.index;
                            win.index = row.index;
                        }
                    }
                    onDoubleClicked: (mouse) => {
                        if (mouse.button === Qt.LeftButton) win.openIndex(row.index);
                    }
                }
            }
        }

        // ---- empty state ---------------------------------------------------
        Column {
            anchors.centerIn: list
            spacing: 8
            visible: win.visibleEntries.length === 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: win.filter.length > 0 ? "\uf002" : "\uf07b"
                color: theme.track
                font.family: theme.icon
                font.pixelSize: 34
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: win.filter.length > 0 ? "No matches" : "Empty folder"
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 13
            }
        }

        // ---- preview panel -------------------------------------------------
        Rectangle {
            id: previewPanel
            anchors {
                top: top.bottom; bottom: status.top
                right: parent.right; rightMargin: 8
                topMargin: 6; bottomMargin: 8
            }
            width: win.preview ? 320 : 0
            radius: theme.radiusSmall
            color: theme.surface2
            border.width: 1
            border.color: theme.border
            clip: true
            visible: width > 1
            opacity: win.preview ? 1 : 0
            Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 140 } }

            // Declared here so playback state survives selection changes.
            MediaPlayer {
                id: player
                source: win.mediaSource
                audioOutput: AudioOutput { volume: 1.0 }
                onSourceChanged: player.stop()
            }
            Connections {
                target: win
                function onPreviewChanged() { if (!win.preview) player.stop(); }
            }

            Flickable {
                anchors.fill: parent
                anchors.margins: 12
                contentWidth: width
                contentHeight: body.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: body
                    width: parent.width
                    spacing: 12

                    // photo
                    Rectangle {
                        width: parent.width
                        height: win.isImage(win.previewEntry) ? Math.round(width * 0.72) : 0
                        visible: win.isImage(win.previewEntry)
                        radius: theme.radiusSmall
                        color: theme.bg
                        clip: true
                        Image {
                            anchors.fill: parent
                            anchors.margins: 2
                            source: win.imageSource
                            asynchronous: true
                            cache: false
                            sourceSize.width: 1024
                            sourceSize.height: 1024
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                    }

                    // audio
                    Rectangle {
                        width: parent.width
                        height: 208
                        visible: win.isAudio(win.previewEntry)
                        radius: theme.radiusSmall
                        color: theme.bg

                        Column {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 12

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "\uf1c7"
                                color: theme.accent
                                font.family: theme.icon
                                font.pixelSize: 38
                            }
                            Text {
                                width: parent.width
                                text: win.previewEntry ? win.previewEntry.name : ""
                                color: theme.text
                                font.family: theme.font
                                font.pixelSize: 13
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideMiddle
                            }

                            Item {
                                width: parent.width
                                height: 16
                                Rectangle {
                                    id: seekTrack
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 5
                                    radius: 2.5
                                    color: theme.track
                                    Rectangle {
                                        height: parent.height
                                        radius: 2.5
                                        color: theme.accent
                                        width: {
                                            const d = player.duration;
                                            return d > 0 ? seekTrack.width * Math.max(0, Math.min(1, player.position / d)) : 0;
                                        }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: (m) => {
                                        if (player.duration > 0)
                                            player.position = Math.max(0, Math.min(1, m.x / width)) * player.duration;
                                    }
                                }
                            }

                            Row {
                                width: parent.width
                                Text {
                                    width: parent.width / 2
                                    text: win.fmtClock(player.position)
                                    color: theme.textDim
                                    font.family: theme.font
                                    font.pixelSize: 10
                                }
                                Text {
                                    width: parent.width / 2
                                    horizontalAlignment: Text.AlignRight
                                    text: win.fmtClock(player.duration)
                                    color: theme.textDim
                                    font.family: theme.font
                                    font.pixelSize: 10
                                }
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 10
                                BarButton {
                                    glyph: "\uf048"
                                    onActivated: player.position = Math.max(0, player.position - 10000)
                                }
                                BarButton {
                                    glyph: player.playbackState === MediaPlayer.PlayingState ? "\uf04c" : "\uf04b"
                                    onActivated: player.playbackState === MediaPlayer.PlayingState
                                                  ? player.pause() : player.play()
                                }
                                BarButton {
                                    glyph: "\uf051"
                                    onActivated: player.position = Math.min(player.duration, player.position + 10000)
                                }
                            }
                        }
                    }

                    // generic file
                    Column {
                        width: parent.width
                        spacing: 10
                        visible: win.previewEntry !== null
                              && !win.isImage(win.previewEntry) && !win.isAudio(win.previewEntry)
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: win.iconFor(win.previewEntry)
                            color: theme.track
                            font.family: theme.icon
                            font.pixelSize: 44
                        }
                    }

                    // details
                    Column {
                        width: parent.width
                        spacing: 6
                        visible: win.previewEntry !== null
                        Text {
                            width: parent.width
                            text: win.previewEntry ? win.previewEntry.name : ""
                            color: theme.text
                            font.family: theme.font
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            wrapMode: Text.WrapAnywhere
                        }
                        Text {
                            width: parent.width
                            text: win.describe(win.previewEntry)
                            color: theme.textDim
                            font.family: theme.font
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }
                        Text {
                            width: parent.width
                            visible: win.previewEntry !== null
                            text: win.previewEntry ? win.previewEntry.path : ""
                            color: theme.textDim
                            font.family: theme.font
                            font.pixelSize: 10
                            opacity: 0.7
                            wrapMode: Text.WrapAnywhere
                        }
                    }

                    // no selection
                    Text {
                        width: parent.width
                        visible: win.previewEntry === null
                        text: "Nothing selected"
                        color: theme.textDim
                        font.family: theme.font
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Item { width: 1; height: 4 }
                }
            }
        }

        // ---- scrollbar -----------------------------------------------------
        Rectangle {
            id: scrollbar
            readonly property real viewport: Math.max(1, list.height - list.topMargin - list.bottomMargin)
            readonly property real overflow: Math.max(0, list.contentHeight - viewport)

            visible: overflow > 1
            width: 6
            radius: 3
            color: theme.track
            x: list.x + list.width - width - 3
            height: overflow > 1 ? Math.max(28, viewport * viewport / Math.max(1, list.contentHeight)) : 0
            y: list.y + list.topMargin + (overflow > 1
                ? (Math.max(0, Math.min(overflow, list.contentY)) / overflow) * (viewport - height)
                : 0)
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        // ---- status bar ----------------------------------------------------
        Item {
            id: status
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 32

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1
                color: theme.border
            }
            Text {
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                text: win.selectedCount > 0
                      ? (win.selectedCount + " selected")
                      : (win.visibleEntries.length + " / " + win.entries.length)
                color: win.selectedCount > 0 ? theme.text : theme.textDim
                font.family: theme.font
                font.pixelSize: 11
            }
            Text {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                visible: win.picker === null
                text: win.status
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 11
            }

            Row {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 8
                visible: win.picker !== null

                ActionButton { label: "Cancel"; onActivated: win.pickerCancel() }
                ActionButton {
                    label: win.picker && win.picker.directory ? "Choose folder" : "Choose file"
                    primary: true
                    onActivated: win.pickerAccept()
                }
            }
        }

        // ---- keyboard ------------------------------------------------------
        Keys.onUpPressed: (e) => { if (!win.overlayOpen) { win.move(-1); e.accepted = true; } }
        Keys.onDownPressed: (e) => { if (!win.overlayOpen) { win.move(1); e.accepted = true; } }
        Keys.onReturnPressed: (e) => { if (!win.overlayOpen) { win.openIndex(win.index); e.accepted = true; } }
        Keys.onEnterPressed: (e) => { if (!win.overlayOpen) { win.openIndex(win.index); e.accepted = true; } }
        Keys.onBackPressed: (e) => { if (!win.overlayOpen) { win.goUp(); e.accepted = true; } }
        Keys.onEscapePressed: (e) => {
            if (menu.shown) { menu.shown = false; e.accepted = true; }
            else if (win.selectedCount > 0) { win.selected = ({}); e.accepted = true; }
            else if (!win.overlayOpen) { win.picker ? win.pickerCancel() : Qt.quit(); e.accepted = true; }
        }
        Keys.onPressed: (e) => {
            if (win.overlayOpen && !menu.shown) { return; }
            const ctrl = e.modifiers & Qt.ControlModifier;
            const shift = e.modifiers & Qt.ShiftModifier;
            if (ctrl && shift && e.key === Qt.Key_N) {
                win.openNewFolder();
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_N) {
                win.openNewFile();
                e.accepted = true;
            } else if (e.key === Qt.Key_F2) {
                win.startRename(win.index);
                e.accepted = true;
            } else if (e.key === Qt.Key_Delete) {
                win.deleteIndex(win.index, !!shift);
                e.accepted = true;
            } else if (e.key === Qt.Key_Home) {
                win.index = 0; e.accepted = true;
            } else if (e.key === Qt.Key_End) {
                win.index = Math.max(0, win.visibleEntries.length - 1); e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_H) {
                win.showHidden = !win.showHidden;
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_R || e.key === Qt.Key_F5) {
                win.refresh();
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_A) {
                win.selectAll();
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_C) {
                if (shift) win.copyPath(); else win.copySelection();
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_V) {
                win.pasteClipboard();
                e.accepted = true;
            } else if (e.key === Qt.Key_F3) {
                win.preview = !win.preview;
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_F) {
                search.focusInput();
                e.accepted = true;
            }
        }

        // ---- context menu backdrop ----------------------------------------
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            visible: menu.shown
            z: 90
            MouseArea { anchors.fill: parent; onClicked: menu.shown = false }
        }

        ContextMenu {
            id: menu
            onChosen: (act) => win.menuChoose(act)
        }

        PromptDialog {
            id: prompt
            onAccepted: (text) => { prompt.shown = false; root.forceActiveFocus(); win.promptAccept(text); }
            onCancelled: { prompt.shown = false; root.forceActiveFocus(); }
        }

        ConfirmDialog {
            id: confirm
            onConfirmed: { confirm.shown = false; root.forceActiveFocus(); win.confirmAccept(); }
            onCancelled: { confirm.shown = false; root.forceActiveFocus(); }
        }

        TrashPanel { id: trashPanel }

        Toast { id: toast }
    }

    // ---- components --------------------------------------------------------
    component BarButton: Rectangle {
        id: btn
        property string glyph
        property bool active: false
        signal activated()

        width: 32
        height: 32
        radius: height / 2
        color: (ma.containsMouse || btn.active) ? theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: 110 } }

        Text {
            anchors.centerIn: parent
            text: btn.glyph
            color: btn.active ? theme.text : theme.textDim
            font.family: theme.icon
            font.pixelSize: 14
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
    }

    component ActionButton: Rectangle {
        id: ab
        property string label
        property bool primary: false
        property bool danger: false
        signal activated()

        implicitWidth: abText.implicitWidth + 30
        implicitHeight: 28
        radius: height / 2
        color: ab.primary ? theme.accent
             : ab.danger ? Qt.rgba(0.9, 0.42, 0.39, 0.14)
             : theme.hover
        border.width: 1
        border.color: ab.primary ? "transparent"
                    : ab.danger ? Qt.rgba(0.9, 0.42, 0.39, 0.35)
                    : theme.border
        Behavior on color { ColorAnimation { duration: 110 } }
        Behavior on border.color { ColorAnimation { duration: 110 } }

        Text {
            id: abText
            anchors.centerIn: parent
            text: ab.label
            color: ab.primary ? theme.bg : ab.danger ? theme.danger : theme.text
            font.family: theme.font
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ab.activated()
        }
    }

    component SearchField: Rectangle {
        id: sf
        property alias text: sInput.text
        function focusInput() { sInput.forceActiveFocus(); sInput.selectAll(); }

        height: 32
        radius: height / 2
        color: theme.surface2
        border.width: 1
        border.color: sInput.activeFocus ? theme.accent : theme.border
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Text {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            text: "\uf002"
            color: theme.textDim
            font.family: theme.icon
            font.pixelSize: 12
        }
        TextInput {
            id: sInput
            anchors {
                left: parent.left; leftMargin: 32
                right: parent.right; rightMargin: 12
                verticalCenter: parent.verticalCenter
            }
            color: theme.text
            font.family: theme.font
            font.pixelSize: 12
            selectionColor: theme.accent
            selectedTextColor: theme.bg
            clip: true
            onAccepted: win.openIndex(win.index)
            Keys.onDownPressed: (e) => { win.move(1); e.accepted = true; }
            Keys.onUpPressed: (e) => { win.move(-1); e.accepted = true; }
            Keys.onEscapePressed: (e) => { sInput.text = ""; root.forceActiveFocus(); e.accepted = true; }
        }
    }

    component ContextMenu: Rectangle {
        id: menuPopup
        property bool shown: false
        property var items: []
        readonly property int rowHeight: 30
        readonly property int sepHeight: 9
        signal chosen(string act)

        width: 218
        implicitHeight: {
            let h = 8;
            for (let i = 0; i < items.length; i++) h += items[i].sep ? sepHeight : rowHeight;
            return h;
        }
        height: implicitHeight
        radius: 12
        color: theme.elevated
        border.width: 1
        border.color: theme.border
        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        scale: shown ? 1 : 0.97
        transformOrigin: Item.TopLeft
        z: 95
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
            id: menuCol
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 4 }
            Repeater {
                model: menuPopup.items
                delegate: Item {
                    id: menuRow
                    required property var modelData
                    width: menuCol.width
                    height: modelData.sep ? menuPopup.sepHeight : menuPopup.rowHeight

                    Rectangle {
                        visible: modelData.sep === true
                        anchors {
                            left: parent.left; right: parent.right
                            leftMargin: 10; rightMargin: 10
                            verticalCenter: parent.verticalCenter
                        }
                        height: 1
                        color: theme.border
                    }

                    Rectangle {
                        id: rowBg
                        visible: modelData.sep !== true
                        anchors.fill: parent
                        radius: 8
                        color: itemMa.containsMouse ? theme.hover : "transparent"
                        Behavior on color { ColorAnimation { duration: 90 } }

                        Text {
                            id: rowIcon
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            width: 16
                            text: modelData.glyph || ""
                            color: modelData.danger ? theme.danger : theme.textDim
                            font.family: theme.icon
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Text {
                            id: rowHint
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            text: modelData.key || ""
                            color: theme.textDim
                            font.family: theme.font
                            font.pixelSize: 10
                            opacity: 0.75
                        }
                        Text {
                            anchors {
                                left: rowIcon.right; leftMargin: 10
                                right: rowHint.left; rightMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            text: modelData.label
                            color: modelData.danger ? theme.danger : theme.text
                            font.family: theme.font
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        MouseArea {
                            id: itemMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: menuPopup.chosen(modelData.act)
                        }
                    }
                }
            }
        }
    }

    component PromptDialog: Item {
        id: pd
        property bool shown: false
        property string title: ""
        property string glyph: "\uf15b"
        property string placeholder: "Name"
        property string value: ""
        property string confirmLabel: "Create"
        signal accepted(string text)
        signal cancelled()

        anchors.fill: parent
        z: 100
        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        onShownChanged: if (shown) {
            pInput.text = pd.value;
            Qt.callLater(function() { pInput.forceActiveFocus(); pInput.selectAll(); });
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: pd.cancelled() }
        }

        Rectangle {
            id: panel
            anchors.centerIn: parent
            width: Math.min(420, win.width - 48)
            height: 172
            radius: 16
            color: theme.surface2
            border.width: 1
            border.color: theme.border
            scale: pd.shown ? 1 : 0.94
            Behavior on scale {
                NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.06 }
            }
            MouseArea { anchors.fill: parent }

            Text {
                id: pIcon
                anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 20 }
                text: pd.glyph
                color: theme.accent
                font.family: theme.icon
                font.pixelSize: 18
            }
            Text {
                anchors {
                    left: pIcon.right; leftMargin: 12
                    right: parent.right; rightMargin: 20
                    verticalCenter: pIcon.verticalCenter
                }
                text: pd.title
                color: theme.text
                font.family: theme.font
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Rectangle {
                id: field
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 20; rightMargin: 20; topMargin: 62
                }
                height: 40
                radius: 10
                color: theme.bg
                border.width: 1
                border.color: pInput.activeFocus ? theme.accent : theme.border
                Behavior on border.color { ColorAnimation { duration: 120 } }

                TextInput {
                    id: pInput
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                    verticalAlignment: TextInput.AlignVCenter
                    color: theme.text
                    font.family: theme.font
                    font.pixelSize: 13
                    selectionColor: theme.accent
                    selectedTextColor: theme.bg
                    clip: true
                    onAccepted: pd.accepted(text)
                    Keys.onEscapePressed: (e) => { pd.cancelled(); e.accepted = true; }
                }
                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    visible: pInput.text.length === 0
                    text: pd.placeholder
                    color: theme.textDim
                    font.family: theme.font
                    font.pixelSize: 13
                }
            }

            Row {
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 16 }
                spacing: 8
                ActionButton { label: "Cancel"; onActivated: pd.cancelled() }
                ActionButton {
                    label: pd.confirmLabel
                    primary: true
                    onActivated: pd.accepted(pInput.text)
                }
            }
        }
    }

    component ConfirmDialog: Item {
        id: cd
        property bool shown: false
        property string title: ""
        property string message: ""
        property string confirmLabel: "OK"
        property bool danger: false
        signal confirmed()
        signal cancelled()

        anchors.fill: parent
        z: 110
        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        focus: shown
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        onShownChanged: if (shown) cd.forceActiveFocus()
        Keys.onEscapePressed: (e) => { cd.cancelled(); e.accepted = true; }
        Keys.onReturnPressed: (e) => { cd.confirmed(); e.accepted = true; }
        Keys.onEnterPressed: (e) => { cd.confirmed(); e.accepted = true; }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: cd.cancelled() }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420, win.width - 48)
            height: 168
            radius: 16
            color: theme.surface2
            border.width: 1
            border.color: theme.border
            scale: cd.shown ? 1 : 0.94
            Behavior on scale {
                NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.06 }
            }
            MouseArea { anchors.fill: parent }

            Text {
                id: cIcon
                anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 20 }
                text: cd.danger ? "\uf2ed" : "\uf1f8"
                color: cd.danger ? theme.danger : theme.accent
                font.family: theme.icon
                font.pixelSize: 18
            }
            Text {
                anchors {
                    left: cIcon.right; leftMargin: 12
                    right: parent.right; rightMargin: 20
                    verticalCenter: cIcon.verticalCenter
                }
                text: cd.title
                color: theme.text
                font.family: theme.font
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                anchors {
                    left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 20; rightMargin: 20; topMargin: 58
                }
                text: cd.message
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
            Row {
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 16 }
                spacing: 8
                ActionButton { label: "Cancel"; onActivated: cd.cancelled() }
                ActionButton {
                    label: cd.confirmLabel
                    primary: !cd.danger
                    danger: cd.danger
                    onActivated: cd.confirmed()
                }
            }
        }
    }

    component TrashPanel: Item {
        id: tp
        property bool shown: false
        property var items: []

        function reload() {
            let data = [];
            try { data = JSON.parse(fs.trash_list()); } catch (e) { data = []; }
            tp.items = data;
        }

        anchors.fill: parent
        z: 105
        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        focus: shown
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        onShownChanged: if (shown) tp.forceActiveFocus()
        Keys.onEscapePressed: (e) => { tp.shown = false; e.accepted = true; }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.55)
            MouseArea { anchors.fill: parent; onClicked: tp.shown = false }
        }

        Rectangle {
            id: tpPanel
            anchors.centerIn: parent
            width: Math.min(640, win.width - 48)
            height: Math.min(520, win.height - 80)
            radius: 16
            color: theme.surface2
            border.width: 1
            border.color: theme.border
            scale: tp.shown ? 1 : 0.96
            Behavior on scale {
                NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.04 }
            }
            MouseArea { anchors.fill: parent }

            Text {
                id: tpTitle
                anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 18 }
                text: "Trash"
                color: theme.text
                font.family: theme.font
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Text {
                anchors { left: tpTitle.right; leftMargin: 10; verticalCenter: tpTitle.verticalCenter }
                text: tp.items.length + (tp.items.length === 1 ? " item" : " items")
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 11
            }
            Row {
                anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 14 }
                spacing: 8
                ActionButton {
                    visible: tp.items.length > 0
                    label: "Empty Trash"
                    danger: true
                    onActivated: win.trashEmpty()
                }
                ActionButton {
                    label: "Close"
                    onActivated: tp.shown = false
                }
            }

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 52 }
                height: 1
                color: theme.border
            }

            ListView {
                anchors {
                    left: parent.left; right: parent.right
                    top: parent.top; bottom: parent.bottom
                    topMargin: 58; bottomMargin: 12
                    leftMargin: 12; rightMargin: 12
                }
                clip: true
                model: tp.items
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: trow
                    required property var modelData

                    width: ListView.view.width
                    height: 48
                    radius: theme.radiusSmall
                    color: tMa.containsMouse ? theme.hover : "transparent"

                    Text {
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: trow.modelData.dir ? "\uf07b" : "\uf15b"
                        color: theme.textDim
                        font.family: theme.icon
                        font.pixelSize: 15
                    }
                    Column {
                        anchors {
                            left: parent.left; leftMargin: 40
                            right: tActions.left; rightMargin: 12
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 2
                        Text {
                            width: parent.width
                            text: trow.modelData.original !== "" ? trow.modelData.original : trow.modelData.name
                            color: theme.text
                            font.family: theme.font
                            font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                        Text {
                            text: win.fmtTime(trow.modelData.deleted)
                            color: theme.textDim
                            font.family: theme.font
                            font.pixelSize: 10
                        }
                    }
                    Row {
                        id: tActions
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        ActionButton {
                            label: "Restore"
                            opacity: trow.modelData.known ? 1 : 0.4
                            onActivated: if (trow.modelData.known) win.trashRestore([trow.modelData.name])
                        }
                        ActionButton {
                            label: "Delete"
                            danger: true
                            onActivated: win.trashDelete([trow.modelData.name])
                        }
                    }
                    MouseArea {
                        id: tMa
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: tp.items.length === 0
                text: "Trash is empty"
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 13
            }
        }
    }

    component Toast: Rectangle {
        id: tst
        property bool shown: false
        property string message: ""
        property string actionLabel: ""
        property var action: null

        function show(t) {
            tst.actionLabel = "";
            tst.action = null;
            tst.message = t;
            tst.shown = true;
            timer.restart();
        }
        function showUndo(t, cb) {
            tst.actionLabel = "Undo";
            tst.action = cb;
            tst.message = t;
            tst.shown = true;
            timer.restart();
        }

        z: 130
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(win.width - 40, content.implicitWidth + 44)
        height: 36
        radius: height / 2
        color: theme.elevated
        border.width: 1
        border.color: theme.border
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.96
        y: shown ? parent.height - height - 46 : parent.height - height - 26
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 1.04 } }

        Row {
            id: content
            anchors.centerIn: parent
            spacing: 14

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: tst.message
                color: theme.text
                font.family: theme.font
                font.pixelSize: 12
            }
            ActionButton {
                visible: tst.actionLabel.length > 0
                anchors.verticalCenter: parent.verticalCenter
                label: tst.actionLabel
                primary: true
                onActivated: {
                    const fn = tst.action;
                    tst.shown = false;
                    if (fn) fn();
                }
            }
        }
        Timer { id: timer; interval: 4200; repeat: false; onTriggered: tst.shown = false }
    }
}
