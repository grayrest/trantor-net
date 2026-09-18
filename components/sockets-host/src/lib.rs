//! roc:sync-sockets host: tcp (client+listen), udp, name lookup. Sockets are
//! resources (P5). Blocking (P12). Owned args decref'd; handles via
//! resource::with.
//!
//! Reads go through the socket's OWN buffer, which is why `Sock::Stream` holds
//! a `BufReader` rather than a bare `TcpStream`. They used to mint a stream
//! resource per call from a cloned socket; the hosted call owns that resource
//! and releases it on return, so every read destroyed the buffer it had just
//! filled and threw away everything it had read past the request.
mod budget;
mod conn;

use conn::Conn;
use core::mem::ManuallyDrop;
use trantor_abi as abi;
use abi::*;
use std::net::{SocketAddr, TcpListener, ToSocketAddrs, UdpSocket};
use std::time::Duration;

pub enum Sock { Stream(Conn), Listener(TcpListener), Udp(UdpSocket) }

/// The most one `tcp_read!` allocates, however large its `max` — the same
/// clamp, and the same reason, as `Streams.read!` and `udp_recv!`.
const READ_CHUNK_MAX: u64 = 1 << 20;

/// `not a connected stream`, for the socket ops that need one.
fn not_a_stream() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Unsupported, "not a connected stream")
}

/// `Sockets.NetErr`: the five network conditions named, everything else an
/// ordinary `Io(IOErr)`.
///
/// These five used to go through `IOErr`, which has no way to say
/// ConnectionRefused — so they all landed in `Other(message)` and reached
/// callers as an unrecognised string. That is the whole reason NetErr exists.
type NetErr = AddrInUseOrAddrNotAvailableOrConnectionRefusedOrConnectionResetOrIoOrTimedOut;
type NetErrTag = AddrInUseOrAddrNotAvailableOrConnectionRefusedOrConnectionResetOrIoOrTimedOutTag;
type NetErrPayload = AddrInUseOrAddrNotAvailableOrConnectionRefusedOrConnectionResetOrIoOrTimedOutPayload;

fn ioerr(e: &std::io::Error) -> IOErr {
    let tag = sync_io_core::ioerr_tag!(e, IOErrTag);
    if let IOErrTag::Other = tag { IOErr { payload: IOErrPayload { other: ManuallyDrop::new(RocStr::from_str(&e.to_string(), abi::host())) }, tag } } else { IOErr { payload: unsafe { core::mem::zeroed() }, tag } }
}

fn neterr(e: &std::io::Error) -> NetErr {
    use std::io::ErrorKind as K;
    let tag = match e.kind() {
        K::ConnectionRefused => NetErrTag::ConnectionRefused,
        K::ConnectionReset => NetErrTag::ConnectionReset,
        K::TimedOut => NetErrTag::TimedOut,
        // SO_RCVTIMEO expiry is EAGAIN/EWOULDBLOCK, not ETIMEDOUT. Every
        // socket here is blocking (P12), so there is no other way to get
        // WouldBlock, and without this a read timeout reached callers as
        // Unrecognized("Resource temporarily unavailable (os error 35)").
        K::WouldBlock => NetErrTag::TimedOut,
        K::AddrInUse => NetErrTag::AddrInUse,
        K::AddrNotAvailable => NetErrTag::AddrNotAvailable,
        _ => NetErrTag::Io,
    };
    if let NetErrTag::Io = tag {
        // SAFETY: SocketsIOErr is glue's twin of IOErr for this reach path —
        // the same ten variants, same layout (the "error twins" note above).
        let twin = unsafe { core::mem::transmute::<IOErr, SocketsIOErr>(ioerr(e)) };
        NetErr { payload: NetErrPayload { io: ManuallyDrop::new(twin) }, tag }
    } else {
        NetErr { payload: unsafe { core::mem::zeroed() }, tag }
    }
}
fn take_str(s: RocStr) -> String { let v = s.as_str().to_string(); unsafe { s.decref(abi::host()) }; v }
fn handle(s: Sock) -> *mut u64 { abi::resource::new(s) as *mut u64 }

macro_rules! sock_result { ($R:ident, $P:ident, $T:ident, $r:expr) => {
    match $r { Ok(s) => $R { payload: $P { ok: ManuallyDrop::new(handle(s)) }, tag: $T::Ok }, Err(e) => $R { payload: $P { err: ManuallyDrop::new(neterr(&e)) }, tag: $T::Err } }
}}

/// The same shape for a leaf whose Ok is a byte list rather than a socket.
macro_rules! read_result { ($R:ident, $P:ident, $T:ident, $r:expr) => {
    match $r {
        Ok(bytes) => $R { payload: $P { ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(&bytes, abi::host()) }) }, tag: $T::Ok },
        Err(e) => $R { payload: $P { err: ManuallyDrop::new(neterr(&e)) }, tag: $T::Err },
    }
}}

/// No IP datagram can exceed this, so a larger `max` asks for memory that
/// cannot be filled. Unclamped, `recv!(sock, 4.6e18)` aborted the process:
/// "memory allocation of 4611686018427387904 bytes failed", exit 134.
const DATAGRAM_MAX: u64 = 65535;

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__resolve(name: RocStr) -> SocketsResolveResult {
    let host = take_str(name);
    match format!("{host}:0").to_socket_addrs() {
        Ok(addrs) => {
            let v: Vec<V4OrV6> = addrs.map(|a| match a.ip() {
                std::net::IpAddr::V4(ip) => { let o = ip.octets(); V4OrV6 { payload: V4OrV6Payload { v4: ManuallyDrop::new(V4OrV6V4Payload { _0: o[0], _1: o[1], _2: o[2], _3: o[3] }) }, tag: V4OrV6Tag::V4 } }
                std::net::IpAddr::V6(ip) => { let s = ip.segments(); V4OrV6 { payload: V4OrV6Payload { v6: ManuallyDrop::new(V4OrV6V6Payload { _0: s[0], _1: s[1], _2: s[2], _3: s[3], _4: s[4], _5: s[5], _6: s[6], _7: s[7] }) }, tag: V4OrV6Tag::V6 } }
            }).collect();
            SocketsResolveResult { payload: SocketsResolveResultPayload { ok: ManuallyDrop::new(unsafe { RocListWith::<V4OrV6, false>::from_slice(&v, abi::host()) }) }, tag: SocketsResolveResultTag::Ok }
        }
        Err(e) => SocketsResolveResult { payload: SocketsResolveResultPayload { err: ManuallyDrop::new(neterr(&e)) }, tag: SocketsResolveResultTag::Err },
    }
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_connect(host: RocStr, port: u16, ms: u64) -> SocketsTcpConnectResult {
    let h = take_str(host);
    sock_result!(SocketsTcpConnectResult, SocketsTcpConnectResultPayload, SocketsTcpConnectResultTag, budget::connect(|| Ok((h.as_str(), port).to_socket_addrs()?.collect()), Duration::from_millis(ms)).map(|c| Sock::Stream(Conn::new(c))))
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_listen(host: RocStr, port: u16) -> SocketsTcpListenResult {
    let h = take_str(host);
    sock_result!(SocketsTcpListenResult, SocketsTcpListenResultPayload, SocketsTcpListenResultTag, TcpListener::bind((h.as_str(), port)).map(Sock::Listener))
}
/// `Sockets.tcp_accept! : TcpSocket, U64 => Try(TcpSocket, NetErr)`
/// The next connection, waiting at most `ms`. A zero budget is rejected by the
/// caller (NetHost); here it is spent at once, never infinite.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_accept(l: *mut u64, ms: u64) -> SocketsTcpAcceptResult {
    let r = unsafe { abi::resource::with(l as RocBox, |s: &mut Sock| match s { Sock::Listener(l) => budget::accept(l, Duration::from_millis(ms)).map(|c| Sock::Stream(Conn::new(c))), _ => Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "not a listener")) }) };
    sock_result!(SocketsTcpAcceptResult, SocketsTcpAcceptResultPayload, SocketsTcpAcceptResultTag, r)
}
/// `Sockets.tcp_read! : TcpSocket, U64 => Try(List(U8), [Io(IOErr)])`
/// Up to `max` bytes from the socket's own buffer. Empty list = end of stream.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_read(s: *mut u64, max: u64) -> SocketsTcpReadResult {
    let r = unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x {
        Sock::Stream(c) => c.read(max.min(READ_CHUNK_MAX) as usize),
        _ => Err(not_a_stream()),
    }) };
    read_result!(SocketsTcpReadResult, SocketsTcpReadResultPayload, SocketsTcpReadResultTag, r)
}

/// `Sockets.tcp_read_until! : TcpSocket, U8, U64 => Try(List(U8), [Io(IOErr)])`
/// Up to and including the next `delim`, at most `max` bytes. Empty list = end.
/// One hosted call, against the buffer that persists between calls — the Roc
/// side used to do this a byte at a time through a fresh reader per byte.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_read_until(s: *mut u64, delim: u8, max: u64) -> SocketsTcpReadUntilResult {
    let r = unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x {
        Sock::Stream(c) => c.read_until(delim, usize::try_from(max).unwrap_or(usize::MAX)),
        _ => Err(not_a_stream()),
    }) };
    read_result!(SocketsTcpReadUntilResult, SocketsTcpReadUntilResultPayload, SocketsTcpReadUntilResultTag, r)
}

/// `Sockets.tcp_read_exactly! : TcpSocket, U64 => Try(List(U8), NetErr)`
/// Exactly `want` bytes under the one read timeout, or fewer at end of stream.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_read_exactly(s: *mut u64, want: u64) -> SocketsTcpReadExactlyResult {
    let r = unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x {
        Sock::Stream(c) => c.read_exactly(usize::try_from(want).unwrap_or(usize::MAX)),
        _ => Err(not_a_stream()),
    }) };
    read_result!(SocketsTcpReadExactlyResult, SocketsTcpReadExactlyResultPayload, SocketsTcpReadExactlyResultTag, r)
}

/// `Sockets.tcp_unread! : TcpSocket, List(U8) => {}`
/// Bytes a read returned, put back in front of the next read.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_unread(s: *mut u64, bytes: RocListWith<u8, false>) {
    let b = bytes.as_slice().to_vec();
    unsafe { bytes.decref(abi::host()) };   // owned arg (B0)
    unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| { if let Sock::Stream(c) = x { c.unread(b); } }) }
}

/// `Sockets.tcp_write! : TcpSocket, List(U8) => Try({}, NetErr)`
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_write(s: *mut u64, bytes: RocListWith<u8, false>) -> SocketsTcpWriteResult {
    let b = bytes.as_slice().to_vec();
    unsafe { bytes.decref(abi::host()) };   // owned arg (B0)
    let r = unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x {
        Sock::Stream(c) => budget::write_all(c.reader.get_mut(), &b),
        _ => Err(not_a_stream()),
    }) };
    match r {
        Ok(()) => SocketsTcpWriteResult { payload: SocketsTcpWriteResultPayload { ok: [] }, tag: SocketsTcpWriteResultTag::Ok },
        Err(e) => SocketsTcpWriteResult { payload: SocketsTcpWriteResultPayload { err: ManuallyDrop::new(neterr(&e)) }, tag: SocketsTcpWriteResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_set_read_timeout(s: *mut u64, ms: u64) {
    unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| { if let Sock::Stream(c) = x { let _ = c.reader.get_ref().set_read_timeout(if ms == 0 { None } else { Some(Duration::from_millis(ms)) }); } }) }
}

/// The write half of the same knob. There was no such leaf at all, so
/// `Tcp.write!`'s `timeout_ms` was named `_timeout_ms` and discarded: a write
/// to a peer that accepts and never reads blocked indefinitely.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_set_write_timeout(s: *mut u64, ms: u64) {
    unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| { if let Sock::Stream(c) = x { let _ = c.reader.get_ref().set_write_timeout(if ms == 0 { None } else { Some(Duration::from_millis(ms)) }); } }) }
}
/// The UDP half. `recv_from` blocks until a datagram arrives, and there was
/// no way to bound it.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__udp_set_read_timeout(s: *mut u64, ms: u64) {
    unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| { if let Sock::Udp(u) = x { let _ = u.set_read_timeout(if ms == 0 { None } else { Some(Duration::from_millis(ms)) }); } }) }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__tcp_local_port(s: *mut u64) -> u16 {
    unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x { Sock::Stream(c) => c.reader.get_ref().local_addr().map(|a| a.port()).unwrap_or(0), Sock::Listener(l) => l.local_addr().map(|a| a.port()).unwrap_or(0), Sock::Udp(u) => u.local_addr().map(|a| a.port()).unwrap_or(0) }) }
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__udp_bind(host: RocStr, port: u16) -> SocketsUdpBindResult {
    let h = take_str(host);
    sock_result!(SocketsUdpBindResult, SocketsUdpBindResultPayload, SocketsUdpBindResultTag, UdpSocket::bind((h.as_str(), port)).map(Sock::Udp))
}
/// Which of a name's addresses a datagram goes to: the first of the socket's
/// own family. It was simply the first, and `localhost` resolves to 127.0.0.1
/// before ::1 on macOS, so a socket bound to ::1 could not send to it by name.
/// With none of that family it is the first after all, and the send's own
/// error says why that cannot work.
fn destination(addrs: &[SocketAddr], local: SocketAddr) -> std::io::Result<SocketAddr> {
    addrs.iter().find(|a| a.is_ipv6() == local.is_ipv6()).or_else(|| addrs.first()).copied()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::AddrNotAvailable, "no address for host"))
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__udp_send_to(s: *mut u64, host: RocStr, port: u16, bytes: RocListWith<u8, false>) -> SocketsUdpSendToResult {
    let h = take_str(host); let b = bytes.as_slice().to_vec(); unsafe { bytes.decref(abi::host()) };
    // The lookup happens before the send, outside any budget, as for connect.
    let addrs = (h.as_str(), port).to_socket_addrs().map(Iterator::collect::<Vec<_>>);
    let r = addrs.and_then(|addrs| unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x {
        Sock::Udp(u) => destination(&addrs, u.local_addr()?).and_then(|to| budget::send_to(u, &b, to)),
        _ => Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "not udp")),
    }) });
    match r { Ok(n) => SocketsUdpSendToResult { payload: SocketsUdpSendToResultPayload { ok: ManuallyDrop::new(n as u64) }, tag: SocketsUdpSendToResultTag::Ok }, Err(e) => SocketsUdpSendToResult { payload: SocketsUdpSendToResultPayload { err: ManuallyDrop::new(neterr(&e)) }, tag: SocketsUdpSendToResultTag::Err } }
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__udp_recv(s: *mut u64, max: u64) -> SocketsUdpRecvResult {
    let r = unsafe { abi::resource::with(s as RocBox, |x: &mut Sock| match x { Sock::Udp(u) => { let mut buf = vec![0u8; max.min(DATAGRAM_MAX) as usize]; budget::recv_from(u, &mut buf).map(|(n, from)| { buf.truncate(n); (buf, from) }) }, _ => Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "not udp")) }) };
    match r {
        Ok((buf, from)) => SocketsUdpRecvResult { payload: SocketsUdpRecvResultPayload { ok: ManuallyDrop::new(AnonStruct902edcae59c36540 { bytes: unsafe { RocListWith::<u8, false>::from_slice(&buf, abi::host()) }, from_host: RocStr::from_str(&from.ip().to_string(), abi::host()), from_port: from.port() }) }, tag: SocketsUdpRecvResultTag::Ok },
        Err(e) => SocketsUdpRecvResult { payload: SocketsUdpRecvResultPayload { err: ManuallyDrop::new(neterr(&e)) }, tag: SocketsUdpRecvResultTag::Err },
    }
}
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__sockets_host__udp_local_port(s: *mut u64) -> u16 { trantor__sockets_host__tcp_local_port(s) }
