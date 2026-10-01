.pragma library

// Pure formatting / file-kind helpers shared by the QML views. Kept free of
// QtObject state so any component can use it without wiring.

function isImage(e) {
    return !!e && !e.dir
        && /\.(png|jpe?g|gif|webp|svg|bmp|avif|ico|tiff?)$/i.test(e.name);
}

function isAudio(e) {
    return !!e && !e.dir
        && /\.(mp3|flac|wav|ogg|oga|m4a|opus|aac|wma|alac)$/i.test(e.name);
}

function isVideo(e) {
    return !!e && !e.dir
        && /\.(mp4|mkv|webm|mov|avi|m4v|ogv)$/i.test(e.name);
}

function isText(e) {
    if (!e || e.dir) return false;
    return /\.(txt|md|markdown|rst|log|conf|cfg|ini|toml|yaml|yml|json|xml|csv|tsv|sh|bash|zsh|fish|rs|py|js|mjs|cjs|ts|tsx|jsx|qml|c|h|cc|cpp|hpp|go|java|kt|lua|rb|php|sql|html|htm|css|scss|nix|kdl|desktop|service|diff|patch|env|gitignore|gitattributes|editorconfig)$/i.test(e.name)
        || /^(README|LICENSE|COPYING|Makefile|Dockerfile|flake\.lock|Cargo\.lock|CMakeLists\.txt|\.gitignore|\.bashrc|\.profile)/i.test(e.name);
}

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
    else if (isImage(e)) parts.push("Image");
    else if (isAudio(e)) parts.push("Audio");
    else if (isVideo(e)) parts.push("Video");
    else parts.push("File");
    if (!e.dir && !e.link) parts.push(fmtSize(e));
    parts.push(fmtTime(e.mtime));
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

// Join a directory and a child name into an absolute path.
function joinPath(dir, name) {
    if (!dir || dir === "/") return "/" + name;
    return dir.replace(/\/+$/, "") + "/" + name;
}

// Final component of a path.
function baseName(path) {
    return path.split("/").pop();
}
