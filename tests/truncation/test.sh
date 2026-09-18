# A truncated response body is an error, not a short body.
#
# `collect_stream!` ended on a read failure and returned what had arrived,
# through a `List(U8)` that had nowhere to say otherwise — so a server declaring
# `Content-Length: 1000` and sending 10 bytes, or a chunked stream cut before its
# terminator, was indistinguishable from a complete response. A COMPLETE response
# is asserted too: without it, a version that failed every body read would pass.
#
# The failures are named. `IOErr` has no timeout or reset, so a stalled body, a
# connection closed early and a reset all used to arrive as `Io(Other(msg))`,
# told apart only by the message text. A gzip body, ureq's default, wraps the
# disconnect once more, and was still `Io` until that was unwrapped too — but a
# gzip stream truncated inside a body that arrived whole is bad data, not an
# early end, and stays `Io`. And headers trickling in a byte at a time must
# still time out: without a send timeout ureq renewed the deadline per byte.
#
# The same server echoes the verb it received: ureq refuses a method it does not
# know unless told otherwise, so QUERY and `Unknown(ext)` were never sent, and
# its refusal — like any request the client will not send, such as a body
# longer than its Content-Length — was reported as `BadBody`, a fault in the
# response.
source ../lib.sh
peer badsrv.py BPORT
make_world "$TMP/app" "$DEPS"
sed "s/@@BPORT@@/$BPORT/" app.roc > "$TMP/app.roc"
build_app "$TMP/app" "$TMP/app.roc" trunc
tout=$(capped 60 "$(bin "$TMP/app" trunc)" 2>&1) || { echo "FAIL: the truncation app did not run — $tout"; exit 1; }
want="Ok(complete) EndedEarly EndedEarly TimedOut EndedEarly EndedEarly Io Timeout@bounded QUERY PURGE Other"
[[ "$tout" == "$want" ]] || { echo "FAIL: body outcomes were '$tout', want '$want' (complete lie chunk stall reset gzip-cut-short gzip-truncated-in-a-whole-body headers-trickled query-verb unknown-verb body-over-content-length)"; exit 1; }
echo "ok: a complete body reads, and a lying Content-Length, a cut chunked stream, a stall and a reset are errors named for what happened; QUERY and Unknown verbs go out, and a request the client refuses is Other"
