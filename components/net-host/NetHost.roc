import IOErr exposing [IOErr]
import Streams
import Sockets
import HttpHost
import InternalHttp

## The network half of what used to be one `Host` module in the CLI baseline.
##
## It had to move with the sockets: `http_send_request!` speaks
## `InternalHttp`, which lives here, so the baseline was depending backwards on
## the package that depends on it. Tcp/Udp/Http call this; nothing else does.
NetHost :: [].{
	## basic-cli's Tcp surface: the handle IS the socket resource; streams are
	## minted per call (drop-balanced). Timeouts via tcp_set_read_timeout!.
	TcpStream : Sockets.TcpSocket
	## Errors cross STRUCTURED. These used to return `Try(_, Str)` built from
	## `IOErr.to_str`, and Tcp.roc parsed the string back into tags — a contract
	## nothing type-checked, whose two halves had drifted apart, so every TCP
	## failure arrived as `Unrecognized`. Udp never did this; neither does this
	## now.
	## Connect reports Sockets.NetErr: a refused connection or a timeout is a
	## network condition, not an IOErr. Reads and writes do too.
	##
	## A ZERO budget fails immediately, everywhere in this module. `Tcp.roc` has
	## always said so; the host read it as "no timeout" and set `None`, so the
	## value that looks most conservative was the only one that could block
	## forever — and because the read timeout is re-applied per call, one
	## `read_up_to!(s, n, 0)` also CLEARED the timeout for every later read on
	## that stream. Rejecting it here means it never reaches the socket.
	tcp_connect! : Str, U16, U64 => Try(TcpStream, Sockets.NetErr)
	tcp_connect! = |host, port, timeout_ms|
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
			## The timeout goes INTO the connect now. It used to be applied
			## afterwards as the socket's read timeout, leaving the connect
			## itself unbounded: a 500ms budget against a full accept queue
			## returned after 8.05s.
			match Sockets.tcp_connect!(host, port, timeout_ms) {
				Ok(sock) => {
					Sockets.tcp_set_read_timeout!(sock, timeout_ms)
					Ok(sock)
				}
				Err(e) => Err(e)
			}
		}
	## The listening side. A listener is the same socket resource as a stream,
	## named apart so each signature says which of the two it takes.
	TcpListener : Sockets.TcpSocket
	tcp_listen! : Str, U16 => Try(TcpListener, Sockets.NetErr)
	tcp_listen! = |host, port| Sockets.tcp_listen!(host, port)
	tcp_accept! : TcpListener, U64 => Try(TcpStream, Sockets.NetErr)
	tcp_accept! = |listener, timeout_ms|
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
			Sockets.tcp_accept!(listener, timeout_ms)
		}
	tcp_local_port! : TcpListener => U16
	tcp_local_port! = |listener| Sockets.tcp_local_port!(listener)
	tcp_read_up_to! : TcpStream, U64, U64 => Try(List(U8), Sockets.NetErr)
	tcp_read_up_to! = |sock, max, timeout_ms|
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
			Sockets.tcp_set_read_timeout!(sock, timeout_ms)
			Sockets.tcp_read!(sock, max)
		}
	## `UnexpectedEof` is its own tag, not a magic string: the stream ending
	## early is a different outcome from the read failing.
	tcp_read_exactly! : TcpStream, U64, U64 => Try(List(U8), [UnexpectedEof, ConnectionRefused, ConnectionReset, TimedOut, AddrInUse, AddrNotAvailable, Io(IOErr)])
	tcp_read_exactly! = |sock, n, timeout_ms|
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
			Sockets.tcp_set_read_timeout!(sock, timeout_ms)
			# One host call under one budget: a Roc loop of reads gave every
			# chunk a fresh timeout, and dropped what it had on a failure.
			bytes = widen_net(Sockets.tcp_read_exactly!(sock, n))?
			if List.len(bytes) < n {
				# The stream ended short. What did arrive stays readable: an
				# error that also discards bytes is how a stream goes
				# misaligned without anyone being told (D-S2-55).
				Sockets.tcp_unread!(sock, bytes)
				Err(UnexpectedEof)
			} else {
				Ok(bytes)
			}
		}
	## `LimitExceeded` likewise. Reaching `max` without the delimiter used to
	## return `Ok` of a truncated buffer, indistinguishable from success.
	##
	## One hosted call now. It used to be a Roc loop reading a single byte at a
	## time, each through a stream minted for that byte and destroyed after it,
	## so the first read pulled the whole line into a buffer and returned one
	## byte of it — the rest was gone and the next call found nothing.
	tcp_read_until! : TcpStream, U8, U64, U64 => Try(List(U8), [LimitExceeded, ConnectionRefused, ConnectionReset, TimedOut, AddrInUse, AddrNotAvailable, Io(IOErr)])
	tcp_read_until! = |sock, delim, max, timeout_ms| {
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
		Sockets.tcp_set_read_timeout!(sock, timeout_ms)
		bytes = widen_net(Sockets.tcp_read_until!(sock, delim, max))?
		## `max` bytes without the delimiter among them is the limit case; the
		## host stops at `max` and cannot say which happened.
		ended_with_delim =
			match List.last(bytes) {
				Ok(b) => b == delim
				Err(_) => Bool.False
			}
		# `max` bytes and no delimiter: those bytes are consumed, as basic-cli
		# consumes them, and the error says exactly that many went. Putting them
		# back made a loop that skips over-long lines retry the same bytes
		# forever, instantly, from the pending buffer (D-S2-55).
		if List.len(bytes) >= max and !ended_with_delim { Err(LimitExceeded) } else { Ok(bytes) }
		}
	}
	## Writes carry NetErr, and the timeout is real. The parameter used to be
	## named `_timeout_ms` and discarded — there was no write-timeout leaf at
	## all — so a write to a peer that accepts and never reads blocked
	## indefinitely, and the `TcpWriteErr(TimedOut)` Tcp.roc documents could not
	## happen. It also went through `Streams.write!` as `Io(IOErr)`, and `IOErr`
	## has no TimedOut to return.
	tcp_write! : TcpStream, List(U8), U64 => Try({}, Sockets.NetErr)
	tcp_write! = |sock, bytes, timeout_ms|
		if timeout_ms == 0 {
			Err(TimedOut)
		} else {
			Sockets.tcp_set_write_timeout!(sock, timeout_ms)
			Sockets.tcp_write!(sock, bytes)
		}

	## Up to `max` bytes of a response body, its failure named.
	http_read_body! : Streams.InputStream, U64 => Try(List(U8), HttpHost.BodyErr)
	http_read_body! = |stream, max| HttpHost.read_body!(stream, max)

	http_send_request! : InternalHttp.RequestToAndFromHost => Try(InternalHttp.ResponseToAndFromHost, InternalHttp.TransportErr)
	http_send_request! = |req| {
		# Pass the body stream through unchanged (H5); Http collects on demand
		# via read_body_to_end!, so the shim no longer eagerly reads the body.
		match HttpHost.send!(req) {
			Ok(resp) => Ok({ status: resp.status, headers: split_headers(resp.headers_flat), body_stream: resp.body_stream })
			Err(e) => Err(e)
		}
	}
}

## Rebuild a `Sockets.NetErr` into an open union. This compiler will not widen
## a closed alias into a superset on its own, so every widen in this tree is
## spelled out — see stdio-lib's `widen_stdout_err` for the same shape.
widen_net : Try(a, Sockets.NetErr) -> Try(a, [ConnectionRefused, ConnectionReset, TimedOut, AddrInUse, AddrNotAvailable, Io(IOErr), ..])
widen_net = |r|
	match r {
		Ok(v) => Ok(v)
		Err(ConnectionRefused) => Err(ConnectionRefused)
		Err(ConnectionReset) => Err(ConnectionReset)
		Err(TimedOut) => Err(TimedOut)
		Err(AddrInUse) => Err(AddrInUse)
		Err(AddrNotAvailable) => Err(AddrNotAvailable)
		Err(Io(e)) => Err(Io(e))
	}

split_headers : List(U8) -> List((Str, Str))
split_headers = |flat| {
	parts = split_on_nul(flat, [], [])
	pair_up(parts, [])
}

split_on_nul : List(U8), List(U8), List(Str) -> List(Str)
split_on_nul = |bytes, cur, acc| {
	match bytes {
		[] => if List.is_empty(cur) and List.is_empty(acc) { [] } else { List.append(acc, Str.from_utf8_lossy(cur)) }
		[0, .. as rest] => split_on_nul(rest, [], List.append(acc, Str.from_utf8_lossy(cur)))
		[b, .. as rest] => split_on_nul(rest, List.append(cur, b), acc)
	}
}

pair_up : List(Str), List((Str, Str)) -> List((Str, Str))
pair_up = |parts, acc| {
	match parts {
		[k, v, .. as rest] => pair_up(rest, List.append(acc, (k, v)))
		_ => acc
	}

}
