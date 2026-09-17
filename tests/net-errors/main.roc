app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Tcp
import pf.Sockets

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	refused = match Tcp.connect!("127.0.0.1", 1, 1_000) {
		Ok(_) => "connected"
		Err(e) => Tcp.connect_err_to_str(e)
	}
	inuse = match Sockets.tcp_listen!("127.0.0.1", 0) {
		Err(_) => "listen failed"
		Ok(l) => {
			port = Sockets.tcp_local_port!(l)
			result = match Sockets.tcp_listen!("127.0.0.1", port) {
				Ok(_) => "listened twice"
				Err(AddrInUse) => "AddrInUse"
				Err(_) => "not AddrInUse"
			}
			# The first listener must outlive the second bind, or its resource
			# is dropped and the port is free again.
			_ = Sockets.tcp_local_port!(l)
			result
		}
	}
	Stdout.line!("${refused} ${inuse}")?
	Ok({})
}
