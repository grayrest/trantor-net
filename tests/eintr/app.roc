app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.Clocks
import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Tcp
import pf.TempTest
import pf.Udp

## Every operation's whole budget. The signal lands halfway through it.
budget_ms : U64
budget_ms = 2000

interrupt_at_ms : U64
interrupt_at_ms = 1000

## Bigger than a loopback socket's send buffer can grow to, so the write is
## still blocked when the signal arrives.
write_bytes : U64
write_bytes = 32 * 1024 * 1024

nanos_per_ms : U64
nanos_per_ms = 1000000

## One row: `name|outcome|elapsed_ms|signals_delivered`.
timed! : Str, Bool, ({} => Str) => Str
timed! = |name, restart, op!| {
	TempTest.interrupt_after!(interrupt_at_ms, restart)
	start = Clocks.monotonic_now!({})
	outcome = op!({})
	elapsed_ms = (Clocks.monotonic_now!({}) - start) // nanos_per_ms
	delivered = TempTest.take_interrupts!({})
	"${name}|${outcome}|${Str.inspect(elapsed_ms)}|${Str.inspect(delivered)}"
}

pass! : Str, Bool => Try({}, _)
pass! = |label, restart| {
	reader = Tcp.connect!("127.0.0.1", @@DEAF@@, budget_ms) ? |_| ConnectFailed
	liner = Tcp.connect!("127.0.0.1", @@DEAF@@, budget_ms) ? |_| ConnectFailed
	writer = Tcp.connect!("127.0.0.1", @@DEAF@@, budget_ms) ? |_| ConnectFailed
	udp = Udp.bind!("127.0.0.1", 0) ? |_| BindFailed
	payload = List.repeat(65, write_bytes)

	rows = [
		timed!("${label}tcp-read", restart, |_| match reader.read_up_to!(4, budget_ms) {
			Ok(_) => "Ok"
			Err(TcpReadErr(TimedOut)) => "TimedOut"
			Err(other) => Str.inspect(other)
		}),
		timed!("${label}tcp-read-until", restart, |_| match liner.read_line!(64, budget_ms) {
			Ok(_) => "Ok"
			Err(TcpReadErr(TimedOut)) => "TimedOut"
			Err(other) => Str.inspect(other)
		}),
		timed!("${label}udp-recv", restart, |_| match Udp.recv!(udp, 1024, budget_ms) {
			Ok(_) => "Ok"
			Err(RecvErr(TimedOut)) => "TimedOut"
			Err(other) => Str.inspect(other)
		}),
		timed!("${label}tcp-write", restart, |_| match writer.write!(payload, budget_ms) {
			Ok(_) => "Ok"
			Err(TcpWriteErr(TimedOut)) => "TimedOut"
			Err(other) => Str.inspect(other)
		}),
	]
	Stdout.line!(Str.join_with(rows, "\n"))
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	pass!("", Bool.False)?
	# The pass macOS failed while the host waited under SO_RCVTIMEO: the kernel
	# restarted the call with a fresh timeout.
	pass!("restart:", Bool.True)
}
