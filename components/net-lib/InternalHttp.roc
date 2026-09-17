import http.Header
import http.Method
import http.Request
import http.Response
import Streams

## Define host-ABI HTTP types and convert them to/from the shared HTTP package
## types. The response body is a streaming `Streams.InputStream` (H5): the host
## crossing carries the stream, and `Http` builds its streaming `Response` from
## it (so `from_host_response` no longer collects into a roc-lang/http Response).
InternalHttp :: [].{

	## Errors raised by the host while sending a request, before a real HTTP
	## response is available.
	TransportErr : [Timeout, NetworkError, BadBody, Other(List(U8))]

	# Generated Rust glue uses tuple headers at the host ABI boundary.
	HostHeaderTuple : (Str, Str)

	RequestToAndFromHost : {
		method : U8,
		method_ext : Str,
		headers : List(HostHeaderTuple),
		uri : Str,
		body : List(U8),
		timeout_ms : U64,
	}

	ResponseToAndFromHost : {
		status : U16,
		headers : List(HostHeaderTuple),
		body_stream : Streams.InputStream,
	}

	to_host_request : Request -> RequestToAndFromHost
	to_host_request = |request| {
		method = Request.method(request)
		{
			method: to_host_method(method),
			method_ext: to_host_method_ext(method),
			headers: to_host_headers(Request.headers(request)),
			uri: Request.uri(request),
			body: Request.body(request),
			timeout_ms: to_host_timeout(Request.timeout(request)),
		}
	}

	to_host_headers : List(Header.Header) -> List(HostHeaderTuple)
	to_host_headers = |headers|
		headers.map(|{ name, value }| (name, value))

	from_host_headers : List(HostHeaderTuple) -> List(Header.Header)
	from_host_headers = |headers|
		headers.map(|(name, value)| { name, value })

	## The eager roc-lang/http `Response`. Http's streaming `Response` names a
	## different local type, so the bridge that builds this shared type lives
	## here (where `Response` resolves to the http package, not the local type).
	HttpResponse : Response.Response

	to_http_response : U16, List(Header.Header), List(U8) -> HttpResponse
	to_http_response = |status, headers, body|
		Response.from_status(status)
			.with_headers(headers)
			.with_body(body)
}

to_host_method : Method.Method -> U8
to_host_method = |method|
	match method {
		OPTIONS => 5
		GET => 3
		POST => 7
		PUT => 8
		DELETE => 1
		HEAD => 4
		TRACE => 9
		CONNECT => 0
		PATCH => 6
		QUERY => 2
		Unknown(_) => 2
	}

to_host_method_ext : Method.Method -> Str
to_host_method_ext = |method|
	match method {
		QUERY => "QUERY"
		Unknown(ext) => ext
		_ => ""
	}

to_host_timeout : [TimeoutMilliseconds(U64), NoTimeout] -> U64
to_host_timeout = |timeout|
	match timeout {
		TimeoutMilliseconds(ms) => ms
		NoTimeout => 0
	}
