app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }
import pf.OsStr
import pf.Stdout
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Stdout.line!("no net")?
	Ok({})
}
