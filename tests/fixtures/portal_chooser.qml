import QtQuick
import "qrc:/qml" as Qfm

Qfm.Main {
    id: win

    function check(condition, message) {
        if (!condition) throw new Error(message);
    }

    function findItem(item, name) {
        if (item.objectName === name) return item;
        const children = item.children || [];
        for (let i = 0; i < children.length; i++) {
            const found = findItem(children[i], name);
            if (found) return found;
        }
        return null;
    }

    Component.onCompleted: console.warn("qfm-test-ready:chooser")

    onPickerChanged: {
        if (!win.picker) return;
        Qt.callLater(function() {
            try {
                const request = win.picker;
                const input = findItem(win.contentItem, "saveNameInput");
                const button = findItem(win.contentItem, "pickerAcceptButton");
                const confirmation = findItem(win.contentItem, "pickerConfirmation");
                const search = findItem(win.contentItem, "browserSearch");
                const startPath = win.curPath;
                const enter = request.title.indexOf("with Enter") >= 0;
                const searchEnter = request.title === "Choose folder from search";
                check(win.shown, "request did not show the dialog");
                check(win.title === request.title, "application title was lost");
                check(button.label === win.pickerLabel, "accept button label was lost");
                console.warn("qfm-test-request:" + JSON.stringify({
                    mode: request.mode, path: win.curPath, name: win.saveName, label: button.label
                }));

                if (request.mode === "save") {
                    check(win.pickerSave && !request.directory && !request.multiple, "SaveFile became an open/folder picker");
                    check(input.visible && input.text === win.saveName, "suggested filename is not visible");
                } else check(!input.visible, "filename input leaked to another mode");

                if (request.title === "Edit filename") {
                    input.text = "Бэкап базы.sql.gz";
                    input.textEdited();
                    check(win.saveName === input.text, "filename edits did not reach the request");
                    input.text = Qt.binding(function() { return win.saveName; });
                } else if (request.title === "Validate filename") {
                    const invalid = ["", ".", "..", "../escape.sql", "bad/name", "bad\nname", "bad\0name"];
                    for (let i = 0; i < invalid.length; i++) {
                        win.saveName = invalid[i];
                        check(!button.enabled, "invalid filename enabled Save");
                        win.pickerAccept();
                        check(win.picker === request, "invalid filename completed the request");
                    }
                    win.saveName = "valid.sql.gz";
                } else if (request.title === "Cancel saving") {
                    win.close();
                    check(!win.shown && !win.picker, "closing did not cancel SaveFile");
                    console.warn("qfm-test-finished:" + request.title);
                    return;
                } else if (request.title === "Open backups" || request.title === "Open backups with Enter") {
                    win.selectAll();
                    check(win.selectedCount === 3, "expected a folder and two files");
                } else if (request.title === "Choose backup folder") {
                    check(win.visibleEntries.every(e => e.dir), "folder picker displays files");
                } else if (request.title === "Open backup with Enter") {
                    check(win.activeEntry && win.activeEntry.dir, "expected a folder under the cursor");
                    win.activateCurrent();
                    check(win.picker === request && win.curPath === startPath, "Enter entered a folder in a file picker");
                    // Right-arrow navigation uses openIndex, left-arrow uses goUp.
                    const child = win.activeEntry.path;
                    win.openIndex(win.index);
                    check(win.curPath === child && win.picker === request, "folder navigation confirmed the request");
                    win.goUp();
                    check(win.curPath === startPath, "parent navigation failed");
                    win.index = win.visibleEntries.findIndex(e => !e.dir);
                    check(win.index >= 0, "backup file is missing");
                } else if (enter) {
                    check(win.activeEntry && win.activeEntry.dir, "expected a folder under the cursor");
                } else if (searchEnter) {
                    search.text = "subfolder";
                    check(win.activeEntry && win.activeEntry.name === "subfolder", "search did not highlight the folder");
                }

                if (searchEnter) search.accepted();
                else if (enter) win.activateCurrent();
                else win.pickerAccept();
                if (enter || searchEnter)
                    check(win.curPath === startPath, "Enter navigated instead of confirming the selection");
                if (request.title === "Replace backup" || request.title === "Decline replacement") {
                    check(win.picker === request && confirmation.shown, "overwrite was not confirmed");
                    if (request.title === "Replace backup") confirmation.confirmed();
                    else {
                        confirmation.cancelled();
                        check(win.picker === request && !confirmation.shown, "declining replacement closed the picker");
                        win.pickerCancel();
                    }
                } else if (request.title === "Directory collision") {
                    check(win.picker === request && !confirmation.shown, "save would replace a directory");
                    win.pickerCancel();
                }
                check(!win.picker && !win.shown, "request did not finish and hide the dialog");
                console.warn("qfm-test-finished:" + request.title);
            } catch (error) {
                console.warn("qfm-test-failure:" + error);
                win.pickerCancel();
            }
        });
    }
}
