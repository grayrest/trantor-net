//! TEST SCAFFOLDING (HC3 only, excluded from the published baseline): the
//! in-process HTTP server the basic-cli http-client / http-simple examples
//! expect on 127.0.0.1:9000 (basic-cli runs this as ci/rust_http_server; here
//! it is a host thread so the single example binary can start it). Binds
//! synchronously so a request right after start! connects, then serves on a
//! background thread. Endpoints mirror basic-cli's ci server.
mod signals;

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

const UTF8: &str = "Hello from the test server!";
const ROOT_JSON: &str = "{\"foo\":\"json-root\"}";
const HTML: &str = "<html><body>hi</body></html>";

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__testnet_host__start_test_server() {
    // Bind before returning so the example's first request has a listener.
    let l = match TcpListener::bind("127.0.0.1:9000") {
        Ok(l) => l,
        Err(_) => return, // already bound (e.g. two example runs) — reuse the running one
    };
    std::thread::spawn(move || {
        for c in l.incoming().flatten() {
            std::thread::spawn(move || serve(c));
        }
    });
}

fn ok_body(c: &mut TcpStream, body: &[u8]) {
    let _ = c.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).as_bytes());
    let _ = c.write_all(body);
}

fn serve(mut c: TcpStream) {
    let mut buf = Vec::new();
    let mut b = [0u8; 1024];
    // Read at least the headers.
    let header_end = loop {
        match c.read(&mut b) {
            Ok(0) | Err(_) => return,
            Ok(n) => {
                buf.extend_from_slice(&b[..n]);
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break i + 4;
                }
            }
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut parts = head.split_whitespace();
    let _method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");
    match path {
        "/utf8test" => ok_body(&mut c, UTF8.as_bytes()),
        "/" => ok_body(&mut c, ROOT_JSON.as_bytes()),
        "/html" => ok_body(&mut c, HTML.as_bytes()),
        // Non-JSON body -> Http.get! (JSON decode) fails with JsonErr.
        "/invalid-json" => ok_body(&mut c, b"this is not json"),
        // Invalid UTF-8 body -> Http.get_utf8! fails with BadBody.
        "/invalid-utf8" => ok_body(&mut c, &[0xff, 0xfe, 0xfd]),
        // Echo the request body back (basic-cli posts JSON here).
        "/echo-json" => {
            let clen: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length:").or_else(|| l.strip_prefix("content-length:")))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(0);
            let mut body = buf[header_end..].to_vec();
            while body.len() < clen {
                match c.read(&mut b) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => body.extend_from_slice(&b[..n]),
                }
            }
            ok_body(&mut c, &body);
        }
        _ => {
            let _ = c.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
    }
}
