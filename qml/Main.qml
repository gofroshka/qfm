// qfm — minimalist file manager (plain Qt Quick, no Quickshell).
// This file owns application state and layout; reusable pieces live in
// components/ and pure helpers in Utils.js.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Qfm 1.0
import "components"
import "Utils.js" as Utils

Window {
    id: win

    width: 960
    height: 620
    minimumWidth: 520
    minimumHeight: 360
    visible: shown
    title: !win.picker ? "Files" : win.picker.title || (win.pickerSave ? "Save file"
           : win.pickerSaveFiles ? "Choose destination folder"
           : win.picker.directory ? "Choose folder" : "Choose file")
    color: Theme.bg
    flags: qfmPortalMode ? Qt.Dialog : Qt.Window
    modality: qfmPortalMode ? Qt.WindowModal : Qt.NonModal

    // Hidden when started as a portal backend until a request arrives.
    property bool shown: !qfmPortalMode
    // Active FileChooser request from the Rust portal backend, or null.
    property var picker: null
    property string saveName: ""
    readonly property bool pickerSave: !!win.picker && win.picker.mode === "save"
    readonly property bool pickerSaveFiles: !!win.picker && win.picker.mode === "saveFiles"
    readonly property string pickerLabel: {
        if (!win.picker) return "";
        if (win.picker.accept_label)
            return win.picker.accept_label.replace(/_([^_])/g, "$1").replace(/__/g, "_");
        if (win.pickerSave || win.pickerSaveFiles) return "Save";
        return win.picker.directory ? "Choose folder" : "Choose file";
    }
    readonly property string pickerHint: {
        if (!win.picker) return "";
        if (win.pickerSave) return "Enter saves the file. Use \u2192 / \u2190 to navigate folders.";
        if (win.pickerSaveFiles) return "Enter chooses the highlighted folder; " + win.pickerLabel
            + " uses the current folder (" + win.picker.files.length + " files).";
        return win.picker.directory ? "Enter chooses the highlighted folder. \u2192 opens it; \u2190 goes back."
                                   : "Enter selects files. \u2192 opens folders; \u2190 goes back.";
    }
    readonly property bool pickerCanAccept: {
        if (!win.picker || win.curPath === "") return false;
        if (win.pickerSave) return Utils.validFileName(win.saveName);
        if (win.pickerSaveFiles)
            return win.picker.files.length > 0 && win.picker.files.every(Utils.validFileName);
        if (win.picker.directory) return true;
        return win.pickerOpenPaths().length > 0;
    }

    onClosing: (close) => {
        if (qfmPortalMode) {
            close.accepted = false;
            win.pickerCancel();
        }
    }

    // Rust backend, registered from main.rs as the QML module `Qfm`.
    Fs { id: fs }
    Preview { id: preview }
    Clipboard { id: clipboard }
    Trash { id: trash }
    Portal { id: portal }

    // ---- state -------------------------------------------------------------
    property string curPath: ""
    property string curParent: ""
    property var entries: []
    property int index: 0
    property string status: ""
    property bool showHidden: false
    property string filter: ""
    // Preview side panel (photos / audio / metadata).
    property bool previewVisible: true
    // Multi-selection: path -> true. `anchor` is the shift-click origin.
    property var selected: ({})
    property int anchor: -1
    // Browser-style navigation history and type-ahead buffer.
    property var backStack: []
    property var forwardStack: []
    property string typeAhead: ""
    // Raw JSON of the last listing, used to detect external changes.
    property string listingRaw: ""
    // Number of items currently in the trash (for the toolbar badge).
    property int trashCount: 0
    // Pending operation launched from a prompt/confirm dialog.
    property var pendingOp: ({})

    // Rubber-band selection rectangle, in scene coordinates.
    property bool marqueeActive: false
    property real marqueeX0: 0
    property real marqueeY0: 0
    property real marqueeX1: 0
    property real marqueeY1: 0
    // Row index under the cursor (drives the hover highlight).
    property int hoverIndex: -1

    readonly property bool overlayOpen:
        menu.shown || prompt.shown || confirm.shown || trashPanel.shown || quickLook.shown

    readonly property var visibleEntries: {
        const q = win.filter.toLowerCase();
        const src = win.entries || [];
        const out = [];
        for (let i = 0; i < src.length; i++) {
            const e = src[i];
            if (!win.showHidden && e.hidden) continue;
            if (win.picker && win.picker.directory && !e.dir) continue;
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
        Utils.isImage(win.previewEntry) ? preview.file_uri(win.previewEntry.path) : ""
    readonly property string audioSource:
        Utils.isAudio(win.previewEntry) ? preview.file_uri(win.previewEntry.path) : ""
    readonly property string textSample:
        Utils.isText(win.previewEntry) ? preview.read_text(win.previewEntry.path, 8000) : ""

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
    // Load a directory into the view without touching history.
    function load(path, keepFilter) {
        const raw = fs.list_json(path);
        let data;
        try { data = JSON.parse(raw); } catch (e) { data = { error: "parse error" }; }
        if (data.error !== undefined) {
            win.status = data.error;
            win.toastMsg(data.error);
            return false;
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
        return true;
    }

    // Load a directory and record the move in the back/forward history.
    function navigate(path, keepFilter) {
        const from = win.curPath;
        if (!win.load(path, keepFilter)) return;
        if (from !== "" && from !== win.curPath) {
            win.backStack = win.backStack.concat([from]);
            win.forwardStack = [];
        }
    }

    function historyBack() {
        if (win.backStack.length === 0) return;
        const target = win.backStack[win.backStack.length - 1];
        const from = win.curPath;
        if (!win.load(target, false)) return;
        win.backStack = win.backStack.slice(0, -1);
        if (from !== "") win.forwardStack = win.forwardStack.concat([from]);
    }

    function historyForward() {
        if (win.forwardStack.length === 0) return;
        const target = win.forwardStack[win.forwardStack.length - 1];
        const from = win.curPath;
        if (!win.load(target, false)) return;
        win.forwardStack = win.forwardStack.slice(0, -1);
        if (from !== "") win.backStack = win.backStack.concat([from]);
    }

    function refresh(selectPath) {
        const sel = win.visibleEntries[win.index];
        const want = selectPath !== undefined ? selectPath : (sel ? sel.path : null);
        win.load(win.curPath, true);
        if (want) {
            const list = win.visibleEntries;
            for (let i = 0; i < list.length; i++) {
                if (list[i].path === want) { win.index = i; break; }
            }
        }
    }

    // Jump to the next entry matching the typed prefix.
    function typeAheadFind(ch) {
        win.typeAhead += ch;
        typeAheadTimer.restart();
        const q = win.typeAhead.toLowerCase();
        const list = win.visibleEntries;
        if (list.length === 0) return;
        for (let n = 1; n <= list.length; n++) {
            const i = (win.index + n) % list.length;
            if (list[i].name.toLowerCase().indexOf(q) === 0) { win.index = i; return; }
        }
        for (let i = 0; i < list.length; i++) {
            if (list[i].name.toLowerCase().indexOf(q) >= 0) { win.index = i; return; }
        }
    }

    function pageMove(dir) {
        const n = win.visibleEntries.length;
        if (n === 0) return;
        const rows = Math.max(1, Math.floor(list.height / 38));
        if (win.selectedCount > 0) win.selected = ({});
        win.index = Math.max(0, Math.min(n - 1, win.index + dir * rows));
    }

    // Space: toggle the current row's selection and step down.
    function toggleCurrent() {
        if (win.visibleEntries.length === 0) return;
        win.toggleSelect(win.index);
        if (win.index < win.visibleEntries.length - 1) win.index += 1;
    }

    // Space: open the large preview for the current entry.
    function openQuickLook() {
        if (!win.activeEntry) return;
        quickLook.open(win.activeEntry);
    }

    // Advance the quick look by `delta`, clamped to the listing.
    function quickLookStep(delta) {
        const list = win.visibleEntries;
        if (list.length === 0) return;
        let i = win.index + delta;
        if (i < 0) i = 0;
        if (i >= list.length) i = list.length - 1;
        win.index = i;
        quickLook.open(list[i]);
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
        const n = win.visibleEntries.length;
        if (n === 0) { win.index = 0; return; }
        if (win.selectedCount > 0) win.selected = ({});
        win.index = ((win.index + delta) % n + n) % n;
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

    // `file://` URIs to drag from a row: the whole selection when the row is
    // selected, otherwise just that entry.
    function dragUriList(index) {
        const list = win.visibleEntries;
        const e = list[index];
        if (!e) return [];
        if (win.isSelected(e.path) && win.selectedCount > 1)
            return win.selectedPaths().map(p => preview.file_uri(p));
        return [preview.file_uri(e.path)];
    }

    // Handle a drop onto a folder row / breadcrumb. Internal drags move the
    // entries, drags from other applications copy them.
    function handleDrop(target, uris, internal) {
        if (!target || !uris || uris.length === 0) return;
        const joined = uris.join("\n");
        const err = internal ? fs.move_uris(target, joined) : fs.copy_uris(target, joined);
        if (err) { win.toastMsg(err); return; }
        win.toastMsg(internal
                     ? (uris.length > 1 ? "Moved " + uris.length + " items" : "Moved")
                     : (uris.length > 1 ? "Copied " + uris.length + " items" : "Copied"));
        win.refresh();
    }

    // ---- rubber-band selection --------------------------------------------
    function marqueeBegin(x, y) {
        win.marqueeActive = true;
        win.marqueeX0 = x;
        win.marqueeY0 = y;
        win.marqueeX1 = x;
        win.marqueeY1 = y;
    }

    function marqueeUpdate(x, y) {
        win.marqueeX1 = x;
        win.marqueeY1 = y;
        win.applyMarquee();
    }

    function marqueeEnd() { win.marqueeActive = false; }

    // Select every visible entry intersecting the marquee rectangle.
    function applyMarquee() {
        const rx = Math.min(win.marqueeX0, win.marqueeX1);
        const ry = Math.min(win.marqueeY0, win.marqueeY1);
        const rw = Math.abs(win.marqueeX1 - win.marqueeX0);
        const rh = Math.abs(win.marqueeY1 - win.marqueeY0);
        const tl = list.mapFromItem(null, rx, ry);
        const br = list.mapFromItem(null, rx + rw, ry + rh);
        const cx1 = tl.x + list.contentX;
        const cy1 = tl.y + list.contentY;
        const cx2 = br.x + list.contentX;
        const cy2 = br.y + list.contentY;
        const next = {};
        const entries = win.visibleEntries;
        for (let i = 0; i < entries.length; i++) {
            const item = list.itemAtIndex(i);
            if (!item) continue;
            if (item.x < cx2 && item.x + item.width > cx1
                    && item.y < cy2 && item.y + item.height > cy1)
                next[entries[i].path] = true;
        }
        win.selected = next;
        win.anchor = -1;
    }

    // Mouse click on a row: plain replaces, Ctrl toggles, Shift extends.
    function handleRowClick(i, modifiers) {
        const entry = win.visibleEntries[i];
        if (win.pickerSave && entry && !entry.dir) win.saveName = entry.name;
        if (modifiers & Qt.ControlModifier) {
            win.index = i;
            win.toggleSelect(i);
        } else if (modifiers & Qt.ShiftModifier) {
            win.index = i;
            win.selectRange(i);
        } else {
            win.index = i;
            win.selectOnly(i);
        }
    }

    // ---- copy / paste ------------------------------------------------------
    function copySelection() {
        const paths = win.selectedPaths();
        if (paths.length === 0) return;
        clipboard.copy_to_clipboard(paths.join("\n"));
        win.toastMsg(paths.length === 1 ? "Copied" : ("Copied " + paths.length + " items"));
    }

    function copyPath() {
        if (!win.activeEntry) return;
        clipboard.copy_text(win.activeEntry.path);
        win.toastMsg("Path copied");
    }

    function pasteClipboard() {
        if (clipboard.clipboard_count() === 0) { win.toastMsg("Clipboard is empty"); return; }
        const err = clipboard.paste(win.curPath);
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Pasted");
        win.refresh();
    }

    function openIndex(i) {
        const list = win.visibleEntries;
        if (i < 0 || i >= list.length) return;
        const e = list[i];
        if (e.dir) { win.navigate(e.path); return; }
        if (win.picker) {
            win.index = i;
            if (win.pickerSave) win.saveName = e.name;
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
            selectPath = Utils.joinPath(win.curPath, name);
        } else if (op.type === "newfolder") {
            err = fs.create_dir(win.curPath, name);
            selectPath = Utils.joinPath(win.curPath, name);
        } else if (op.type === "rename") {
            err = fs.rename(op.path, name);
            const parent = op.path.substring(0, op.path.lastIndexOf("/"));
            selectPath = Utils.joinPath(parent, name);
        }
        if (err) { win.toastMsg(err); return; }
        win.toastMsg(op.type === "rename" ? "Renamed" : "Created");
        win.refresh(selectPath);
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
        for (let i = 0; i < paths.length; i++) names.push(Utils.baseName(paths[i]));
        win.startDelete(paths, names, permanent);
    }

    // Delete the current selection (or the entry under the cursor).
    function deleteCurrent(permanent) {
        if (win.selectedCount > 0) win.deleteSelection(permanent);
        else win.deleteIndex(win.index, permanent);
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
        confirm.glyph = permanent ? "\uf2ed" : "\uf1f8";
        confirm.danger = permanent;
        confirm.shown = true;
    }

    function confirmAccept() {
        const op = win.pendingOp || {};
        if (op.type === "overwrite") {
            if (win.picker && win.picker.handle === op.handle) win.pickerAnswer(0, [op.path]);
            return;
        }
        if (op.type !== "delete") return;
        if (op.permanent) {
            const err = fs.delete_permanent(op.paths.join("\n"));
            if (err) { win.toastMsg(err); return; }
            win.toastMsg(op.paths.length > 1 ? "Deleted " + op.paths.length + " items" : "Deleted");
            win.refresh();
            return;
        }
        const res = trash.trash(op.paths.join("\n"));
        if (res === "error:EXDEV") {
            win.startDelete(op.paths, op.names, true);
            win.toastMsg("This volume has no trash");
            return;
        }
        if (res.indexOf("error:") === 0) { win.toastMsg(res.slice(6)); return; }
        const names = res;
        win.refresh();
        win.trashCount = trash.trash_count();
        win.toastUndo(names.split("\n").length > 1
                      ? ("Trashed " + names.split("\n").length + " items") : "Trashed",
                      names);
    }

    // Undo the most recent trash operation.
    function undoTrash(names) {
        if (!names) return;
        const err = trash.trash_restore(names);
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Restored");
        win.refresh();
        win.trashCount = trash.trash_count();
    }

    // ---- trash panel -------------------------------------------------------
    function openTrash() {
        trashPanel.reload();
        trashPanel.shown = true;
    }

    function trashRestore(names) {
        const err = trash.trash_restore(names.join("\n"));
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Restored");
        win.refresh();
        win.trashCount = trash.trash_count();
        trashPanel.reload();
    }

    function trashDelete(names) {
        const err = trash.trash_delete(names.join("\n"));
        if (err) { win.toastMsg(err); return; }
        win.toastMsg("Deleted");
        win.trashCount = trash.trash_count();
        trashPanel.reload();
    }

    function trashEmpty() {
        const err = trash.trash_empty();
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
            items.push({ label: "Preview", glyph: "\uf06e", act: "preview", key: "Space" });
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
        if (clipboard.clipboard_count() > 0)
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
        else if (act === "preview") win.openQuickLook();
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

    // ---- portal picker -----------------------------------------------------
    function pollPortal() {
        if (!qfmPortalMode || win.picker) return;
        const raw = portal.poll_portal();
        if (!raw) return;
        let req;
        try { req = JSON.parse(raw); } catch (e) { return; }
        win.picker = req;
        win.saveName = req.current_name || "";
        win.backStack = [];
        win.forwardStack = [];
        win.typeAhead = "";
        const fallback = (qfmInitialPath && qfmInitialPath !== "") ? qfmInitialPath : fs.home();
        if (!win.load(req.current_folder || fallback, false)) win.load(fs.home(), false);
        win.shown = true;
        win.raise();
        win.requestActivate();
        if (win.pickerSave) {
            saveInput.forceActiveFocus();
            saveInput.selectAll();
        } else root.forceActiveFocus();
    }

    function pickerOpenPaths() {
        if (!win.picker) return [];
        const paths = win.selectedPaths();
        const entries = win.visibleEntries;
        const out = [];
        for (let i = 0; i < entries.length; i++) {
            const e = entries[i];
            if (e.dir === win.picker.directory && paths.indexOf(e.path) >= 0) out.push(e.path);
        }
        return win.picker.multiple ? out : out.slice(0, 1);
    }

    // SaveFiles returns one destination per supplied name, preserving order.
    // Avoid both existing entries and collisions within this request.
    function pickerSaveFilesPaths(folder) {
        let data;
        try { data = JSON.parse(fs.list_json(folder)); } catch (e) { return []; }
        if (data.error !== undefined) { win.toastMsg(data.error); return []; }
        const used = Object.create(null);
        for (let i = 0; i < data.entries.length; i++) used[data.entries[i].name] = true;
        return win.picker.files.map(function(name) {
            const dot = name.lastIndexOf(".");
            const base = dot > 0 ? name.slice(0, dot) : name;
            const ext = dot > 0 ? name.slice(dot) : "";
            let candidate = name;
            for (let n = 2; used[candidate]; n++) candidate = base + " " + n + ext;
            used[candidate] = true;
            return Utils.joinPath(folder, candidate);
        });
    }

    function pickerAccept(useActiveFolder) {
        if (!win.picker || win.overlayOpen || !win.pickerCanAccept) return;
        const folder = useActiveFolder && win.activeEntry && win.activeEntry.dir
            ? win.activeEntry.path : win.curPath;
        if (win.pickerSave) {
            const path = Utils.joinPath(win.curPath, win.saveName);
            const kind = fs.path_kind(path);
            if (kind === "directory") { win.toastMsg("A folder already has this name"); return; }
            if (kind.indexOf("error:") === 0) { win.toastMsg(kind.slice(6)); return; }
            if (kind === "file") {
                win.pendingOp = { type: "overwrite", path: path, handle: win.picker.handle };
                confirm.title = "Replace existing file?";
                confirm.message = "\u201c" + win.saveName + "\u201d already exists. Saving will replace it.";
                confirm.confirmLabel = "Replace";
                confirm.glyph = "\uf0c7";
                confirm.danger = true;
                confirm.shown = true;
                return;
            }
            win.pickerAnswer(0, [path]);
        } else if (win.pickerSaveFiles) {
            const paths = win.pickerSaveFilesPaths(folder);
            if (paths.length > 0) win.pickerAnswer(0, paths);
        } else if (win.picker.directory) {
            const paths = win.picker.multiple && win.selectedCount > 0 ? win.pickerOpenPaths() : [];
            win.pickerAnswer(0, paths.length > 0 ? paths : [folder]);
        } else {
            const paths = win.pickerOpenPaths();
            if (paths.length > 0) win.pickerAnswer(0, paths);
        }
    }

    function activateCurrent() {
        if (win.picker) win.pickerAccept(true);
        else win.openIndex(win.index);
    }

    function pickerCancel() { win.pickerAnswer(1, []); }

    function pickerAnswer(code, paths) {
        if (win.picker && win.picker.handle) portal.portal_reply(win.picker.handle, code, paths.join("\n"));
        menu.shown = false;
        prompt.shown = false;
        confirm.shown = false;
        trashPanel.shown = false;
        quickLook.shown = false;
        win.pendingOp = ({});
        win.saveName = "";
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
            running: qfmPortalMode && win.picker === null
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
                win.trashCount = trash.trash_count();
            }
        }

        // Reset the type-ahead prefix after a short pause.
        Timer {
            id: typeAheadTimer
            interval: 800
            repeat: false
            onTriggered: win.typeAhead = ""
        }

        // Show the calling application's title and the purpose of the picker.
        Item {
            id: pickerInfo
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: win.picker ? 52 : 0
            visible: win.picker !== null

            Text {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; topMargin: 8 }
                text: win.title
                color: Theme.text
                font.family: Theme.font
                font.pixelSize: 13
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Text {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14; bottomMargin: 6 }
                text: win.pickerHint
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        // ---- top bar -------------------------------------------------------
        Item {
            id: top
            anchors { left: parent.left; right: parent.right; top: pickerInfo.bottom }
            height: 52

            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Theme.border
            }

            Row {
                id: navButtons
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 6

                BarButton { glyph: "\uf060"; onActivated: win.historyBack() }
                BarButton { glyph: "\uf061"; onActivated: win.historyForward() }
                BarButton { glyph: "\uf062"; onActivated: win.goUp() }
                BarButton { glyph: "\uf015"; onActivated: win.goHome() }
                BarButton { glyph: "\uf021"; onActivated: win.refresh() }
            }

            Breadcrumbs {
                id: crumbs
                anchors {
                    left: navButtons.right; leftMargin: 10
                    right: tools.left; rightMargin: 12
                    verticalCenter: parent.verticalCenter
                }
                model: win.crumbs
                currentPath: win.curPath
                onNavigate: (path) => win.navigate(path)
                onDropRequested: (path, uris, internal) => win.handleDrop(path, uris, internal)
            }

            Row {
                id: tools
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 6

                SearchField {
                    id: search
                    objectName: "browserSearch"
                    width: 180
                    onTextChanged: win.filter = search.text
                    onAccepted: win.activateCurrent()
                    onMoveUp: win.move(-1)
                    onMoveDown: win.move(1)
                    onEscaped: root.forceActiveFocus()
                }
                BarButton {
                    glyph: win.showHidden ? "\uf06e" : "\uf070"
                    active: win.showHidden
                    onActivated: win.showHidden = !win.showHidden
                }
                BarButton {
                    glyph: "\uf03e"
                    active: win.previewVisible
                    onActivated: win.previewVisible = !win.previewVisible
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
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 10
                font.letterSpacing: 0.6
            }
            Text {
                anchors { right: parent.right; rightMargin: 14 + 130 + 12; verticalCenter: parent.verticalCenter }
                width: 90
                horizontalAlignment: Text.AlignRight
                text: "Size"
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 10
                font.letterSpacing: 0.6
            }
            Text {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                width: 130
                horizontalAlignment: Text.AlignRight
                text: "Modified"
                color: Theme.textDim
                font.family: Theme.font
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
                const p = listBackground.mapToItem(null, mouse.x, mouse.y);
                win.openMenu(-1, p.x, p.y);
            }
        }

        ListView {
            id: list
            anchors {
                left: parent.left; right: previewPanel.left
                top: header.bottom; bottom: saveField.top
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
                radius: Theme.radiusSmall

                Rectangle {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    anchors.leftMargin: 2
                    width: 3
                    height: Math.max(0, parent.height - 14)
                    radius: 1.5
                    color: Theme.accent
                }
            }

            delegate: FileRow {
                selected: win.isSelected(modelData.path)
                hovered: index === win.hoverIndex
                onRowContext: (index, x, y) => win.openMenu(index, x, y)
                onDropRequested: (target, uris, internal) => win.handleDrop(target, uris, internal)
            }
        }

        // ---- list mouse overlay --------------------------------------------
        // A single transparent surface above the list that decides, on press,
        // whether the gesture is a file drag (selected row), a rubber-band
        // selection (empty area or unselected row) or a plain click.
        Item {
            id: listDragProxy
            width: 1
            height: 1
            x: -1000
            y: -1000
        }

        MouseArea {
            id: listMouse
            anchors.fill: list
            z: 55
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
            preventStealing: true

            property int pressIndex: -1
            property real pressX: 0
            property real pressY: 0
            property bool banding: false
            property bool moved: false
            // Pressed on a selected row -> file drag is allowed.
            property bool armed: false
            property var grab: null
            property url pixmap: ""

            drag.target: listMouse.armed ? listDragProxy : null
            drag.threshold: 8

            Drag.active: listMouse.drag.active
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
            Drag.proposedAction: Qt.CopyAction
            Drag.hotSpot.x: 12
            Drag.hotSpot.y: Theme.rowHeight / 2
            Drag.imageSource: listMouse.pixmap
            Drag.imageSourceSize: Qt.size(list.width, Theme.rowHeight)
            Drag.mimeData: ({
                "text/uri-list": listMouse.pressIndex >= 0
                                 ? win.dragUriList(listMouse.pressIndex).join("\r\n") : "",
                "application/x-qfm-internal": "1"
            })

            function indexAt(mx, my) {
                return list.indexAt(mx + list.contentX, my + list.contentY);
            }

            function selectedAt(i) {
                const e = win.visibleEntries[i];
                return !!e && win.isSelected(e.path);
            }

            onEntered: win.hoverIndex = indexAt(mouseX, mouseY)
            onExited: win.hoverIndex = -1

            onPressed: mouse => {
                root.forceActiveFocus();
                pressX = mouse.x;
                pressY = mouse.y;
                banding = false;
                moved = false;
                pressIndex = indexAt(mouse.x, mouse.y);
                win.hoverIndex = pressIndex;
                armed = pressIndex >= 0 && selectedAt(pressIndex);
                if (armed) {
                    const item = list.itemAtIndex(pressIndex);
                    if (item)
                        item.grabToImage(function(result) {
                            listMouse.grab = result;
                            listMouse.pixmap = result.url;
                        });
                }
            }

            onPositionChanged: mouse => {
                win.hoverIndex = indexAt(mouse.x, mouse.y);
                if (!pressed)
                    return;
                if (!moved && (Math.abs(mouse.x - pressX) > 6 || Math.abs(mouse.y - pressY) > 6))
                    moved = true;
                if (listMouse.armed || !moved)
                    return;
                if (!banding) {
                    banding = true;
                    const p0 = listMouse.mapToItem(null, pressX, pressY);
                    win.marqueeBegin(p0.x, p0.y);
                }
                const p = listMouse.mapToItem(null, mouse.x, mouse.y);
                win.marqueeUpdate(p.x, p.y);
            }

            onReleased: mouse => {
                if (banding) {
                    win.marqueeEnd();
                } else if (!moved) {
                    if (pressIndex >= 0)
                        win.handleRowClick(pressIndex, mouse.modifiers);
                    else if (win.selectedCount > 0)
                        win.selected = ({});
                }
                banding = false;
                moved = false;
                armed = false;
                pressIndex = -1;
            }

            onCanceled: {
                if (banding)
                    win.marqueeEnd();
                banding = false;
                moved = false;
                armed = false;
                pressIndex = -1;
            }

            onDoubleClicked: mouse => {
                const i = indexAt(mouse.x, mouse.y);
                if (i >= 0)
                    win.openIndex(i);
            }

            // The overlay sits above the ListView, so wheel scrolling must be
            // forwarded to it manually.
            WheelHandler {
                onWheel: event => {
                    const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y;
                    const max = Math.max(0, list.contentHeight - list.height);
                    list.contentY = Math.max(0, Math.min(max, list.contentY - delta));
                    event.accepted = true;
                }
            }
        }

        EmptyState {
            anchors.centerIn: list
            filtered: win.filter.length > 0
            visible: win.visibleEntries.length === 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        // ---- rubber-band rectangle -----------------------------------------
        Rectangle {
            id: marqueeRect
            visible: win.marqueeActive
            z: 60
            x: Math.min(win.marqueeX0, win.marqueeX1)
            y: Math.min(win.marqueeY0, win.marqueeY1)
            width: Math.abs(win.marqueeX1 - win.marqueeX0)
            height: Math.abs(win.marqueeY1 - win.marqueeY0)
            color: Qt.rgba(1, 1, 1, 0.08)
            border.width: 1
            border.color: Theme.accent
            radius: 2
        }

        // ---- preview panel -------------------------------------------------
        PreviewPanel {
            id: previewPanel
            anchors {
                top: top.bottom; bottom: saveField.top
                right: parent.right; rightMargin: 8
                topMargin: 6; bottomMargin: 8
            }
            shown: win.previewVisible
            entry: win.previewEntry
            imageSource: win.imageSource
            audioSource: win.audioSource
            textSample: win.textSample
        }

        // ---- scrollbar -----------------------------------------------------
        Rectangle {
            id: scrollbar
            readonly property real viewport: Math.max(1, list.height - list.topMargin - list.bottomMargin)
            readonly property real overflow: Math.max(0, list.contentHeight - viewport)

            visible: overflow > 1
            width: 6
            radius: 3
            color: Theme.track
            x: list.x + list.width - width - 3
            height: overflow > 1 ? Math.max(28, viewport * viewport / Math.max(1, list.contentHeight)) : 0
            y: list.y + list.topMargin + (overflow > 1
                ? (Math.max(0, Math.min(overflow, list.contentY)) / overflow) * (viewport - height)
                : 0)
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        // A save request chooses a new path; it does not create an empty file.
        Item {
            id: saveField
            anchors { left: parent.left; right: parent.right; bottom: status.top }
            height: win.pickerSave ? 48 : 0
            visible: win.pickerSave

            Text {
                id: saveLabel
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                text: "File name"
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 12
            }
            Rectangle {
                anchors {
                    left: saveLabel.right; leftMargin: 12
                    right: parent.right; rightMargin: 14
                    verticalCenter: parent.verticalCenter
                }
                height: 34
                radius: Theme.radiusSmall
                color: Theme.surface2
                border.width: 1
                border.color: saveInput.activeFocus ? Theme.accent : Theme.border

                TextInput {
                    id: saveInput
                    objectName: "saveNameInput"
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                    verticalAlignment: TextInput.AlignVCenter
                    text: win.saveName
                    onTextEdited: win.saveName = text
                    color: Theme.text
                    font.family: Theme.font
                    font.pixelSize: 12
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.bg
                    clip: true
                    onAccepted: win.pickerAccept()
                    Keys.onEscapePressed: (e) => { win.pickerCancel(); e.accepted = true; }
                }
                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    visible: saveInput.text.length === 0
                    text: "Enter a file name"
                    color: Theme.textDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }
            }
        }

        // ---- status bar ----------------------------------------------------
        Item {
            id: status
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: win.picker ? 40 : 32

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1
                color: Theme.border
            }
            Text {
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                text: win.selectedCount > 0
                      ? (win.selectedCount + " selected")
                      : (win.visibleEntries.length + " / " + win.entries.length)
                color: win.selectedCount > 0 ? Theme.text : Theme.textDim
                font.family: Theme.font
                font.pixelSize: 11
            }
            Text {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                visible: win.picker === null
                text: win.status
                color: Theme.textDim
                font.family: Theme.font
                font.pixelSize: 11
            }

            Row {
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 8
                visible: win.picker !== null

                ActionButton { label: "Cancel"; onActivated: win.pickerCancel() }
                ActionButton {
                    objectName: "pickerAcceptButton"
                    label: win.pickerLabel
                    enabled: win.pickerCanAccept
                    opacity: enabled ? 1 : 0.45
                    primary: true
                    onActivated: win.pickerAccept()
                }
            }
        }

        // ---- keyboard ------------------------------------------------------
        Keys.onUpPressed: (e) => { if (!win.overlayOpen) { win.move(-1); e.accepted = true; } }
        Keys.onDownPressed: (e) => { if (!win.overlayOpen) { win.move(1); e.accepted = true; } }
        Keys.onReturnPressed: (e) => { if (!win.overlayOpen) { win.activateCurrent(); e.accepted = true; } }
        Keys.onEnterPressed: (e) => { if (!win.overlayOpen) { win.activateCurrent(); e.accepted = true; } }
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
            const alt = e.modifiers & Qt.AltModifier;
            if (alt && e.key === Qt.Key_Left) {
                win.historyBack();
                e.accepted = true;
            } else if (alt && e.key === Qt.Key_Right) {
                win.historyForward();
                e.accepted = true;
            } else if (alt && e.key === Qt.Key_Up) {
                win.goUp();
                e.accepted = true;
            } else if (e.key === Qt.Key_Backspace) {
                win.deleteCurrent(!!shift);
                e.accepted = true;
            } else if (e.key === Qt.Key_Left) {
                win.goUp();
                e.accepted = true;
            } else if (e.key === Qt.Key_Right) {
                win.openIndex(win.index);
                e.accepted = true;
            } else if (e.key === Qt.Key_PageUp) {
                win.pageMove(-1);
                e.accepted = true;
            } else if (e.key === Qt.Key_PageDown) {
                win.pageMove(1);
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_Space) {
                win.toggleCurrent();
                e.accepted = true;
            } else if (e.key === Qt.Key_Space) {
                win.openQuickLook();
                e.accepted = true;
            } else if (ctrl && shift && e.key === Qt.Key_N) {
                win.openNewFolder();
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_N) {
                win.openNewFile();
                e.accepted = true;
            } else if (e.key === Qt.Key_F2) {
                win.startRename(win.index);
                e.accepted = true;
            } else if (e.key === Qt.Key_Delete) {
                win.deleteCurrent(!!shift);
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
                win.previewVisible = !win.previewVisible;
                e.accepted = true;
            } else if (ctrl && e.key === Qt.Key_F) {
                search.focusInput();
                e.accepted = true;
            } else if (!ctrl && !alt && e.text.length === 1 && e.text >= " ") {
                win.typeAheadFind(e.text);
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
            objectName: "pickerConfirmation"
            onConfirmed: { confirm.shown = false; root.forceActiveFocus(); win.confirmAccept(); }
            onCancelled: { confirm.shown = false; root.forceActiveFocus(); }
        }

        TrashPanel {
            id: trashPanel
            loadList: function() { return trash.trash_list(); }
            onRestoreRequested: (names) => win.trashRestore(names)
            onDeleteRequested: (names) => win.trashDelete(names)
            onEmptyRequested: win.trashEmpty()
        }

        QuickLook {
            id: quickLook
            index: win.index
            total: win.visibleEntries.length
            fileUri: function(path) { return preview.file_uri(path); }
            readText: function(path, max) { return preview.read_text(path, max); }
            onStepRequested: (delta) => win.quickLookStep(delta)
            onClosed: root.forceActiveFocus()
        }

        Toast { id: toast }

        // ---- resize handles -------------------------------------------------
        ResizeHandle {
            edges: Qt.TopEdge; height: 6; z: 80
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 12; rightMargin: 12 }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.BottomEdge; height: 6; z: 80
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 12; rightMargin: 12 }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.LeftEdge; width: 6; z: 80
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left; topMargin: 12; bottomMargin: 12 }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.RightEdge; width: 6; z: 80
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right; topMargin: 12; bottomMargin: 12 }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.TopEdge | Qt.LeftEdge; width: 12; height: 12; z: 81
            anchors { top: parent.top; left: parent.left }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.TopEdge | Qt.RightEdge; width: 12; height: 12; z: 81
            anchors { top: parent.top; right: parent.right }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.BottomEdge | Qt.LeftEdge; width: 12; height: 12; z: 81
            anchors { bottom: parent.bottom; left: parent.left }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
        ResizeHandle {
            edges: Qt.BottomEdge | Qt.RightEdge; width: 12; height: 12; z: 81
            anchors { bottom: parent.bottom; right: parent.right }
            onResizeRequested: (edges) => win.startSystemResize(edges)
        }
    }
}
