app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.Clocks
import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Tcp

nanos_per_ms : U64
nanos_per_ms = 1000000

## Long enough to tell a bounded wait from an immediate return.
accept_budget_ms : U64
accept_budget_ms = 200

read_budget_ms : U64
read_budget_ms = 300

## Generous: every step here is loopback, and a hang is the failure.
step_ms : U64
step_ms = 2000

## Runs `op!` and says how long it took, in milliseconds.
timed! : ({} => Str) => (Str, U64)
timed! = |op!| {
	start = Clocks.monotonic_now!({})
	outcome = op!({})
	(outcome, (Clocks.monotonic_now!({}) - start) // nanos_per_ms)
}

## A listener accepts within its budget, and what it accepts is a Stream.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	listener = Tcp.listen!("127.0.0.1", 0) ? |_| ListenFailed
	port = listener.port!()
	in_use = match Tcp.listen!("127.0.0.1", port) {
		Ok(_) => "Ok"
		Err(AddrInUse) => "AddrInUse"
		Err(other) => Str.inspect(other)
	}

	# Nobody connects: the accept must give up at its budget, not before.
	(idle, idle_ms) = timed!(|{}| accepted(listener.accept!(accept_budget_ms)))

	# The backlog completes the connect before anything accepts it. A zero
	# budget still fails at once, and leaves the connection for the next accept.
	client = Tcp.connect!("127.0.0.1", port, step_ms) ? |_| ConnectFailed
	(zero, zero_ms) = timed!(|{}| accepted(listener.accept!(0)))
	server = listener.accept!(step_ms) ? |_| AcceptFailed

	client.write_utf8!("ping", step_ms) ? |_| ClientWriteFailed
	to_server = read(server.read_exactly!(4, step_ms))
	server.write_utf8!("pong", step_ms) ? |_| ServerWriteFailed
	to_client = read(client.read_exactly!(4, step_ms))

	# The client sends nothing more for now: a read on the accepted stream is
	# bounded. The client is written to afterwards, which also keeps it open
	# through the wait — dropped, it would close, and the read would see the
	# end of the stream instead.
	(silent, silent_ms) = timed!(|{}| read(server.read_up_to!(4, read_budget_ms)))
	client.write_utf8!("late", step_ms) ? |_| ClientWriteFailed
	after_silent = read(server.read_exactly!(4, step_ms))

	fields = [in_use, idle, Str.inspect(idle_ms), zero, Str.inspect(zero_ms), to_server, to_client, silent, Str.inspect(silent_ms), after_silent]
	Stdout.line!(Str.join_with(fields.map(|f| "[${f}]"), " "))
}

accepted : Try(Tcp.Stream, _) -> Str
accepted = |r| match r {
	Ok(_) => "Ok"
	Err(TimedOut) => "TimedOut"
	Err(other) => Str.inspect(other)
}

read : Try(List(U8), _) -> Str
read = |r| match r {
	Ok(bytes) => Str.from_utf8_lossy(bytes)
	Err(TcpReadErr(TimedOut)) => "TimedOut"
	Err(other) => Str.inspect(other)
}
