app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }
import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Tcp

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	s = Tcp.connect!("127.0.0.1", @@PORT@@, 5000) ? |_| ConnectFailed
	# The peer sent 8 bytes in ONE send; take them in two halves. The second
	# half is only there if the first read kept what it did not return.
	a = s.read_exactly!(4, 5000) ? |_| ReadA
	b = s.read_exactly!(4, 5000) ? |_| ReadB
	# And a delimiter read, which used to consume a byte at a time.
	s.write_utf8!("until|", 5000) ? |_| WriteFailed
	u = s.read_until!(124, 64, 5000) ? |_| ReadUntilFailed
	Stdout.line!("${Str.from_utf8_lossy(a)}/${Str.from_utf8_lossy(b)}/${Str.from_utf8_lossy(u)}")
}
