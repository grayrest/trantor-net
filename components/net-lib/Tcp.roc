import IOErr exposing [IOErr]
import NetHost

## Connect to TCP servers, accept connections, and exchange buffered byte
## streams. basic-cli's Tcp has no server side; `listen!` and `Listener` are
## trantor's.
##
## See the [host runtime behavior](https://github.com/roc-lang/basic-cli#host-runtime-behavior)
## for additional runtime details.
##
## Timeout arguments are in milliseconds and apply to the whole operation,
## including every underlying read/write attempt. A zero timeout fails
## immediately. Read and write timeouts are returned as
## `TcpReadErr(TimedOut)` and `TcpWriteErr(TimedOut)` respectively, and an
## accept timeout as `TimedOut`.
Tcp :: [].{

	## Represents a TCP stream.
	##
	## The connection is automatically closed when the last reference to the
	## stream is dropped. It wraps an opaque host-side `BufReader<TcpStream>`
	## handle.
	Stream :: { host : NetHost.TcpStream }.{

		## Render the stream without exposing its host handle.
		to_inspect : Stream -> Str
		to_inspect = |_| "Tcp.Stream(<opaque>)"

		## Read up to a number of bytes, waiting at most `timeout_ms` milliseconds.
		## An empty list is the end of the stream, so a `bytes_to_read` of 0 reads
		## nothing and cannot be told from it: ask for at least one byte.
		read_up_to! : Stream, U64, U64 => Try(List(U8), [TcpReadErr(StreamErr), ..])
		read_up_to! = |stream, bytes_to_read, timeout_ms|
			NetHost.tcp_read_up_to!(stream.host, bytes_to_read, timeout_ms)
				.map_err(|err| TcpReadErr(stream_err(err)))

		## Read an exact number of bytes, waiting at most `timeout_ms` milliseconds.
		##
		## `TcpUnexpectedEOF` is returned if the stream ends before the specified
		## number of bytes is reached; the bytes that did arrive are still there
		## for the next read.
		read_exactly! : Stream, U64, U64 => Try(List(U8), [TcpUnexpectedEOF, TcpReadErr(StreamErr), ..])
		read_exactly! = |stream, bytes_to_read, timeout_ms|
			match NetHost.tcp_read_exactly!(stream.host, bytes_to_read, timeout_ms) {
				Ok(bytes) => Ok(bytes)
				Err(UnexpectedEof) => Err(TcpUnexpectedEOF)
				Err(ConnectionRefused) => Err(TcpReadErr(stream_err(ConnectionRefused)))
				Err(ConnectionReset) => Err(TcpReadErr(stream_err(ConnectionReset)))
				Err(TimedOut) => Err(TcpReadErr(stream_err(TimedOut)))
				Err(AddrInUse) => Err(TcpReadErr(stream_err(AddrInUse)))
				Err(AddrNotAvailable) => Err(TcpReadErr(stream_err(AddrNotAvailable)))
				Err(Io(e)) => Err(TcpReadErr(stream_err(Io(e))))
			}

		## Read until a delimiter or EOF is reached, consuming at most `max_bytes`
		## and waiting at most `timeout_ms` milliseconds.
		## If found, the delimiter is included as the last byte. Returns
		## `TcpReadLimitExceeded(max_bytes)` if the delimiter was not found within
		## the limit; those `max_bytes` bytes are consumed, as in basic-cli, so a
		## loop that skips over-long lines moves on.
		read_until! : Stream, U8, U64, U64 => Try(List(U8), [TcpReadLimitExceeded(U64), TcpReadErr(StreamErr), ..])
		read_until! = |stream, byte, max_bytes, timeout_ms|
			match NetHost.tcp_read_until!(stream.host, byte, max_bytes, timeout_ms) {
				Ok(bytes) => Ok(bytes)
				Err(LimitExceeded) => Err(TcpReadLimitExceeded(max_bytes))
				Err(ConnectionRefused) => Err(TcpReadErr(stream_err(ConnectionRefused)))
				Err(ConnectionReset) => Err(TcpReadErr(stream_err(ConnectionReset)))
				Err(TimedOut) => Err(TcpReadErr(stream_err(TimedOut)))
				Err(AddrInUse) => Err(TcpReadErr(stream_err(AddrInUse)))
				Err(AddrNotAvailable) => Err(TcpReadErr(stream_err(AddrNotAvailable)))
				Err(Io(e)) => Err(TcpReadErr(stream_err(Io(e))))
			}

		## Read at most `max_bytes` through a newline (`\n`, byte 10) or EOF as
		## UTF-8, waiting at most `timeout_ms` milliseconds. If found, the newline
		## is included as the last character. A line that is not valid UTF-8 is
		## `TcpReadBadUtf8`, and its bytes are consumed: use `read_until!` to keep
		## them.
		read_line! : Stream, U64, U64 => Try(Str, [TcpReadBadUtf8(_), TcpReadLimitExceeded(U64), TcpReadErr(StreamErr), ..])
		read_line! = |stream, max_bytes, timeout_ms|
			match read_until!(stream, 10, max_bytes, timeout_ms) {
				Ok(bytes) => Str.from_utf8(bytes).map_err(|err| TcpReadBadUtf8(err))
				Err(err) => Err(err)
			}

		## Write bytes, waiting at most `timeout_ms` milliseconds. A write that
		## times out may have sent part of `bytes`, and says nothing of how much:
		## treat the stream as unusable after one.
		write! : Stream, List(U8), U64 => Try({}, [TcpWriteErr(StreamErr), ..])
		write! = |stream, bytes, timeout_ms|
			NetHost.tcp_write!(stream.host, bytes, timeout_ms)
				.map_err(|err| TcpWriteErr(stream_err(err)))

		## Write a string as UTF-8, waiting at most `timeout_ms` milliseconds.
		write_utf8! : Stream, Str, U64 => Try({}, [TcpWriteErr(StreamErr), ..])
		write_utf8! = |stream, str, timeout_ms|
			write!(stream, Str.to_utf8(str), timeout_ms)
	}

	## A socket listening for connections, closed when the last reference to it
	## is dropped.
	Listener :: { host : NetHost.TcpListener }.{

		## Render the listener without exposing its host handle.
		to_inspect : Listener -> Str
		to_inspect = |_| "Tcp.Listener(<opaque>)"

		## Take the next connection, waiting at most `timeout_ms` milliseconds.
		## A zero timeout fails immediately, even with a connection waiting.
		##
		## The connection is an ordinary `Stream`, and each of its reads and
		## writes takes its own timeout. A server that wants to wait indefinitely
		## calls this in a loop and carries on after `TimedOut`, which is also
		## where it checks whether to shut down.
		accept! : Listener, U64 => Try(Stream, [TimedOut, PermissionDenied, OutOfMemory, Unrecognized(Str), ..])
		accept! = |listener, timeout_ms|
			NetHost.tcp_accept!(listener.host, timeout_ms)
				.map_ok(|stream| Stream.{ host: stream })
				.map_err(accept_err)

		## The port the listener is bound to: the one the OS picked, when
		## `listen!` was given port 0.
		port! : Listener => U16
		port! = |listener| NetHost.tcp_local_port!(listener.host)
	}

	## Represents errors that can occur when connecting to a remote host.
	ConnectErr : [
		PermissionDenied,
		AddrInUse,
		AddrNotAvailable,
		ConnectionRefused,
		Interrupted,
		TimedOut,
		Unsupported,
		Unrecognized(Str),
	]

	## Represents errors that can occur when performing an effect with a `Stream`.
	StreamErr : [
		StreamNotFound,
		PermissionDenied,
		ConnectionRefused,
		ConnectionReset,
		Interrupted,
		TimedOut,
		OutOfMemory,
		BrokenPipe,
		Unrecognized(Str),
	]

	## Opens a TCP connection, waiting at most `timeout_ms` milliseconds across
	## all resolved addresses. The name lookup runs first and is not bounded —
	## it cannot be cancelled — so a slow resolver adds its own time. A zero
	## timeout fails immediately.
	##
	## ```roc
	## # Connect to localhost:8080
	## stream = Tcp.connect!("localhost", 8080, 5_000)?
	## ```
	##
	## Valid hostnames look like `127.0.0.1`, `::1`, `localhost`, or `roc-lang.org`.
	connect! : Str, U16, U64 => Try(Stream, [PermissionDenied, AddrInUse, AddrNotAvailable, ConnectionRefused, Interrupted, TimedOut, Unsupported, Unrecognized(Str), ..])
	connect! = |host, port, timeout_ms|
		NetHost.tcp_connect!(host, port, timeout_ms)
			.map_ok(|stream| Stream.{ host: stream })
			.map_err(connect_err)

	## Listens for TCP connections on `host` and `port`. Port 0 picks a free
	## port; `Listener.port!` says which.
	##
	## ```roc
	## listener = Tcp.listen!("127.0.0.1", 8080)?
	## stream = listener.accept!(5_000)?
	## ```
	listen! : Str, U16 => Try(Listener, [AddrInUse, AddrNotAvailable, PermissionDenied, Unrecognized(Str), ..])
	listen! = |host, port|
		NetHost.tcp_listen!(host, port)
			.map_ok(|listener| Listener.{ host: listener })
			.map_err(listen_err)

	## Convert a `ConnectErr` to a `Str` you can print.
	connect_err_to_str = |err|
		match err {
			PermissionDenied => "PermissionDenied"
			AddrInUse => "AddrInUse"
			AddrNotAvailable => "AddrNotAvailable"
			ConnectionRefused => "ConnectionRefused"
			Interrupted => "Interrupted"
			TimedOut => "TimedOut"
			Unsupported => "Unsupported"
			Unrecognized(message) => "Unrecognized Error: ${message}"
		}

	## Convert a `StreamErr` to a `Str` you can print.
	stream_err_to_str = |err|
		match err {
			StreamNotFound => "StreamNotFound"
			PermissionDenied => "PermissionDenied"
			ConnectionRefused => "ConnectionRefused"
			ConnectionReset => "ConnectionReset"
			Interrupted => "Interrupted"
			TimedOut => "TimedOut"
			OutOfMemory => "OutOfMemory"
			BrokenPipe => "BrokenPipe"
			Unrecognized(message) => "Unrecognized Error: ${message}"
		}
}

# ---- internal helpers (module-private) -----------------------------------------

## IOErr -> the ConnectErr / StreamErr variants basic-cli's Tcp reports.
##
## These replace two parsers that matched on "ErrorKind::…" strings NetHost
## never produced, so every error fell through to `Unrecognized` no matter what
## went wrong. Mapping from the type removes the possibility: an IOErr variant
## that gains a case here is a compile error if it is spelled wrong, which a
## string comparison never was.
##
## The five network conditions IOErr cannot express — ConnectionRefused,
## TimedOut, AddrInUse, AddrNotAvailable, ConnectionReset — now arrive as
## `Sockets.NetErr` and map straight across. `ConnectErr` has no
## ConnectionReset (a connect cannot be reset), so that one case is named
## rather than dropped.
##
## Both take an `IOErr` and are left unannotated so inference yields an OPEN
## union, which is what `connect!`'s signature requires — as the parsers they
## replace also were.
connect_err = |err|
	match err {
		ConnectionRefused => ConnectionRefused
		TimedOut => TimedOut
		AddrInUse => AddrInUse
		AddrNotAvailable => AddrNotAvailable
		ConnectionReset => Unrecognized("connection reset")
		Io(PermissionDenied) => PermissionDenied
		Io(Interrupted) => Interrupted
		Io(Unsupported) => Unsupported
		Io(other) => Unrecognized(IOErr.to_str(other))
	}

## `Sockets.NetErr` -> `listen!`'s tags. A bind reports an address in use or
## unavailable, or a privileged port; the rest cannot come from a bind, and are
## named rather than dropped, as `connect_err` names ConnectionReset.
listen_err = |err|
	match err {
		AddrInUse => AddrInUse
		AddrNotAvailable => AddrNotAvailable
		ConnectionRefused => Unrecognized("connection refused")
		ConnectionReset => Unrecognized("connection reset")
		TimedOut => Unrecognized("timed out")
		Io(PermissionDenied) => PermissionDenied
		Io(other) => Unrecognized(IOErr.to_str(other))
	}

## `Sockets.NetErr` -> `accept!`'s tags. The host retries an interrupted accept
## and one whose connection was abandoned before it was taken, so what reaches
## here is the deadline, a refusal (a Linux firewall rule answers EPERM), or
## running out of memory or descriptors — the last an `Unrecognized` message,
## since IOErr has no tag for it.
accept_err = |err|
	match err {
		TimedOut => TimedOut
		ConnectionRefused => Unrecognized("connection refused")
		ConnectionReset => Unrecognized("connection reset")
		AddrInUse => Unrecognized("address already in use")
		AddrNotAvailable => Unrecognized("address not available")
		Io(PermissionDenied) => PermissionDenied
		Io(OutOfMemory) => OutOfMemory
		Io(other) => Unrecognized(IOErr.to_str(other))
	}

## Takes a `Sockets.NetErr` now, not a bare `IOErr`. Reads used to arrive as
## `Io(IOErr)` because they came through `Streams.read!`, and `IOErr` has no
## way to say TimedOut or ConnectionReset — so a read timeout reached callers
## as `Unrecognized("Resource temporarily unavailable (os error 35)")` and a
## peer RST as `Unrecognized("Connection reset by peer")`, while the
## `TimedOut` and `ConnectionReset` variants right there in `StreamErr` were
## unreachable. Reading through the socket puts its own error type on the path.
stream_err = |err|
	match err {
		ConnectionRefused => ConnectionRefused
		ConnectionReset => ConnectionReset
		TimedOut => TimedOut
		AddrInUse => Unrecognized("address already in use")
		AddrNotAvailable => Unrecognized("address not available")
		Io(PermissionDenied) => PermissionDenied
		Io(Interrupted) => Interrupted
		Io(OutOfMemory) => OutOfMemory
		Io(BrokenPipe) => BrokenPipe
		Io(other) => Unrecognized(IOErr.to_str(other))
	}

## Fed what the code actually delivers, not a hand-written literal: the old
## expects checked the parsers against "ErrorKind::…" strings nothing produced,
## so they stayed green while the pipeline they guarded was broken.
expect connect_err(ConnectionRefused) == ConnectionRefused
expect connect_err(TimedOut) == TimedOut
expect connect_err(Io(PermissionDenied)) == PermissionDenied
expect stream_err(Io(BrokenPipe)) == BrokenPipe
expect stream_err(Io(NotFound)) == Unrecognized("entity was not found")
## The two that could not be produced before reads carried NetErr.
expect stream_err(TimedOut) == TimedOut
expect stream_err(ConnectionReset) == ConnectionReset
expect listen_err(AddrInUse) == AddrInUse
expect listen_err(Io(PermissionDenied)) == PermissionDenied
expect accept_err(TimedOut) == TimedOut
expect accept_err(Io(OutOfMemory)) == OutOfMemory
