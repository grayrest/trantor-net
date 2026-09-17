//! The socket host's budgeted calls, compiled from the SAME source file the
//! host ships, so they can be tested without a composed world.
//!
//! `tests/eintr` covers the leaves end to end through Roc, but trantor builds
//! apps on macOS only (its symbol scan reads Mach-O, and roc's arm64glibc link
//! brings no libc). The defect is Linux's, so this crate is what runs there.

#[path = "../../../components/sockets-host/src/budget.rs"]
pub mod budget;
