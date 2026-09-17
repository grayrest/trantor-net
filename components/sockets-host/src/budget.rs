//! Socket calls bounded by their whole timeout, which a signal neither ends
//! early nor stretches.
//!
//! No call here blocks in the kernel under SO_RCVTIMEO or SO_SNDTIMEO. The
//! socket is nonblocking for the length of a leaf call, and the waiting is done
//! by `poll` against one deadline on a monotonic clock. The timeout leaves
//! still record the budget in those socket options; this module only reads it
//! back.
//!
//! Why not the options themselves:
//!
//! - Linux never restarts a socket call that has SO_RCVTIMEO/SO_SNDTIMEO: under
//!   any installed handler, SA_RESTART or not, it returns EINTR (Linux 6.8: TCP
//!   recv, UDP recv, TCP send). trantor-terminal's SIGWINCH made every resize an
//!   `Interrupted` from Tcp and Udp.
//! - macOS restarts such a call under SA_RESTART inside the kernel with a FRESH
//!   timeout. A 2s recv under a signal every 0.5s returned after 10.03s: a
//!   window drag held the call open for as long as it lasted, and no retry
//!   around the call can see that happen. trantor-terminal keeps SA_RESTART
//!   (trantor D-K1-28), so the wait has to be somewhere a signal ends it.
//!   `poll` returns EINTR on both platforms whatever the flags (macOS, same
//!   signals: EINTR at 0.50s), and is simply called again with what is left.
//! - A timeout option is per syscall, not per call. A send that has moved bytes
//!   returns their count, and `write_all` gave the next send a fresh timeout; a
//!   32MB write to a stalled peer took twice its budget with no signal at all.
//!   Tcp's documented contract is the whole operation.
use std::io::{self, BufRead, BufReader, ErrorKind, Read};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};
use std::time::{Duration, Instant};

/// `poll`'s "no timeout".
const POLL_FOREVER: libc::c_int = -1;
/// How much one read of `read_into` asks the socket for.
const READ_CHUNK: usize = 1 << 16;
const MICROS_PER_MILLI: u128 = 1000;

/// Which of a socket's two timeouts a call runs under.
#[derive(Clone, Copy)]
enum Direction { Read, Write }

impl Direction {
    fn poll_events(self) -> libc::c_short {
        match self { Direction::Read => libc::POLLIN, Direction::Write => libc::POLLOUT }
    }
}

/// A socket whose recorded timeouts can be read and whose blocking mode can
/// be switched.
trait TimedSocket {
    fn timeout(&self, direction: Direction) -> io::Result<Option<Duration>>;
    fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()>;
    fn raw_fd(&self) -> RawFd;
}

impl TimedSocket for TcpStream {
    fn timeout(&self, direction: Direction) -> io::Result<Option<Duration>> {
        match direction { Direction::Read => self.read_timeout(), Direction::Write => self.write_timeout() }
    }
    fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> { TcpStream::set_nonblocking(self, nonblocking) }
    fn raw_fd(&self) -> RawFd { self.as_raw_fd() }
}

impl TimedSocket for UdpSocket {
    fn timeout(&self, direction: Direction) -> io::Result<Option<Duration>> {
        match direction { Direction::Read => self.read_timeout(), Direction::Write => self.write_timeout() }
    }
    fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> { UdpSocket::set_nonblocking(self, nonblocking) }
    fn raw_fd(&self) -> RawFd { self.as_raw_fd() }
}

impl<S: TimedSocket> TimedSocket for BufReader<S> {
    fn timeout(&self, direction: Direction) -> io::Result<Option<Duration>> { self.get_ref().timeout(direction) }
    fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> { self.get_ref().set_nonblocking(nonblocking) }
    fn raw_fd(&self) -> RawFd { self.get_ref().raw_fd() }
}

fn budget_spent() -> io::Error {
    io::Error::new(ErrorKind::TimedOut, "socket timeout elapsed before the call completed")
}

/// What is left of `deadline` as a `poll` timeout, rounded UP to a whole
/// millisecond: rounding down would poll for 0ms and spin through the last
/// fraction of the budget.
fn poll_timeout(deadline: Option<Instant>) -> Option<libc::c_int> {
    let Some(deadline) = deadline else { return Some(POLL_FOREVER) };
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() { return None; }
    let millis = left.as_micros().div_ceil(MICROS_PER_MILLI);
    Some(libc::c_int::try_from(millis).unwrap_or(libc::c_int::MAX))
}

/// One leaf call's deadline over one of a socket's timeouts. No timeout, no
/// deadline: the call waits as long as it takes, as the socket always did.
struct Budget {
    direction: Direction,
    deadline: Option<Instant>,
}

impl Budget {
    fn start(sock: &impl TimedSocket, direction: Direction) -> io::Result<Self> {
        let timeout = sock.timeout(direction)?;
        Ok(Budget { direction, deadline: timeout.map(|timeout| Instant::now() + timeout) })
    }

    /// Waits until `fd` is ready for this budget's direction, or fails
    /// TimedOut at the deadline. A signal ends `poll` early on every platform
    /// and flag setting; it is called again with what is left.
    fn wait_ready(&self, fd: RawFd) -> io::Result<()> {
        loop {
            let Some(timeout) = poll_timeout(self.deadline) else { return Err(budget_spent()) };
            let mut ready = libc::pollfd { fd, events: self.direction.poll_events(), revents: 0 };
            // SAFETY: one valid pollfd, and fd is open for the borrow's length.
            let polled = unsafe { libc::poll(&mut ready, 1, timeout) };
            if polled > 0 { return Ok(()); }
            if polled < 0 {
                let e = io::Error::last_os_error();
                if e.kind() != ErrorKind::Interrupted { return Err(e); }
            }
            // A timeout of 0 events, or EINTR: the loop re-reads the clock.
        }
    }

    /// One syscall's worth of work: made, and when the socket is not ready,
    /// waited for and made again.
    fn attempt<S: TimedSocket, T>(&self, sock: &mut S, mut call: impl FnMut(&mut S) -> io::Result<T>) -> io::Result<T> {
        loop {
            match call(sock) {
                Err(e) if e.kind() == ErrorKind::WouldBlock => self.wait_ready(sock.raw_fd())?,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                other => return other,
            }
        }
    }
}

/// Runs a leaf call's attempts under one budget, with the socket nonblocking
/// throughout, then puts it back to blocking.
fn within_budget<S: TimedSocket, T>(sock: &mut S, direction: Direction, call: impl FnOnce(&mut S, &Budget) -> io::Result<T>) -> io::Result<T> {
    let budget = Budget::start(&*sock, direction)?;
    sock.set_nonblocking(true)?;
    let result = call(sock, &budget);
    // Switching an open socket back to blocking cannot fail, and if it did,
    // failing here would throw away bytes the call already consumed.
    let _ = sock.set_nonblocking(false);
    result
}

/// `Read::read`, within the read timeout.
pub fn read(stream: &mut BufReader<TcpStream>, buf: &mut [u8]) -> io::Result<usize> {
    within_budget(stream, Direction::Read, |s, budget| budget.attempt(s, |s| s.read(buf)))
}

/// `BufRead::read_until` through `Read::take(max)`: up to and including
/// `delim`, until `out` holds `limit` bytes, stopping at end of stream. Every
/// refill of the buffer shares the one read timeout.
///
/// Appends to `out` rather than returning a fresh buffer, so a caller whose
/// read fails part way still has the bytes this took off the socket: they are
/// gone from the socket's buffer, and dropping them with the error left the
/// stream readable but misaligned.
pub fn read_until_into(stream: &mut BufReader<TcpStream>, delim: u8, limit: usize, out: &mut Vec<u8>) -> io::Result<()> {
    within_budget(stream, Direction::Read, |stream, budget| {
        while out.len() < limit {
            let available = budget.attempt(stream, |s| s.fill_buf().map(<[u8]>::len))?;
            if available == 0 { break; }
            let window = &stream.buffer()[..available.min(limit - out.len())];
            let (used, found) = match window.iter().position(|&b| b == delim) {
                Some(i) => (i + 1, true),
                None => (window.len(), false),
            };
            out.extend_from_slice(&window[..used]);
            stream.consume(used);
            if found { break; }
        }
        Ok(())
    })
}

/// Reads until `out` holds `want` bytes or the stream ends, every read sharing
/// the one read timeout. Appends, for the same reason `read_until_into` does.
///
/// A loop of `read` calls in Roc gave each chunk a fresh budget, so a peer
/// sending one byte every 300ms held a 500ms `read_exactly!` open for 5.8s.
pub fn read_into(stream: &mut BufReader<TcpStream>, want: usize, out: &mut Vec<u8>) -> io::Result<()> {
    within_budget(stream, Direction::Read, |stream, budget| {
        let mut chunk = vec![0u8; READ_CHUNK.min(want.saturating_sub(out.len())).max(1)];
        while out.len() < want {
            let ask = (want - out.len()).min(chunk.len());
            let n = budget.attempt(stream, |s| s.read(&mut chunk[..ask]))?;
            if n == 0 { break; }
            out.extend_from_slice(&chunk[..n]);
        }
        Ok(())
    })
}

/// `Write::write_all`, every send sharing the one write timeout.
pub fn write_all(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<()> {
    within_budget(stream, Direction::Write, |stream, budget| {
        let mut rest = bytes;
        while !rest.is_empty() {
            let written = budget.attempt(stream, |s| send(s, rest))?;
            if written == 0 { return Err(io::Error::from(ErrorKind::WriteZero)); }
            rest = &rest[written..];
        }
        Ok(())
    })
}

/// One send that cannot raise SIGPIPE. The app's `main` is exported to C, so
/// Rust's startup never ignores SIGPIPE, and a write to a peer that has closed
/// ends the process. macOS std sets `SO_NOSIGPIPE` on every socket it makes,
/// accepted ones included, so a plain write already answers `BrokenPipe`.
#[cfg(target_vendor = "apple")]
fn send(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<usize> {
    std::io::Write::write(stream, bytes)
}

/// Linux std's `write` is a plain `write(2)`, which raises SIGPIPE: measured,
/// a write to a closed peer exited 141. `MSG_NOSIGNAL` makes this one send
/// answer `EPIPE` instead, and changes nothing about the socket for anyone
/// else (D-S2-51).
#[cfg(not(target_vendor = "apple"))]
fn send(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<usize> {
    // SAFETY: a valid pointer and length for `bytes`, on an open socket.
    let sent = unsafe { libc::send(stream.as_raw_fd(), bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) };
    usize::try_from(sent).map_err(|_| io::Error::last_os_error())
}

/// `TcpListener::accept`, waiting at most `timeout` for a connection.
///
/// A listener has no timeout option to record a budget in, so the deadline
/// comes from the caller. `accept` used to block until a peer connected, and a
/// server had no way to stop waiting — to notice a shutdown, say — short of
/// one arriving. The listener stays nonblocking for its whole life: nothing
/// else waits on it, and a connection `poll` reported that the peer abandoned
/// before `accept` took it then answers WouldBlock, and the wait resumes with
/// what is left, rather than blocking past the deadline for the next one.
/// ECONNABORTED is that same abandoned connection, reported instead of dropped.
///
/// A zero timeout is spent before it starts: it fails TimedOut when no
/// connection is already waiting, and never means "no timeout".
pub fn accept(listener: &TcpListener, timeout: Duration) -> io::Result<TcpStream> {
    let budget = Budget { direction: Direction::Read, deadline: Some(Instant::now() + timeout) };
    listener.set_nonblocking(true)?;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                // macOS hands the accepted socket the listener's O_NONBLOCK;
                // Linux does not. Reads and writes set the mode they need on
                // each call, so nothing here depends on it today; this keeps a
                // stream from ever leaving accept in a mode no other stream has.
                stream.set_nonblocking(false)?;
                return Ok(stream);
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => budget.wait_ready(listener.as_raw_fd())?,
            Err(e) if matches!(e.kind(), ErrorKind::Interrupted | ErrorKind::ConnectionAborted) => continue,
            Err(e) => return Err(e),
        }
    }
}

/// `UdpSocket::send_to`, with the EINTR retry every other call has. A UDP
/// socket has no write timeout, so there is no deadline, only the retry.
pub fn send_to(sock: &mut UdpSocket, bytes: &[u8], to: SocketAddr) -> io::Result<usize> {
    within_budget(sock, Direction::Write, |s, budget| budget.attempt(s, |s| s.send_to(bytes, to)))
}

/// `UdpSocket::recv_from`, within the read timeout.
pub fn recv_from(sock: &mut UdpSocket, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
    within_budget(sock, Direction::Read, |s, budget| budget.attempt(s, |s| s.recv_from(buf)))
}
