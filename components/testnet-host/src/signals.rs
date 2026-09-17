//! TEST SCAFFOLDING: interrupt the calling thread with a signal while it is
//! blocked in a socket call.
//!
//! A Roc app has no way to install a signal handler, and a handler is what
//! turns a signal into EINTR: with none, SIGUSR1 kills the process. The signal
//! goes to the calling thread by `pthread_kill`, not to the process, so it
//! cannot land on some other thread and leave the socket call untouched.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// How many SIGUSR1s the handler has seen since the last `take_interrupts!`.
/// Without it a test that never delivered its signal would pass.
static DELIVERED: AtomicU64 = AtomicU64::new(0);

extern "C" fn count_delivery(_signal: libc::c_int) {
    DELIVERED.fetch_add(1, Ordering::SeqCst);
}

/// Installs the counting handler for SIGUSR1, with `SA_RESTART` exactly when
/// `restart` is true. Re-installed on every call so one app can try both.
fn install_handler(restart: bool) {
    // SAFETY: a zeroed sigaction is valid; the handler touches only an atomic,
    // which is async-signal-safe.
    unsafe {
        let mut action: libc::sigaction = core::mem::zeroed();
        action.sa_sigaction = count_delivery as *const () as libc::sighandler_t;
        action.sa_flags = if restart { libc::SA_RESTART } else { 0 };
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(libc::SIGUSR1, &action, core::ptr::null_mut());
    }
}

/// `TestNet.interrupt_after! : U64, Bool => {}`
/// Installs the handler, then signals THIS thread once, `ms` from now.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__testnet_host__interrupt_after(ms: u64, restart: bool) {
    install_handler(restart);
    // pthread_t is a pointer on macOS and an integer on Linux; as usize it
    // crosses to the timer thread on both.
    let target = unsafe { libc::pthread_self() } as usize;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(ms));
        unsafe { libc::pthread_kill(target as libc::pthread_t, libc::SIGUSR1) };
    });
}

/// `TestNet.take_interrupts! : {} => U64`
/// The deliveries since the last call, resetting the count.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn trantor__testnet_host__take_interrupts() -> u64 {
    DELIVERED.swap(0, Ordering::SeqCst)
}
