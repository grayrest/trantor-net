# trantor-net

Sockets and a blocking HTTP client for
[trantor](http://github.com/grayrest/trantor).

## Use it

An add-on over a baseline — it provides no driver, and its own modules import
the baseline's `Host`, `IOErr` and `Url`, so name both:

```toml
# world.toml
[world]
name = "myapp"

[deps]
trantor-cli = { path = "../trantor-cli" }
trantor-net = { path = "../trantor-net" }
```

## Example

```roc
import pf.Http
import pf.Tcp
import pf.Url

url = Url.parse("http://localhost:8000/") ? |_| BadUrl
page = Http.get_utf8!(url)?                  # the whole body, as UTF-8

stream = Tcp.connect!("localhost", 7, 5_000)?
stream.write_utf8!("hello\n", 5_000)?
line = stream.read_line!(1024, 5_000)?       # "hello\n" from an echo server
```

## roc:sync-sockets and roc:sync-http

The WASI-derived layer. `Sockets` carries TCP and UDP together, as
`wasi:sockets` groups them, with `tcp_`/`udp_` prefixes doing the separating.
`HttpHost` is one leaf — `send!` — shaped after
`wasi:http/outgoing-handler`.

The HTTP response body is a `Streams.InputStream`, the same refcounted resource
files, sockets and stdin produce: `send!` returns once the final headers
arrive, and body-phase failures surface on read rather than as a send error.
`read_body!` names them as a `BodyErr`: `TimedOut` when the body stalls past the
request's timeout, `EndedEarly` when the connection closes or is reset before
the body ends, and `Io(IOErr)` for anything else, corrupt compressed data
among it. Reading the same stream with `Streams.read!` still gives `IOErr`.

### Sockets

`NetErr` holds the five network conditions `IOErr` has no tag for; every other
failure is `Io(IOErr)`.

```roc
TcpSocket :: Box(U64)
UdpSocket :: Box(U64)
IpAddress : [V4(U8, U8, U8, U8), V6(U16, U16, U16, U16, U16, U16, U16, U16)]
NetErr : [ConnectionRefused, ConnectionReset, TimedOut, AddrInUse, AddrNotAvailable, Io(IOErr)]

# names
Sockets.resolve! : Str => Try(List(IpAddress), NetErr)

# tcp: connecting
Sockets.tcp_connect! : Str, U16, U64 => Try(TcpSocket, NetErr)          # timeout ms, across every address; starts after the name lookup
Sockets.tcp_listen! : Str, U16 => Try(TcpSocket, NetErr)                # port 0 picks a free port
Sockets.tcp_accept! : TcpSocket, U64 => Try(TcpSocket, NetErr)          # timeout ms; TimedOut when it passes
Sockets.tcp_local_port! : TcpSocket => U16

# tcp: reading and writing
Sockets.tcp_read! : TcpSocket, U64 => Try(List(U8), NetErr)             # up to max; empty is end of stream
Sockets.tcp_read_until! : TcpSocket, U8, U64 => Try(List(U8), NetErr)   # through the delimiter, at most max
Sockets.tcp_read_exactly! : TcpSocket, U64 => Try(List(U8), NetErr)     # exactly n, or fewer at end of stream
Sockets.tcp_unread! : TcpSocket, List(U8) => {}                         # put bytes back in front of the next read
Sockets.tcp_write! : TcpSocket, List(U8) => Try({}, NetErr)
Sockets.tcp_set_read_timeout! : TcpSocket, U64 => {}                    # ms; 0 is no timeout
Sockets.tcp_set_write_timeout! : TcpSocket, U64 => {}                   # ms; 0 is no timeout

# udp
Sockets.udp_bind! : Str, U16 => Try(UdpSocket, NetErr)
Sockets.udp_local_port! : UdpSocket => U16
Sockets.udp_send_to! : UdpSocket, Str, U16, List(U8) => Try(U64, NetErr)
Sockets.udp_recv! : UdpSocket, U64 => Try({ bytes : List(U8), from_host : Str, from_port : U16 }, NetErr)   # one datagram, up to max
Sockets.udp_set_read_timeout! : UdpSocket, U64 => {}                    # ms; 0 is no timeout
```

### HttpHost

```roc
Request : { method : U8, method_ext : Str, headers : List((Str, Str)), uri : Str,
            body : List(U8), timeout_ms : U64 }
Response : { status : U16, headers_flat : List(U8), body_stream : Streams.InputStream }   # headers_flat is name\0value\0…
TransportErr : [Timeout, NetworkError, BadBody, Other(List(U8))]
BodyErr : [TimedOut, EndedEarly, Io(IOErr)]

HttpHost.send! : Request => Try(Response, TransportErr)
HttpHost.read_body! : Streams.InputStream, U64 => Try(List(U8), BodyErr)   # up to max; empty is the end
```

`BadBody` is a malformed response; a request the client refuses to send is
`Other` with its reason.

## Tcp, Udp, Http

The `basic-cli` shim over them, with basic-cli's own error names
(`ConnectErr`, `BindErr`, `RecvErr`, …). `Http.to_http_response!` bridges into
`roc-lang/http`'s `Response`.

### Tcp

Every timeout is in milliseconds and covers the whole operation. A zero timeout
fails at once. A timeout is `TimedOut` inside `TcpReadErr` or `TcpWriteErr`, and
a bare `TimedOut` from `connect!` or `accept!`.

basic-cli's Tcp has no server side; `listen!` and `Listener` are trantor's. An
accepted connection is an ordinary `Stream`. A server that waits indefinitely
loops on `accept!`'s `TimedOut`, which is also where it checks for shutdown.

```roc
Stream :: { host : NetHost.TcpStream }                  # closed when the last reference drops
Listener :: { host : NetHost.TcpListener }              # closed when the last reference drops
NetHost.TcpStream : Sockets.TcpSocket
NetHost.TcpListener : Sockets.TcpSocket
ConnectErr : [PermissionDenied, AddrInUse, AddrNotAvailable, ConnectionRefused, Interrupted,
              TimedOut, Unsupported, Unrecognized(Str)]
StreamErr : [StreamNotFound, PermissionDenied, ConnectionRefused, ConnectionReset, Interrupted,
             TimedOut, OutOfMemory, BrokenPipe, Unrecognized(Str)]

# connecting
Tcp.connect! : Str, U16, U64 => Try(Stream, [PermissionDenied, AddrInUse, AddrNotAvailable, ConnectionRefused, Interrupted, TimedOut, Unsupported, Unrecognized(Str), ..])

# listening
Tcp.listen! : Str, U16 => Try(Listener, [AddrInUse, AddrNotAvailable, PermissionDenied, Unrecognized(Str), ..])   # port 0 picks a free port
accept! : Listener, U64 => Try(Stream, [TimedOut, PermissionDenied, OutOfMemory, Unrecognized(Str), ..])
port! : Listener => U16

# reading: the last argument is the timeout
read_up_to! : Stream, U64, U64 => Try(List(U8), [TcpReadErr(StreamErr), ..])
read_exactly! : Stream, U64, U64 => Try(List(U8), [TcpUnexpectedEOF, TcpReadErr(StreamErr), ..])
read_until! : Stream, U8, U64, U64 => Try(List(U8), [TcpReadLimitExceeded(U64), TcpReadErr(StreamErr), ..])   # delimiter included
read_line! : Stream, U64, U64 => Try(Str, [TcpReadBadUtf8(_), TcpReadLimitExceeded(U64), TcpReadErr(StreamErr), ..])   # "\n" included

# writing
write! : Stream, List(U8), U64 => Try({}, [TcpWriteErr(StreamErr), ..])
write_utf8! : Stream, Str, U64 => Try({}, [TcpWriteErr(StreamErr), ..])

# rendering
to_inspect : Stream -> Str                              # "Tcp.Stream(<opaque>)"
to_inspect : Listener -> Str                            # "Tcp.Listener(<opaque>)"
Tcp.connect_err_to_str : ConnectErr -> Str
Tcp.stream_err_to_str : StreamErr -> Str
```

`Tcp.connect!` returns `ConnectErr`'s tags in an open union rather than
`ConnectErr` itself; `listen!` and `accept!` have no named union. The two
`_to_str` functions carry no annotation in the source; the types shown are the
unions their matches cover.

### Udp

```roc
Socket : Sockets.UdpSocket

Udp.bind! : Str, U16 => Try(Socket, [BindErr(Sockets.NetErr), ..])
Udp.local_port! : Socket => U16
Udp.send_to! : Socket, Str, U16, List(U8) => Try(U64, [SendErr(Sockets.NetErr), ..])
Udp.recv! : Socket, U64, U64 => Try({ bytes : List(U8), from_host : Str, from_port : U16 }, [RecvErr(Sockets.NetErr), ..])   # max bytes, timeout ms; 0 fails at once
```

### Http

`Request` and `Header` are `roc-lang/http`'s; `Url` is the baseline's. `send!`
needs an absolute `http` or `https` URL, and drops the fragment before sending.

A body that cannot be read to its end is `BodyErr(Http.BodyErr)`: `TimedOut`
when it stalls past the request's timeout, `EndedEarly` when the connection
closes or is reset first (a `Content-Length` not reached, a chunked stream cut
short), and `Io(IOErr)` for any other failure, corrupt compressed data among
them.

```roc
Response : { status : U16, headers : List(Header.Header), body : Streams.InputStream }
TransportErr : InternalHttp.TransportErr
BodyErr : [TimedOut, EndedEarly, Io(IOErr)]
InternalHttp.TransportErr : [Timeout, NetworkError, BadBody, Other(List(U8))]
InternalHttp.HttpResponse : Response.Response           # roc-lang/http's eager Response

# sending
Http.send! : Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])   # returns at the headers
Http.send_json! : Request, _ => Try(Response, [JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
Http.with_json_body : Request, _ => Try(Request, [JsonErr(_), ..])                              # sets Content-Type

# reading the body
Http.read_body_to_end! : Response => Try(List(U8), [BodyErr(BodyErr), ..])                     # a cut-off body is BodyErr
Http.to_http_response! : Response => Try(InternalHttp.HttpResponse, [BodyErr(BodyErr), ..])
Http.decode_json_response! : Response => Try(_, [BadBody(Str), BodyErr(BodyErr), JsonErr(_), ..])

# GET
Http.get_utf8! : Url.Url => Try(Str, [BadBody(Str), BodyErr(BodyErr), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
Http.get! : Url.Url => Try(_, [BadBody(Str), BodyErr(BodyErr), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_), ..])   # decodes JSON
```

## TempTest

Test scaffolding, not API: the local HTTP server the package's tests talk to,
and a signal that interrupts a blocked socket call. Its host is `test_only`, so
a published baseline leaves it out.

```roc
TempTest.start_test_server! : {} => {}
TempTest.interrupt_after! : U64, Bool => {}     # SIGUSR1 after ms; the Bool installs it with SA_RESTART
TempTest.take_interrupts! : {} => U64           # deliveries since the last call; resets the count
```

## Known limitations

On Linux, suspending a program with Ctrl-Z and resuming it with `fg` while an
HTTP request is waiting on the server fails that request. The kernel interrupts
a socket read that has a timeout when the process resumes, whether or not any
signal handler is installed, and ureq 3.4.0, the HTTP client under `Http`, does
not retry it. Waiting for the response headers, `send!` returns
`HttpErr(NetworkError)`; reading the body, the read fails. Sending the request
again works. `Tcp` and `Udp` retry within their timeout and are not affected.
