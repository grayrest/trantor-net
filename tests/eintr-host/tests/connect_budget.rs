//! A connect's timeout starts once the name lookup returns (D-S2-57).
//!
//! The lookup here is a stand-in that sleeps, not the system resolver: offline
//! there is no way to make a real lookup slow, so this holds `budget::connect`
//! to its order — lookup, then deadline — and not `getaddrinfo` to any speed.
//! That the host passes its lookup in as this closure is what ties the two.
use eintr_host::budget;
use std::io;
use std::net::{SocketAddr, TcpListener};
use std::time::Duration;

const BUDGET: Duration = Duration::from_millis(200);
/// Longer than the budget, so a deadline taken before the lookup has passed
/// before the first address is tried.
const LOOKUP: Duration = Duration::from_millis(400);

#[test]
fn should_connect_when_the_lookup_outlasts_the_budget() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind a local listener");
    let addr = listener.local_addr().expect("the listener's address");
    let slow_lookup = || -> io::Result<Vec<SocketAddr>> {
        std::thread::sleep(LOOKUP);
        Ok(vec![addr])
    };
    let connected = budget::connect(slow_lookup, BUDGET);
    assert!(connected.is_ok(), "a slow lookup spent the connect's budget: {connected:?}");
}
