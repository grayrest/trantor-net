//! A connected TCP stream and the bytes a failed read took off it.
//!
//! A read that times out part way has already consumed what it read from the
//! socket's buffer. Those bytes used to be dropped with the error, so after a
//! timeout the stream was still readable but misaligned: a peer sending `abc`,
//! then `def|rest` a second later, made `read_until!(124, _, 400)` time out and
//! the next call return `def|`, with `abc` gone and nothing said. They wait in
//! `pending` now, and every read takes from there first.
use crate::budget;
use std::io::{self, BufReader};
use std::net::TcpStream;

pub struct Conn {
    pub reader: BufReader<TcpStream>,
    pending: Vec<u8>,
}

impl Conn {
    pub fn new(stream: TcpStream) -> Self {
        Conn { reader: BufReader::new(stream), pending: Vec::new() }
    }

    /// Up to `max` bytes, from what an earlier read left before the socket.
    pub fn read(&mut self, max: usize) -> io::Result<Vec<u8>> {
        if !self.pending.is_empty() {
            let n = max.min(self.pending.len());
            return Ok(self.pending.drain(..n).collect());
        }
        let mut buf = vec![0u8; max];
        let n = budget::read(&mut self.reader, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Up to and including `delim`, at most `limit` bytes; shorter at end of
    /// stream.
    pub fn read_until(&mut self, delim: u8, limit: usize) -> io::Result<Vec<u8>> {
        let held = self.pending.len().min(limit);
        if let Some(at) = self.pending[..held].iter().position(|&b| b == delim) {
            return Ok(self.pending.drain(..=at).collect());
        }
        let mut out: Vec<u8> = self.pending.drain(..held).collect();
        if out.len() >= limit {
            return Ok(out);
        }
        match budget::read_until_into(&mut self.reader, delim, limit, &mut out) {
            Ok(()) => Ok(out),
            Err(e) => {
                self.keep(out);
                Err(e)
            }
        }
    }

    /// Exactly `want` bytes under one read timeout, or fewer at end of stream.
    pub fn read_exactly(&mut self, want: usize) -> io::Result<Vec<u8>> {
        let held = self.pending.len().min(want);
        let mut out: Vec<u8> = self.pending.drain(..held).collect();
        if out.len() == want {
            return Ok(out);
        }
        match budget::read_into(&mut self.reader, want, &mut out) {
            Ok(()) => Ok(out),
            Err(e) => {
                self.keep(out);
                Err(e)
            }
        }
    }

    /// Puts bytes back in front of anything still held, for a caller that
    /// read them and then decided the read failed (a limit reached without
    /// the delimiter, a stream that ended short).
    pub fn unread(&mut self, bytes: Vec<u8>) {
        self.keep(bytes);
    }

    /// Puts bytes a failed read consumed back in front of anything still held.
    fn keep(&mut self, mut partial: Vec<u8>) {
        partial.extend_from_slice(&self.pending);
        self.pending = partial;
    }
}
