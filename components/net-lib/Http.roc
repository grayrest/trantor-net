import IOErr exposing [IOErr]
import NetHost
import InternalHttp
import Url
import http.Request
import http.Header
import Streams

## Send requests using the shared
## [`roc-lang/http`](https://github.com/roc-lang/http) `Request` type. The
## response is streaming (H5): `send!` returns as soon as the headers arrive and
## the body is a `Streams.InputStream`. `read_body_to_end!` collects it;
## `to_http_response!` bridges to the eager roc-lang/http `Response` for interop.
Http :: [].{

	## Errors raised by the host while sending a request, before a real HTTP
	## response is available.
	TransportErr : InternalHttp.TransportErr

	## Why a response body could not be read to its end: it stalled past the
	## request's timeout, or the connection closed or was reset before the body
	## ended (a `Content-Length` not reached, a chunked stream cut short). These
	## used to be `BodyErr(IOErr)`, and `IOErr` has no way to say either: both
	## arrived as `Other(message)`. A reset is not told apart from an early
	## close because the HTTP library underneath reports them identically.
	BodyErr : [TimedOut, EndedEarly, Io(IOErr)]

	## How long `get!` and `get_utf8!` wait in each phase before giving up:
	## connecting, sending the request, receiving the response headers, and
	## receiving the body, each timed from the end of the one before. So a slow
	## server can take several times this in all, but no single wait is longer. They build the request themselves, and a
	## request with no timeout waits forever: against a server that accepts and
	## never answers, still blocked at 30 seconds. Build a `Request` with
	## `send!` to choose another, or `NoTimeout`.
	default_timeout_ms : U64
	default_timeout_ms = 30_000

	## A streaming HTTP response: status + headers are available immediately, the
	## body is read from `body` on demand (files/sockets/stdin share this
	## InputStream substrate).
	Response : { status : U16, headers : List(Header.Header), body : Streams.InputStream }

	## Validate and send an HTTP request; the response body streams.
	##
	## The request URI must be an absolute HTTP or HTTPS URL accepted by Url.
	## Invalid URLs return InvalidUrl before any host effect occurs. Fragments
	## are removed because they are client-side identifiers and are not sent.
	##
	## ```roc
	## request = Request.from_method(GET).with_uri("https://www.roc-lang.org")
	## response = Http.send!(request)?
	## body = Http.read_body_to_end!(response)
	## ```
	send! : Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send! = |request| {
		url = Url.parse(Request.uri(request)) ? InvalidUrl
		canonical_url = Url.without_fragment(url)
		canonical_request = request.with_uri(Url.to_str(canonical_url))
		host_response = NetHost.http_send_request!(InternalHttp.to_host_request(canonical_request)) ? HttpErr

		Ok(
			{
				status: host_response.status,
				headers: InternalHttp.from_host_headers(host_response.headers),
				body: host_response.body_stream,
			},
		)
	}

	## Collect a streaming response body to end (the "I want the whole thing"
	## helper).
	##
	## A mid-stream failure is an ERROR, not a short body. This used to end the
	## read with whatever had arrived and return it as `List(U8)` — a type with
	## nowhere to say otherwise — so a server declaring `Content-Length: 1000`
	## and sending 10 bytes, or a chunked stream cut before its terminator, was
	## indistinguishable from a complete response. The host reports the
	## truncation (H15: body-phase failures surface as `Io(IOErr)` on read);
	## only this function was throwing it away.
	read_body_to_end! : Response => Try(List(U8), [BodyErr(BodyErr), ..])
	read_body_to_end! = |response| collect_stream!(response.body, [])

	## Bridge a streaming response into the eager roc-lang/http `Response` for
	## interop with code that expects that shared type (reads the whole body).
	to_http_response! : Response => Try(InternalHttp.HttpResponse, [BodyErr(BodyErr), ..])
	to_http_response! = |response| {
		body = read_body_to_end!(response)?
		Ok(InternalHttp.to_http_response(response.status, response.headers, body))
	}

	## Encode a value as JSON and set it as the request body.
	##
	## This uses Roc's builtin JSON encoder, so the value's type determines the
	## encoder through static dispatch.
	with_json_body : Request, _ => Try(Request, [JsonErr(_), ..])
	with_json_body = |request, value| {
		body = Json.to_str_try(value) ? JsonErr

		Ok(
			request
				.add_header("Content-Type", "application/json")
				.with_body(Str.to_utf8(body)),
		)
	}

	## Encode a value as JSON, attach it to the request body, and send it.
	send_json! : Request, _ => Try(Response, [JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send_json! = |request, value| {
		json_request = with_json_body(request, value)?

		send!(json_request)
	}

	## A GET for `url` under `default_timeout_ms`.
	default_get : Url.Url -> Request
	default_get = |url| Request.from_method(GET).with_uri(Url.to_str(url)).with_timeout(TimeoutMilliseconds(Http.default_timeout_ms))

	## Perform an HTTP GET and decode the response body as a UTF-8 `Str`,
	## waiting at most `default_timeout_ms` in each phase.
	##
	## The argument is a validated Url. Quoted literals work through
	## Url.from_quote; dynamic strings should be passed through Url.parse.
	##
	## ```roc
	## hello_str = Http.get_utf8!("http://localhost:8000")?
	## ```
	get_utf8! : Url.Url => Try(Str, [BadBody(Str), BodyErr(BodyErr), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	get_utf8! = |url| {
		response = send!(Http.default_get(url))?
		bytes = read_body_to_end!(response)?
		body = Str.from_utf8(bytes) ? |_| BadBody("get_utf8!: response body was not valid UTF-8")

		Ok(body)
	}

	## Decode a response body as JSON.
	##
	## This uses Roc's builtin JSON parser, so the expected result type
	## determines the parser through static dispatch.
	decode_json_response! : Response => Try(_, [BadBody(Str), BodyErr(BodyErr), JsonErr(_), ..])
	decode_json_response! = |response| {
		bytes = read_body_to_end!(response)?
		body = Str.from_utf8(bytes) ? |_| BadBody("decode_json_response: response body was not valid UTF-8")
		decoded = Json.parse(body) ? JsonErr

		Ok(decoded)
	}

	## Perform an HTTP GET and decode the response body as JSON, waiting at
	## most `default_timeout_ms` in each phase.
	##
	## The argument is a validated Url. JSON parser failures are returned as
	## JsonErr(_).
	##
	## ```roc
	## payload : Try({ foo : Str }, _)
	## payload = Http.get!("http://localhost:8000")
	## ```
	get! : Url.Url => Try(_, [BadBody(Str), BodyErr(BodyErr), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_), ..])
	get! = |url| {
		response = send!(Http.default_get(url))?

		decode_json_response!(response)
	}
}

## Drain a streaming InputStream to end. Threads the stream so Roc re-incs it
## before each `read!` (owned per call), dropping it at a base case —
## drop-balanced. An empty read is the end; a read ERROR is a truncated body
## and is reported, not swallowed.
collect_stream! : Streams.InputStream, List(U8) => Try(List(U8), [BodyErr(Http.BodyErr), ..])
collect_stream! = |stream, acc| {
	match NetHost.http_read_body!(stream, 65536) {
		Ok(chunk) => if List.is_empty(chunk) { Ok(acc) } else { collect_stream!(stream, List.concat(acc, chunk)) }
		Err(TimedOut) => Err(BodyErr(TimedOut))
		Err(EndedEarly) => Err(BodyErr(EndedEarly))
		Err(Io(e)) => Err(BodyErr(Io(e)))
	}
}

## `get!` and `get_utf8!` carry the default, rather than no timeout at all.
expect {
	url = Url.parse("http://127.0.0.1:1/") ?? crash("a literal URL parses")
	Request.timeout(Http.default_get(url)) == TimeoutMilliseconds(Http.default_timeout_ms)
}
