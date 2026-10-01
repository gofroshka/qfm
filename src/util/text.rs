//! String and URI helpers.

/// Escape a string for embedding in a JSON string literal.
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Decode `%XX` escapes (and `+` left as-is, per URI path rules).
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(h) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(h);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Accept either a plain path or a `file://` URI and return a local path.
pub fn from_uri(s: &str) -> String {
    match s.strip_prefix("file://") {
        Some(r) => percent_decode(r),
        None => s.to_owned(),
    }
}

/// Percent-encode a filesystem path for embedding in a `file://` URI.
pub fn uri_encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build a `file://` URI for a local path.
pub fn file_uri(path: &str) -> String {
    format!("file://{}", uri_encode(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_json_control_chars() {
        assert_eq!(esc("a\"b\\c\nd"), "a\\\"b\\\\c\\nd");
        assert_eq!(esc("\u{1}"), "\\u0001");
    }

    #[test]
    fn uri_roundtrip() {
        let path = "/tmp/hello world/файл.txt";
        let uri = file_uri(path);
        assert!(uri.starts_with("file://"));
        assert_eq!(from_uri(&uri), path);
    }
}
