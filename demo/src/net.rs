//! Networking that works on desktop and in the browser.
//!
//! Both versions have the same interface, and neither ever blocks the game loop:
//!   - `post(url)` starts an HTTP POST. Poll it with `try_recv()`.
//!   - `Socket::connect(url)` opens a websocket. Poll it with `try_recv()`, write with `send()`.
//!   - `config()` reads the server URL and input delay.
//!
//! Desktop does the work on background threads. The browser version calls the JS
//! plugin in web/lockstep_net.js, which uses the browser's own WebSocket and XHR.

pub enum NetEvent {
    Open,
    Text(String),
    Closed(String),
}

pub struct Config {
    pub server: String,
    pub delay: u32,
    /// Play automatically with random moves (for testing).
    pub bot: bool,
}

/// http://host:port -> ws://host:port (and https -> wss).
pub fn ws_url(server: &str) -> String {
    if let Some(rest) = server.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = server.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        server.to_string()
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub use desktop::*;
#[cfg(target_arch = "wasm32")]
pub use web::*;

// ---------- Desktop ----------

#[cfg(not(target_arch = "wasm32"))]
mod desktop {
    use super::{Config, NetEvent};
    use std::io::{ErrorKind, Read, Write};
    use std::net::TcpStream;
    use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
    use std::time::Duration;
    use tungstenite::{stream::MaybeTlsStream, Message};

    /// Reads `--server URL`, `--delay N` and `--bot` from the command line.
    pub fn config() -> Config {
        let mut cfg = Config { server: "http://localhost:8080".into(), delay: 2, bot: false };
        let mut args = std::env::args().skip(1);
        while let Some(a) = args.next() {
            match a.as_str() {
                "--server" => cfg.server = args.next().unwrap_or(cfg.server),
                "--delay" => cfg.delay = args.next().and_then(|d| d.parse().ok()).unwrap_or(cfg.delay),
                "--bot" => cfg.bot = true,
                _ => eprintln!("unknown argument {a}. Use --server URL --delay N --bot"),
            }
        }
        cfg.server = cfg.server.trim_end_matches('/').to_string();
        cfg.delay = cfg.delay.max(1);
        cfg
    }

    pub struct HttpPost {
        rx: Receiver<Result<String, String>>,
    }

    impl HttpPost {
        pub fn try_recv(&mut self) -> Option<Result<String, String>> {
            self.rx.try_recv().ok()
        }
    }

    pub fn post(url: &str) -> HttpPost {
        let (tx, rx) = channel();
        let url = url.to_string();
        std::thread::spawn(move || {
            let _ = tx.send(post_blocking(&url));
        });
        HttpPost { rx }
    }

    /// A minimal HTTP/1.1 POST with an empty body. Enough for /match, and it saves pulling in an HTTP crate.
    fn post_blocking(url: &str) -> Result<String, String> {
        let rest = url
            .strip_prefix("http://")
            .ok_or("only http:// server URLs are supported on desktop")?;
        let (host, path) = match rest.find('/') {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, "/"),
        };
        let mut s = TcpStream::connect(host).map_err(|e| format!("connect to {host}: {e}"))?;
        s.set_read_timeout(Some(Duration::from_secs(5))).ok();
        write!(s, "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .map_err(|e| e.to_string())?;
        let mut resp = String::new();
        s.read_to_string(&mut resp).map_err(|e| e.to_string())?;
        let (head, body) = resp.split_once("\r\n\r\n").ok_or("bad HTTP response")?;
        let status = head.lines().next().unwrap_or("");
        if status.split(' ').nth(1) != Some("200") {
            return Err(format!("server replied {status}"));
        }
        Ok(body.to_string())
    }

    pub struct Socket {
        out: Sender<String>,
        events: Receiver<NetEvent>,
    }

    impl Socket {
        pub fn connect(url: &str) -> Socket {
            let (out, out_rx) = channel::<String>();
            let (ev, events) = channel();
            let url = url.to_string();
            std::thread::spawn(move || run(&url, out_rx, ev));
            Socket { out, events }
        }

        pub fn send(&self, text: &str) {
            let _ = self.out.send(text.to_string());
        }

        pub fn try_recv(&mut self) -> Option<NetEvent> {
            match self.events.try_recv() {
                Ok(e) => Some(e),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => Some(NetEvent::Closed("network thread stopped".into())),
            }
        }
    }

    /// The websocket thread. tungstenite's socket can't be split into reader and
    /// writer, so this one thread alternates: read with a short timeout, then send
    /// whatever the game has queued.
    fn run(url: &str, out: Receiver<String>, ev: Sender<NetEvent>) {
        let (mut ws, _) = match tungstenite::connect(url) {
            Ok(c) => c,
            Err(e) => {
                let _ = ev.send(NetEvent::Closed(format!("websocket connect failed: {e}")));
                return;
            }
        };
        if let MaybeTlsStream::Plain(s) = ws.get_mut() {
            s.set_read_timeout(Some(Duration::from_millis(5))).ok();
        }
        let _ = ev.send(NetEvent::Open);

        loop {
            match ws.read() {
                Ok(Message::Text(t)) => {
                    if ev.send(NetEvent::Text(t.to_string())).is_err() {
                        return; // game is gone
                    }
                }
                Ok(Message::Close(_)) => {
                    let _ = ev.send(NetEvent::Closed("server closed the connection".into()));
                    return;
                }
                Ok(_) => {} // ping/pong/binary
                Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(e) => {
                    let _ = ev.send(NetEvent::Closed(format!("connection lost: {e}")));
                    return;
                }
            }
            loop {
                match out.try_recv() {
                    Ok(text) => {
                        if let Err(e) = ws.send(Message::text(text)) {
                            let _ = ev.send(NetEvent::Closed(format!("send failed: {e}")));
                            return;
                        }
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        let _ = ws.close(None);
                        return;
                    }
                }
            }
        }
    }
}

// ---------- Browser (wasm32) ----------

#[cfg(target_arch = "wasm32")]
mod web {
    use super::{Config, NetEvent};
    use sapp_jsutils::JsObject;

    // Implemented in web/lockstep_net.js.
    extern "C" {
        fn lsn_ws_connect(url: JsObject);
        fn lsn_ws_send(text: JsObject);
        fn lsn_ws_try_recv() -> JsObject;
        fn lsn_ws_state() -> i32; // 0 connecting, 1 open, 2 closed
        fn lsn_ws_close_reason() -> JsObject;
        fn lsn_http_post(url: JsObject) -> i32;
        fn lsn_http_status(id: i32) -> i32; // 0 pending, 1 ok, 2 failed
        fn lsn_http_body(id: i32) -> JsObject;
        fn lsn_page_param(name: JsObject) -> JsObject;
        fn lsn_default_server() -> JsObject;
    }

    /// Lets the JS loader check that lockstep_net.js matches this build.
    #[no_mangle]
    pub extern "C" fn lockstep_net_crate_version() -> u32 {
        1
    }

    fn js_string(obj: JsObject) -> String {
        let mut s = String::new();
        if !obj.is_nil() && !obj.is_undefined() {
            obj.to_string(&mut s);
        }
        s
    }

    fn page_param(name: &str) -> String {
        js_string(unsafe { lsn_page_param(JsObject::string(name)) })
    }

    /// Reads ?server=URL&delay=N&bot=1 from the page URL. The default server is port 8080 on the page's host.
    pub fn config() -> Config {
        let mut server = page_param("server");
        if server.is_empty() {
            server = js_string(unsafe { lsn_default_server() });
        }
        let delay = page_param("delay").parse().unwrap_or(2u32).max(1);
        let bot = page_param("bot") == "1";
        Config { server: server.trim_end_matches('/').to_string(), delay, bot }
    }

    pub struct HttpPost {
        id: i32,
        done: bool,
    }

    impl HttpPost {
        pub fn try_recv(&mut self) -> Option<Result<String, String>> {
            if self.done {
                return None;
            }
            let status = unsafe { lsn_http_status(self.id) };
            if status == 0 {
                return None;
            }
            self.done = true;
            let body = js_string(unsafe { lsn_http_body(self.id) });
            Some(if status == 1 { Ok(body) } else { Err(body) })
        }
    }

    pub fn post(url: &str) -> HttpPost {
        HttpPost { id: unsafe { lsn_http_post(JsObject::string(url)) }, done: false }
    }

    /// The browser version supports one socket at a time, which is all the game needs.
    pub struct Socket {
        opened: bool,
        closed: bool,
    }

    impl Socket {
        pub fn connect(url: &str) -> Socket {
            unsafe { lsn_ws_connect(JsObject::string(url)) };
            Socket { opened: false, closed: false }
        }

        pub fn send(&self, text: &str) {
            unsafe { lsn_ws_send(JsObject::string(text)) };
        }

        pub fn try_recv(&mut self) -> Option<NetEvent> {
            let state = unsafe { lsn_ws_state() };
            if !self.opened && state >= 1 {
                self.opened = true;
                if state == 1 {
                    return Some(NetEvent::Open);
                }
            }
            // Deliver every queued message before reporting a close, so the server's
            // final "end" message (with its reason) isn't lost.
            let msg = unsafe { lsn_ws_try_recv() };
            if !msg.is_nil() {
                return Some(NetEvent::Text(js_string(msg)));
            }
            if state == 2 && !self.closed {
                self.closed = true;
                return Some(NetEvent::Closed(js_string(unsafe { lsn_ws_close_reason() })));
            }
            None
        }
    }
}
