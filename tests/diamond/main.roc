app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Udp
import pf.Sockets

## A net error and a stdout error propagated out of one function with `?`.
## This did not type until net-lib's unions were opened the way stdio-lib's
## always were — so it is the check, not just a demo.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	sock = Udp.bind!("127.0.0.1", 0)?
	port = Udp.local_port!(sock)
	Stdout.line!(if port > 0 { "bound" } else { "no port" })?
	Ok({})
}
