//! Portal picker bridge: polls pending FileChooser requests and answers them.

use qmetaobject::prelude::*;

use crate::portal;
use crate::util::text::esc;

#[derive(QObject, Default)]
pub struct Portal {
    base: qt_base_class!(trait QObject),

    // Returns the next pending FileChooser request as JSON, or "".
    poll_portal: qt_method!(fn poll_portal(&self) -> QString {
        match portal::poll() {
            Some(p) => format!(
                "{{\"handle\":\"{}\",\"directory\":{},\"multiple\":{}}}",
                esc(&p.handle),
                p.directory,
                p.multiple
            )
            .into(),
            None => QString::from(""),
        }
    }),

    // Answer a request. `paths` is a newline separated list.
    portal_reply: qt_method!(fn portal_reply(&self, handle: QString, code: i32, paths: QString) {
        let list: Vec<String> = paths
            .to_string()
            .split('\n')
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        portal::reply(&handle.to_string(), code as u32, list);
    }),
}
