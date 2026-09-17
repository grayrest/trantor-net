import IOErr exposing [IOErr]
import Sockets
## Udp: thin blocking sugar over roc:sync-sockets/udp (no basic-cli precedent).
##
## Every error union here is OPEN. A closed one cannot be carried out of a
## function alongside another module's error — an app doing `Udp.bind!(…)?` and
## `Stdout.line!(…)?` could not type — and stdio-lib has widened for exactly
## that reason since it was written.
##
## The payloads carry `Sockets.NetErr`, not `IOErr`: binding a port already in
## use is `AddrInUse`, which IOErr has no way to say. Udp has no basic-cli
## precedent to hold its shape fixed.
Udp :: [].{
	Socket : Sockets.UdpSocket
	bind! : Str, U16 => Try(Socket, [BindErr(Sockets.NetErr), ..])
	bind! = |host, port| Sockets.udp_bind!(host, port).map_err(|e| BindErr(e))
	local_port! : Socket => U16
	local_port! = |s| Sockets.udp_local_port!(s)
	send_to! : Socket, Str, U16, List(U8) => Try(U64, [SendErr(Sockets.NetErr), ..])
	send_to! = |s, host, port, bytes| Sockets.udp_send_to!(s, host, port, bytes).map_err(|e| SendErr(e))
	## Waits at most `timeout_ms` for a datagram. A zero budget fails
	## immediately, as everywhere else in this package.
	##
	## There was no timeout here at all: `recv!` blocked until something
	## arrived, which for a protocol with no delivery guarantee could be never.
	## A datagram longer than `max` is cut to `max` bytes, and nothing says so:
	## ask for the largest datagram the protocol can send.
	recv! : Socket, U64, U64 => Try({ bytes : List(U8), from_host : Str, from_port : U16 }, [RecvErr(Sockets.NetErr), ..])
	recv! = |s, max, timeout_ms|
		if timeout_ms == 0 {
			Err(RecvErr(TimedOut))
		} else {
			Sockets.udp_set_read_timeout!(s, timeout_ms)
			Sockets.udp_recv!(s, max).map_err(|e| RecvErr(e))
		}
}
