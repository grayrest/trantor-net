import IOErr exposing [IOErr]
## roc:sync-sockets: WASI's socket surface in blocking form (P6/P7/P12).
## Sockets are resources (P5); reads go through the socket's own buffer and
## writes through a sync-io stream. Addresses are host:port pairs (name lookup
## is `resolve!`).
Sockets :: [].{
	TcpSocket :: Box(U64)
	UdpSocket :: Box(U64)
	IpAddress : [V4(U8, U8, U8, U8), V6(U16, U16, U16, U16, U16, U16, U16, U16)]

	## What a socket operation can fail with.
	##
	## The five network conditions are here rather than in `IOErr` because
	## `IOErr` cannot express them — it has no ConnectionRefused, and a host
	## mapping ErrorKind onto it has nowhere to put one but `Other(message)`.
	## That is how a refused connection used to reach callers as an
	## unrecognised string. Everything else a socket call can hit is an
	## ordinary I/O failure and stays `Io(IOErr)`.
	NetErr : [
		ConnectionRefused,
		ConnectionReset,
		TimedOut,
		AddrInUse,
		AddrNotAvailable,
		Io(IOErr),
	]
	## ip-name-lookup: every address a name resolves to.
	resolve! : Str => Try(List(IpAddress), NetErr)
	## tcp-create-socket + connect, in one blocking step, waiting at most
	## `timeout_ms` across every address the name resolves to. The lookup
	## itself runs first and is not bounded: it cannot be cancelled, so a slow
	## resolver adds its own time.
	##
	## The timeout used to be applied AFTERWARDS, as the socket's read timeout,
	## so the connect itself was unbounded: a 500ms budget against a full accept
	## queue returned after 8.05s, when the OS gave up.
	tcp_connect! : Str, U16, U64 => Try(TcpSocket, NetErr)
	## tcp-create-socket + bind + listen; port 0 picks a free port.
	tcp_listen! : Str, U16 => Try(TcpSocket, NetErr)
	## The next connection on a listener, waiting at most `timeout_ms`; the
	## deadline passing is `TimedOut`. It used to take no timeout and block
	## until a peer connected, so a server could not stop waiting for one. As
	## with the other budgets, the caller rejects zero before it gets here.
	tcp_accept! : TcpSocket, U64 => Try(TcpSocket, NetErr)
	## Up to `max` bytes from the socket's own buffer; empty list = end of
	## stream. There is no `tcp_input!` any more: minting a stream resource per
	## read meant the buffer inside it died with the hosted call that owned it,
	## taking everything read past the request with it.
	tcp_read! : TcpSocket, U64 => Try(List(U8), NetErr)
	## Up to and including the next `delim`, at most `max` bytes. One hosted
	## call against the persistent buffer — the line reader `read_until` is for.
	tcp_read_until! : TcpSocket, U8, U64 => Try(List(U8), NetErr)
	## Exactly `n` bytes under one read timeout, or fewer at end of stream. A
	## read that fails part way keeps what it took, for the next read: it used
	## to be dropped, and the stream then read on misaligned.
	tcp_read_exactly! : TcpSocket, U64 => Try(List(U8), NetErr)
	## Put bytes a read returned back in front of the next read, for a caller
	## that decides after the fact that the read failed.
	tcp_unread! : TcpSocket, List(U8) => {}
	## Writes go through the socket for the same reason reads do: `Streams.write!`
	## crosses as `Io(IOErr)`, and `IOErr` has no way to say TimedOut, so the
	## `TcpWriteErr(TimedOut)` Tcp.roc documents was unreachable.
	tcp_write! : TcpSocket, List(U8) => Try({}, NetErr)
	## Blocking-model stand-in for pollable timeouts. A zero here means "no
	## timeout" at the socket; the caller is responsible for rejecting a zero
	## budget before it gets this far (see NetHost).
	tcp_set_read_timeout! : TcpSocket, U64 => {}
	tcp_set_write_timeout! : TcpSocket, U64 => {}
	## UDP had no timeout leaf at all, so `Udp.recv!` could block forever with
	## no way to bound it — the one socket operation the timeout work left
	## unbounded.
	udp_set_read_timeout! : UdpSocket, U64 => {}
	tcp_local_port! : TcpSocket => U16
	udp_bind! : Str, U16 => Try(UdpSocket, NetErr)
	udp_send_to! : UdpSocket, Str, U16, List(U8) => Try(U64, NetErr)
	## One datagram (up to `max` bytes) and its sender.
	udp_recv! : UdpSocket, U64 => Try({ bytes : List(U8), from_host : Str, from_port : U16 }, NetErr)
	udp_local_port! : UdpSocket => U16
}
