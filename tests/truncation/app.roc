app [main!] { pf: platform "../target/trantor/app/platform/main.roc", http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Http
import pf.Url
import pf.Clocks
import http.Request

outcome! : Str => Try(Str, _)
outcome! = |path| {
	u = Url.parse("http://127.0.0.1:@@BPORT@@${path}") ? |_| BadUrl
	match Http.get_utf8!(u) {
		Ok(s) => Ok(if Str.count_utf8_bytes(s) > 20 { "Ok(long)" } else { "Ok(${s})" })
		Err(BodyErr(kind)) => Ok(named(kind))
		Err(_) => Ok("other")
	}
}

## A body that stalls past a short explicit timeout.
stalled! : () => Try(Str, _)
stalled! = || {
	request = Request.from_method(GET).with_uri("http://127.0.0.1:@@BPORT@@/stall").with_timeout(TimeoutMilliseconds(500))
	match Http.send!(request) {
		Ok(response) => match Http.read_body_to_end!(response) {
			Ok(_) => Ok("Ok")
			Err(BodyErr(kind)) => Ok(named(kind))
			Err(_) => Ok("other")
		}
		Err(_) => Ok("send-failed")
	}
}

## Headers that trickle in a byte at a time must still time out near the bound.
trickled_headers! : () => Try(Str, _)
trickled_headers! = || {
	request = Request.from_method(GET).with_uri("http://127.0.0.1:@@BPORT@@/tricklehead").with_timeout(TimeoutMilliseconds(500))
	start = Clocks.monotonic_now!({})
	result = match Http.send!(request) {
		Ok(_) => "Ok"
		Err(HttpErr(Timeout)) => "Timeout"
		Err(_) => "other"
	}
	ms = (Clocks.monotonic_now!({}) - start) // 1_000_000
	Ok("${result}@${if ms < 3000 { "bounded" } else { "unbounded:${Str.inspect(ms)}" }}")
}

## The verb the server saw. ureq refuses a method it does not know unless told
## otherwise, and QUERY and `Unknown(ext)` never left the process.
sent_verb! = |method| {
	request = Request.from_method(method).with_uri("http://127.0.0.1:@@BPORT@@/verb")
	match Http.send!(request) {
		Ok(response) => match Http.read_body_to_end!(response) {
			Ok(bytes) => Ok(Str.from_utf8(bytes) ?? "bad-utf8")
			Err(_) => Ok("body-failed")
		}
		Err(HttpErr(BadBody)) => Ok("BadBody")
		Err(_) => Ok("other")
	}
}

## How a request the client will not send is reported. It is not a bad
## response body, and says why.
refusal! = |request| {
	match Http.send!(request) {
		Ok(_) => Ok("Ok")
		Err(HttpErr(Other(message))) => Ok("Other(${Str.from_utf8(message) ?? "bad-utf8"})")
		Err(HttpErr(BadBody)) => Ok("BadBody")
		Err(_) => Ok("other")
	}
}

## The verbs /verb received. A request refused before it is sent must not be
## among them.
seen! = || {
	match Http.get_utf8!(Url.parse("http://127.0.0.1:@@BPORT@@/seen") ? |_| BadUrl) {
		Ok(s) => Ok(s)
		Err(_) => Ok("seen-failed")
	}
}

named : Http.BodyErr -> Str
named = |kind| match kind {
	TimedOut => "TimedOut"
	EndedEarly => "EndedEarly"
	Io(_) => "Io"
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	ok = outcome!("/ok")?
	lie = outcome!("/lie")?
	chunk = outcome!("/chunk")?
	stall = stalled!()?
	reset = outcome!("/reset")?
	gzlie = outcome!("/gzlie")?
	gztrunc = outcome!("/gztrunc")?
	headers = trickled_headers!()?
	query = sent_verb!(QUERY)?
	purge = sent_verb!(Unknown("PURGE"))?
	Stdout.line!("${ok} ${lie} ${chunk} ${stall} ${reset} ${gzlie} ${gztrunc} ${headers} ${query} ${purge}")?
	verb = "http://127.0.0.1:@@BPORT@@/verb"
	refusals = [
		# `Unknown` shared QUERY's method code, so an empty verb went out as QUERY.
		Request.from_method(Unknown("")).with_uri(verb),
		Request.from_method(Unknown("GET /x")).with_uri(verb),
		Request.from_method(Unknown("GET\r\nX: y")).with_uri(verb),
		Request.from_method(GET).with_uri(verb).add_header("Host", "a.example").add_header("Host", "b.example"),
		Request.from_method(GET).with_uri(verb).add_header("Host", "caf\u(e9).example"),
		Request.from_method(GET).with_uri(verb).add_header("Authorization", "Basic caf\u(e9)"),
		# Refused while the body is written, after the request line has gone,
		# so not to /verb.
		Request.from_method(POST).with_uri("http://127.0.0.1:@@BPORT@@/ok").add_header("Content-Length", "1").with_body([104, 101, 108, 108, 111]),
	]
	for request in refusals {
		Stdout.line!(refusal!(request)?)?
	}
	Stdout.line!("seen: ${seen!()?}")
}
