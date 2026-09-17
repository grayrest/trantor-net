//! roc:sync-http host over ureq (H1): one blocking outgoing request whose
//! response BODY is a streaming roc:sync-io InputStream (H5). One process-wide
//! Agent (H8) gives keep-alive + pooling; chunked decode is built in and
//! gzip/brotli decompress transparently (H2). `send!` returns status +
//! NUL-joined multi-value headers (H10) as soon as the final headers arrive;
//! the body is read lazily through the InputStream. Method u8 is basic-cli's
//! InternalHttp.to_host_method encoding (CONNECT=0 … TRACE=9), `Unknown` told
//! apart by a non-empty method_ext (H15).
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
use std::sync::OnceLock;
use std::time::Duration;
use ureq::{http, Agent};

const METHODS: [&str; 10] = ["CONNECT", "DELETE", "QUERY", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"];
type ErrTag = BadBodyOrNetworkErrorOrOtherOrTimeoutTag;
type Err = BadBodyOrNetworkErrorOrOtherOrTimeout;
type Ok = AnonStructD04f4a420a7c0c28;
type BodyErr = EndedEarlyOrIoOrTimedOut;
type BodyErrTag = EndedEarlyOrIoOrTimedOutTag;
type BodyErrPayload = EndedEarlyOrIoOrTimedOutPayload;

/// The one shared Agent (H8): built once, reused for every send! so connections
/// pool and (in HC4) TLS initializes once. Redirect policy from the env (H16):
/// TRANTOR_HTTP_MAX_REDIRECTS (default 10), and hitting the ceiling returns the
/// last response rather than erroring (browser-like). Non-2xx is success (H3).
fn agent() -> &'static Agent {
    static A: OnceLock<Agent> = OnceLock::new();
    A.get_or_init(|| {
        let max_redirects: u32 = std::env::var("TRANTOR_HTTP_MAX_REDIRECTS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(10);
        let builder = Agent::config_builder()
            .http_status_as_error(false)
            .max_redirects(max_redirects)
            .max_redirects_will_error(false);
        #[cfg(feature = "tls")]
        let builder = builder.tls_config(tls::config());
        let config = builder.build();
        Agent::new_with_config(config)
    })
}

/// TLS trust (H13, `tls` feature only). ureq supplies the ring CryptoProvider
/// itself, so this only chooses the root store: webpki-roots by default, and —
/// when TRANTOR_HTTP_EXTRA_CA points at a PEM — webpki-roots **plus** those
/// certs (additive: public CAs stay trusted; the extra CA is the local-dev /
/// corporate / test hook). One env var, one PEM file, no replace-the-store mode.
#[cfg(feature = "tls")]
mod tls {
    use ureq::tls::{Certificate, RootCerts, TlsConfig};

    pub fn config() -> TlsConfig {
        let root_certs = match std::env::var_os("TRANTOR_HTTP_EXTRA_CA") {
            None => RootCerts::WebPki,
            Some(path) => match std::fs::read(&path) {
                Ok(pem) => {
                    // webpki roots (full DERs) + the extra CA's certs, leaked to
                    // 'static (built once behind the process-wide Agent OnceLock).
                    let mut certs: Vec<Certificate<'static>> = webpki_root_certs::TLS_SERVER_ROOT_CERTS
                        .iter()
                        .map(|c| Certificate::from_der(c.as_ref()))
                        .collect();
                    let extra: Vec<_> = rustls_pemfile::certs(&mut &pem[..]).flatten().collect();
                    let extra: &'static [_] = Box::leak(extra.into_boxed_slice());
                    certs.extend(extra.iter().map(|c| Certificate::from_der(c.as_ref())));
                    RootCerts::Specific(std::sync::Arc::new(certs))
                }
                Err(_) => RootCerts::WebPki, // unreadable extra CA -> public roots only
            },
        };
        TlsConfig::builder().root_certs(root_certs).build()
    }
}

fn err(tag: ErrTag, msg: &str) -> HttpHostSendResult {
    let e = if let ErrTag::Other = tag {
        Err {
            payload: BadBodyOrNetworkErrorOrOtherOrTimeoutPayload {
                other: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(msg.as_bytes(), abi::host()) }),
            },
            tag,
        }
    } else {
        Err { payload: unsafe { core::mem::zeroed() }, tag }
    };
    HttpHostSendResult { payload: HttpHostSendResultPayload { err: ManuallyDrop::new(e) }, tag: HttpHostSendResultTag::Err }
}

/// A request's write to a connection the server has closed raises SIGPIPE, and
/// the app's `main` is exported to C, so nothing ignores it and the process
/// dies. macOS std sets `SO_NOSIGPIPE` on every socket it makes; ureq's
/// sockets are std's, so only Linux needs this (D-S2-51).
#[cfg(target_vendor = "apple")]
fn without_sigpipe<T>(call: impl FnOnce() -> T) -> T {
    call()
}

/// Linux sends a write's SIGPIPE to the writing thread: block it for the call,
/// and take any this call raised before restoring the mask — whatever the call
/// returned, since a partial write raises it too. One already pending is not
/// this call's, and is left for the mask to deliver (trantor-process's
/// `without_sigpipe`, the same sequence).
#[cfg(not(target_vendor = "apple"))]
fn without_sigpipe<T>(call: impl FnOnce() -> T) -> T {
    fn pending() -> bool {
        // SAFETY: sigpending fills a stack-local set.
        unsafe {
            let mut set: libc::sigset_t = core::mem::zeroed();
            libc::sigpending(&mut set);
            libc::sigismember(&set, libc::SIGPIPE) == 1
        }
    }
    // SAFETY: signal-mask calls on stack-local sets for the calling thread only.
    unsafe {
        let mut sigpipe: libc::sigset_t = core::mem::zeroed();
        libc::sigemptyset(&mut sigpipe);
        libc::sigaddset(&mut sigpipe, libc::SIGPIPE);
        let mut previous: libc::sigset_t = core::mem::zeroed();
        libc::pthread_sigmask(libc::SIG_BLOCK, &sigpipe, &mut previous);
        let was_blocked = libc::sigismember(&previous, libc::SIGPIPE) == 1;
        let pending_before = pending();
        let result = call();
        if !was_blocked && !pending_before && pending() {
            let no_wait = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            libc::sigtimedwait(&sigpipe, core::ptr::null_mut(), &no_wait);
        }
        libc::pthread_sigmask(libc::SIG_SETMASK, &previous, core::ptr::null_mut());
        result
    }
}

/// Map a ureq transport error onto the 4-variant twin (H3). `send!` only reports
/// connect/header-phase failures; body-phase failures surface as StreamErr on a
/// later read (H15), so decompression/truncation are not mapped here.
fn send_err(e: &ureq::Error) -> HttpHostSendResult {
    use ureq::Error as E;
    match e {
        E::Timeout(_) => err(ErrTag::Timeout, ""),
        E::Io(_) | E::HostNotFound | E::ConnectionFailed | E::Tls(_) | E::ConnectProxyFailed(_) | E::TlsRequired | E::RequireHttpsOnly(_) => {
            err(ErrTag::NetworkError, "")
        }
        E::Protocol(_) | E::BodyExceedsLimit(_) | E::LargeResponseHeader(_, _) => err(ErrTag::BadBody, ""),
        other => err(ErrTag::Other, &other.to_string()),
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__http_host__send(a: HttpHostSendArgs) -> HttpHostSendResult {
    let uri = a.uri.as_str().to_string();
    let method_str = if !a.method_ext.is_empty() {
        a.method_ext.as_str().to_string()
    } else {
        METHODS.get(a.method as usize).copied().unwrap_or("GET").to_string()
    };
    let headers: Vec<(String, String)> = a.headers.as_slice().iter().map(|h| (h._0.as_str().to_string(), h._1.as_str().to_string())).collect();
    let body = a.body.as_slice().to_vec();
    let timeout = a.timeout_ms;
    unsafe { a.decref(abi::host()); } // whole-struct decref recurses into header element strings (B0)

    // tls-off build: no rustls linked, so https can't work — reject it with a
    // clear message rather than a bare connect failure (H12).
    #[cfg(not(feature = "tls"))]
    if uri.starts_with("https://") {
        return err(ErrTag::Other, "https requires the tls feature, which is disabled in this build");
    }

    let method = match http::Method::from_bytes(method_str.as_bytes()) {
        Ok(m) => m,
        Err(_) => return err(ErrTag::Other, "invalid HTTP method"),
    };
    let mut builder = http::Request::builder().method(method).uri(&uri);
    for (k, v) in &headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    let request = match builder.body(body) {
        Ok(r) => r,
        Err(e) => return err(ErrTag::Other, &format!("bad request: {e}")),
    };

    let ag = agent();
    // Per-request timeout (H9, revised): timeout_ms bounds each phase —
    // connect, send the request, send the body, receive the headers, receive
    // the body — each timed from the end of the one before, so a slow server
    // can take several times it in all. 0 = none.
    let configured = if timeout > 0 {
        let d = Duration::from_millis(timeout);
        // Sending is bounded too: without a send timeout ureq gives every wait
        // for a header byte a fresh deadline, and a 500ms request whose headers
        // trickled in a byte every 300ms succeeded after 26s.
        ag.configure_request(request)
            .timeout_connect(Some(d))
            .timeout_send_request(Some(d))
            .timeout_send_body(Some(d))
            .timeout_recv_response(Some(d))
            .timeout_recv_body(Some(d))
            .build()
    } else {
        request
    };

    let resp = match without_sigpipe(|| ag.run(configured)) {
        Ok(r) => r,
        Err(e) => return send_err(&e),
    };

    let status = resp.status().as_u16();
    // NUL-joined, every occurrence preserved and in order (H10): correct for
    // repeated Set-Cookie; the shim splits back into List (Str, Str).
    let mut flat = Vec::new();
    for (name, value) in resp.headers().iter() {
        if !flat.is_empty() {
            flat.push(0);
        }
        flat.extend_from_slice(name.as_str().as_bytes());
        flat.push(0);
        flat.extend_from_slice(value.as_bytes());
    }
    // The body joins files/sockets/stdin as an InputStream (H5): mint one from
    // ureq's owned 'static body reader (decoded: chunked undone, gzip/brotli
    // decompressed). Early-dropping the stream recycles the connection via the
    // B0 destructor.
    let reader = resp.into_body().into_reader();
    let body_stream = sync_io_core::input_stream(Box::new(reader)) as *mut u64;

    let ok = Ok { body_stream, headers_flat: unsafe { RocListWith::<u8, false>::from_slice(&flat, abi::host()) }, status };
    HttpHostSendResult { payload: HttpHostSendResultPayload { ok: ManuallyDrop::new(ok) }, tag: HttpHostSendResultTag::Ok }
}

/// The most one `read_body!` allocates, however large its `max`.
const BODY_CHUNK_MAX: u64 = 1 << 20;

/// What a body read failed with, named where `IOErr` cannot name it.
///
/// ureq wraps its own errors in an `io::Error` whose kind is `Other`, so the
/// kind alone says nothing: a stalled body is `Other("timeout: receive
/// response")`. The wrapped error is looked at first, then the kind.
///
/// A compressed body wraps once more: the decoder reports the connection
/// ending as `Decompress("gzip", <that error>)`, so a cut-off gzip response —
/// the common case, since ureq asks for gzip — was `Io` rather than
/// `EndedEarly`. The error inside is classified the same way; corrupt data,
/// which is neither a timeout nor an early end, stays `Io`.
fn body_failure(e: &std::io::Error) -> BodyErrTag {
    if let Some(inner) = e.get_ref().and_then(|inner| inner.downcast_ref::<ureq::Error>()) {
        match inner {
            ureq::Error::Timeout(_) => return BodyErrTag::TimedOut,
            ureq::Error::Io(io) => return body_failure(io),
            // Only the connection ending counts as ending early here. The
            // decoder reports a compressed stream that is itself truncated,
            // inside a body that arrived whole, as UnexpectedEof too; that is
            // bad data, and a retry would return the same bytes.
            ureq::Error::Decompress(_, io) => {
                return match body_failure(io) {
                    BodyErrTag::EndedEarly if !connection_ended(io) => BodyErrTag::Io,
                    other => other,
                };
            }
            _ => {}
        }
    }
    kind_failure(e.kind())
}

/// Whether an error is the connection going away rather than the data inside
/// it running out. ureq reports a disconnect as `UnexpectedEof` with exactly
/// this message (`Error::disconnected`, ureq pinned at 3.4.0); flate2 reports
/// a truncated gzip stream with the same kind and a different message.
fn connection_ended(e: &std::io::Error) -> bool {
    use std::io::ErrorKind as K;
    if let Some(ureq::Error::Io(inner)) = e.get_ref().and_then(|inner| inner.downcast_ref::<ureq::Error>()) {
        return connection_ended(inner);
    }
    match e.kind() {
        K::ConnectionReset | K::ConnectionAborted => true,
        K::UnexpectedEof => e.get_ref().is_some_and(|inner| inner.to_string() == UREQ_DISCONNECTED),
        _ => false,
    }
}

/// ureq 3.4.0's message for a peer that closed mid-response.
const UREQ_DISCONNECTED: &str = "Peer disconnected";

fn kind_failure(kind: std::io::ErrorKind) -> BodyErrTag {
    use std::io::ErrorKind as K;
    match kind {
        K::TimedOut | K::WouldBlock => BodyErrTag::TimedOut,
        // ureq's "Peer disconnected" is how it reports both: measured, a
        // server that resets mid-body reads the same as one that closes.
        K::UnexpectedEof | K::ConnectionReset | K::ConnectionAborted => BodyErrTag::EndedEarly,
        _ => BodyErrTag::Io,
    }
}

/// `HttpHost.read_body! : Streams.InputStream, U64 => Try(List(U8), BodyErr)`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__http_host__read_body(stream: *mut u64, max: u64) -> HttpHostReadBodyResult {
    use std::io::Read;
    let outcome: std::io::Result<Vec<u8>> = unsafe {
        abi::resource::with(stream as RocBox, |input: &mut sync_io_core::Input| {
            let mut buf = vec![0u8; max.min(BODY_CHUNK_MAX) as usize];
            // A TLS read can write too: rustls sends an alert after a bad
            // record, or answers a KeyUpdate, while reading.
            let n = without_sigpipe(|| input.0.read(&mut buf))?;
            buf.truncate(n);
            Ok(buf)
        })
    };
    match outcome {
        Ok(bytes) => HttpHostReadBodyResult { payload: HttpHostReadBodyResultPayload { ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(&bytes, abi::host()) }) }, tag: HttpHostReadBodyResultTag::Ok },
        Err(e) => {
            let tag = body_failure(&e);
            let err = if let BodyErrTag::Io = tag {
                let io_tag = sync_io_core::ioerr_tag!(e, HttpHostIOErrTag);
                let io = if let HttpHostIOErrTag::Other = io_tag {
                    HttpHostIOErr { payload: HttpHostIOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag: io_tag }
                } else {
                    HttpHostIOErr { payload: unsafe { core::mem::zeroed() }, tag: io_tag }
                };
                BodyErr { payload: BodyErrPayload { io: ManuallyDrop::new(io) }, tag }
            } else {
                BodyErr { payload: unsafe { core::mem::zeroed() }, tag }
            };
            HttpHostReadBodyResult { payload: HttpHostReadBodyResultPayload { err: ManuallyDrop::new(err) }, tag: HttpHostReadBodyResultTag::Err }
        }
    }
}
