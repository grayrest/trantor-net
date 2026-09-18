app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Udp
import pf.Sockets

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	sock = Udp.bind!("127.0.0.1", 0) ? |_| BindFailed
	port = Udp.local_port!(sock)
	_n = Udp.send_to!(sock, "127.0.0.1", port, [104, 105]) ? |_| SendFailed
	# a datagram that arrives still arrives, whole
	delivered = match Udp.recv!(sock, 1024, 2000) {
		Ok(d) => if List.len(d.bytes) == 2 { "2" } else { "wrong-length" }
		Err(_) => "failed"
	}
	# nothing more will come: the budget must end it
	waited = match Udp.recv!(sock, 1024, 400) {
		Ok(_) => "Ok"
		Err(RecvErr(TimedOut)) => "TimedOut"
		Err(_) => "other"
	}
	zero = match Udp.recv!(sock, 1024, 0) {
		Ok(_) => "Ok"
		Err(RecvErr(TimedOut)) => "TimedOut"
		Err(_) => "other"
	}
	# `localhost` resolves to 127.0.0.1 first on macOS, which an IPv6 socket
	# cannot send to: the send must take the name's IPv6 address instead
	six = Udp.bind!("::1", 0) ? |_| BindSixFailed
	by_name = match Udp.send_to!(six, "localhost", Udp.local_port!(six), [104, 105]) {
		Ok(_) => match Udp.recv!(six, 1024, 2000) {
			Ok(d) => if List.len(d.bytes) == 2 { "by-name" } else { "wrong-length" }
			Err(_) => "lost"
		}
		Err(_) => "send-failed"
	}
	l = Sockets.tcp_listen!("127.0.0.1", 0) ? |_| ListenFailed
	lread = match Sockets.tcp_read!(l, 8) {
		Ok(_) => "Ok"
		Err(Io(Unsupported)) => "Unsupported"
		Err(_) => "other"
	}
	Stdout.line!("${delivered} ${waited} ${zero} ${lread} ${by_name}")
}
