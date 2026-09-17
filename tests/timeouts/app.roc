app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Tcp

conn! : U16, U64 => Try(Str, _)
conn! = |port, ms|
	match Tcp.connect!("127.0.0.1", port, ms) {
		Ok(_) => Ok("Ok")
		Err(TimedOut) => Ok("TimedOut")
		Err(other) => Ok(Str.inspect(other))
	}

write_loop! : Tcp.Stream, List(U8), U64 => Try({}, _)
write_loop! = |s, chunk, left|
	if left == 0 { Ok({}) } else {
		s.write!(chunk, 1000)?
		write_loop!(s, chunk, left - 1)
	}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	zero_conn = conn!(@@DEAF@@, 0)?          # zero budget: immediate, not infinite
	slow_conn = conn!(@@BACKLOG@@, 500)?     # budget must bound the CONNECT
	s = Tcp.connect!("127.0.0.1", @@DEAF@@, 2000) ? |_| ConnectFailed
	zero_read = match s.read_up_to!(4, 0) {
		Ok(_) => "Ok"
		Err(TcpReadErr(TimedOut)) => "TimedOut"
		Err(_) => "other"
	}
	# 4MB at a peer that accepts and never reads: the socket buffers fill and
	# the write has to give up on its own budget.
	wrote = match write_loop!(s, List.repeat(65, 262144), 16) {
		Ok({}) => "Ok"
		Err(TcpWriteErr(TimedOut)) => "TimedOut"
		Err(TcpWriteErr(other)) => Str.inspect(other)
	}
	Stdout.line!("${zero_conn} ${slow_conn} ${zero_read} ${wrote}")
}
