app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Tcp
import pf.Clocks

nanos_per_ms : U64
nanos_per_ms = 1000000

## A read that times out part way keeps what it took, and a whole read is
## bounded by its budget however the peer paces its bytes.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# Split, through read_until!: "abc", a timeout, then "def|" arrives.
	a = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	a.write!(Str.to_utf8("S"), 5000) ? |_| WriteFailed
	until_first = outcome(a.read_until!(124, 64, 400))
	until_second = outcome(a.read_until!(124, 64, 3000))

	# Split, through read_exactly!: the same shape.
	b = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	b.write!(Str.to_utf8("S"), 5000) ? |_| WriteFailed
	exactly_first = outcome(b.read_exactly!(6, 400))
	exactly_second = outcome(b.read_exactly!(7, 3000))

	# Split, through read_up_to!: what a timed-out read_until! took comes first.
	u = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	u.write!(Str.to_utf8("S"), 5000) ? |_| WriteFailed
	up_to_first = outcome(u.read_until!(124, 64, 400))
	up_to_second = outcome(u.read_up_to!(2, 3000))
	up_to_third = outcome(u.read_until!(124, 64, 3000))

	# A limit reached without the delimiter consumes what it read, as basic-cli
	# does, so a loop skipping over-long lines moves on.
	l = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	l.write!(Str.to_utf8("L"), 5000) ? |_| WriteFailed
	limited = outcome(l.read_until!(124, 3, 3000))
	after_limit = outcome(l.read_until!(124, 64, 3000))

	# A stream that ends short keeps what arrived.
	e = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	e.write!(Str.to_utf8("E"), 5000) ? |_| WriteFailed
	short = outcome(e.read_exactly!(10, 3000))
	after_short = outcome(e.read_up_to!(10, 3000))

	# Trickle: a 500ms read_exactly! of 20 bytes must give up near 500ms.
	c = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	c.write!(Str.to_utf8("T"), 5000) ? |_| WriteFailed
	start = Clocks.monotonic_now!({})
	trickled = outcome(c.read_exactly!(20, 500))
	ms = (Clocks.monotonic_now!({}) - start) // nanos_per_ms

	# Each field in brackets: an empty read must not shift the later ones.
	fields = [until_first, until_second, exactly_first, exactly_second, up_to_first, up_to_second, up_to_third, limited, after_limit, short, after_short, trickled, Str.inspect(ms)]
	Stdout.line!(Str.join_with(fields.map(|f| "[${f}]"), " "))
}

outcome : Try(List(U8), _) -> Str
outcome = |r| match r {
	Ok(bytes) => Str.from_utf8_lossy(bytes)
	Err(TcpReadErr(TimedOut)) => "TimedOut"
	Err(TcpReadLimitExceeded(_)) => "LimitExceeded"
	Err(TcpUnexpectedEOF) => "UnexpectedEOF"
	Err(other) => Str.inspect(other)
}
