//! A signal halfway through a timed socket call neither ends it early nor
//! stretches it: each call must time out at its whole budget, with the signal
//! delivered during it.
//!
//! Both handler kinds run on both platforms. The SA_RESTART half is the one
//! macOS failed while the host waited in the kernel under SO_RCVTIMEO: the
//! kernel restarted the call with a fresh timeout, and a 2s call ended at 3s.
use eintr_host::budget;
use std::io::{self, BufReader, ErrorKind};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const BUDGET: Duration = Duration::from_millis(2000);
const INTERRUPT_AT: Duration = Duration::from_millis(1000);
/// A retry that restarts the full timeout at 1000ms ends near 3000.
const OVERRUN: Duration = Duration::from_millis(2800);
/// Bigger than a loopback send buffer can grow to, so the write is still
/// blocked when the signal arrives.
const WRITE_BYTES: usize = 32 * 1024 * 1024;
const READ_MAX: u64 = 64;

/// SIGUSR1 deliveries since the current call began. Without it a test whose
/// signal never landed would pass.
static DELIVERED: AtomicU64 = AtomicU64::new(0);
/// One call at a time: the handler and its count are process-wide.
static SERIAL: Mutex<()> = Mutex::new(());

extern "C" fn count_delivery(_signal: libc::c_int) {
    DELIVERED.fetch_add(1, Ordering::SeqCst);
}

#[derive(Clone, Copy, Debug)]
enum Handler { NoRestart, Restart }

fn install(handler: Handler) {
    // SAFETY: a zeroed sigaction is valid; the handler touches only an atomic.
    unsafe {
        let mut action: libc::sigaction = core::mem::zeroed();
        action.sa_sigaction = count_delivery as *const () as libc::sighandler_t;
        action.sa_flags = match handler { Handler::NoRestart => 0, Handler::Restart => libc::SA_RESTART };
        libc::sigemptyset(&mut action.sa_mask);
        assert_eq!(libc::sigaction(libc::SIGUSR1, &action, core::ptr::null_mut()), 0, "sigaction(SIGUSR1)");
    }
}

#[derive(Debug)]
struct Outcome { result: io::Result<()>, elapsed: Duration, delivered: u64 }

/// Runs `call` with SIGUSR1 sent to this thread `INTERRUPT_AT` in.
fn interrupted(handler: Handler, call: impl FnOnce() -> io::Result<()>) -> Outcome {
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    install(handler);
    DELIVERED.store(0, Ordering::SeqCst);
    // pthread_t is a pointer on macOS and an integer on Linux; as usize it
    // crosses to the timer thread on both.
    let target = unsafe { libc::pthread_self() } as usize;
    let start = Instant::now();
    let timer = std::thread::spawn(move || {
        std::thread::sleep(INTERRUPT_AT);
        unsafe { libc::pthread_kill(target as libc::pthread_t, libc::SIGUSR1) };
    });
    let result = call();
    let elapsed = start.elapsed();
    // A call that returned before the signal still gets it here, so the count
    // is final before the next test installs anything.
    timer.join().expect("timer thread");
    Outcome { result, elapsed, delivered: DELIVERED.load(Ordering::SeqCst) }
}

/// `Ok` when the call timed out at its whole budget with one signal in it.
fn at_full_budget(outcome: &Outcome) -> Result<(), String> {
    if outcome.delivered != 1 {
        return Err(format!("{} signals delivered, want 1 — the check proves nothing", outcome.delivered));
    }
    match &outcome.result {
        Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
        other => return Err(format!("ended {other:?} after {:?}, want a timeout", outcome.elapsed)),
    }
    if !(BUDGET..OVERRUN).contains(&outcome.elapsed) {
        return Err(format!("timed out after {:?}, want {BUDGET:?}..{OVERRUN:?}", outcome.elapsed));
    }
    Ok(())
}

/// A connected stream whose peer never sends and never reads. The peer's end
/// is returned so it stays open.
fn silent_peer() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind listener");
    let client = TcpStream::connect(listener.local_addr().expect("listener address")).expect("connect");
    let (peer, _) = listener.accept().expect("accept");
    client.set_read_timeout(Some(BUDGET)).expect("set read timeout");
    client.set_write_timeout(Some(BUDGET)).expect("set write timeout");
    (client, peer)
}

fn tcp_read(handler: Handler) -> Outcome {
    let (client, _peer) = silent_peer();
    let mut stream = BufReader::new(client);
    let mut buf = [0u8; 4];
    interrupted(handler, || budget::read(&mut stream, &mut buf).map(drop))
}

fn tcp_read_until(handler: Handler) -> Outcome {
    let (client, _peer) = silent_peer();
    let mut stream = BufReader::new(client);
    let mut out = Vec::new();
    interrupted(handler, || budget::read_until_into(&mut stream, b'\n', READ_MAX as usize, &mut out))
}

fn tcp_write(handler: Handler) -> Outcome {
    let (mut client, _peer) = silent_peer();
    let payload = vec![b'A'; WRITE_BYTES];
    interrupted(handler, || budget::write_all(&mut client, &payload))
}

fn udp_recv(handler: Handler) -> Outcome {
    let mut sock = UdpSocket::bind("127.0.0.1:0").expect("bind udp");
    sock.set_read_timeout(Some(BUDGET)).expect("set read timeout");
    let mut buf = [0u8; 1024];
    interrupted(handler, || budget::recv_from(&mut sock, &mut buf).map(drop))
}

#[test]
fn should_time_out_at_full_budget_when_tcp_read_is_interrupted() {
    assert_eq!(at_full_budget(&tcp_read(Handler::NoRestart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_tcp_read_until_is_interrupted() {
    assert_eq!(at_full_budget(&tcp_read_until(Handler::NoRestart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_tcp_write_is_interrupted() {
    assert_eq!(at_full_budget(&tcp_write(Handler::NoRestart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_udp_recv_is_interrupted() {
    assert_eq!(at_full_budget(&udp_recv(Handler::NoRestart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_tcp_read_is_interrupted_under_sa_restart() {
    assert_eq!(at_full_budget(&tcp_read(Handler::Restart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_tcp_read_until_is_interrupted_under_sa_restart() {
    assert_eq!(at_full_budget(&tcp_read_until(Handler::Restart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_tcp_write_is_interrupted_under_sa_restart() {
    assert_eq!(at_full_budget(&tcp_write(Handler::Restart)), Ok(()));
}

#[test]
fn should_time_out_at_full_budget_when_udp_recv_is_interrupted_under_sa_restart() {
    assert_eq!(at_full_budget(&udp_recv(Handler::Restart)), Ok(()));
}
