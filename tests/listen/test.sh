# A listener's accept is bounded, and what it accepts is an ordinary Stream.
#
# `Sockets.tcp_accept!` took no timeout and blocked until a peer connected, so a
# server could not stop waiting to notice a shutdown. Tcp had no listening side
# at all. The accept must give up at its budget and not before; a zero budget
# fails at once even with a connection waiting; and the accepted connection
# carries bytes both ways and bounds its reads like any other Stream. A script
# rather than an app suite because the time bounds are the claim: a stdout diff
# would hang, not fail.
source ../lib.sh
readonly ACCEPT_BUDGET_MS=200
readonly READ_BUDGET_MS=300
# Far above either budget, far below a hang.
readonly CEILING_MS=2000
# A zero budget that reaches the socket still returns in well under this.
readonly IMMEDIATE_MS=50
make_world "$TMP/app" "$DEPS"
build_app "$TMP/app" app.roc listen
got=$(capped 60 "$(bin "$TMP/app" listen)" 2>&1) || { echo "FAIL: the listen app did not finish — $got"; exit 1; }
read -r in_use idle idle_ms zero zero_ms to_server to_client silent silent_ms after_silent <<<"$got"
for v in in_use idle idle_ms zero zero_ms to_server to_client silent silent_ms after_silent; do
	printf -v "$v" '%s' "$(sed 's/^\[//; s/\]$//' <<<"${!v}")"
done
[[ "$in_use" == AddrInUse ]] || { echo "FAIL: listening twice on one port gave '$in_use', want AddrInUse"; exit 1; }
[[ "$idle" == TimedOut ]] || { echo "FAIL: an accept nobody connects to gave '$idle', want TimedOut"; exit 1; }
(( idle_ms >= ACCEPT_BUDGET_MS && idle_ms < CEILING_MS )) || {
	echo "FAIL: a ${ACCEPT_BUDGET_MS}ms accept returned after ${idle_ms}ms, want at least its budget and under ${CEILING_MS}ms"; exit 1; }
[[ "$zero" == TimedOut ]] || { echo "FAIL: a zero-budget accept with a connection waiting gave '$zero', want TimedOut"; exit 1; }
(( zero_ms < IMMEDIATE_MS )) || { echo "FAIL: a zero-budget accept took ${zero_ms}ms"; exit 1; }
[[ "$to_server" == ping && "$to_client" == pong ]] || {
	echo "FAIL: across an accepted stream the server read '$to_server' and the client '$to_client', want ping and pong"; exit 1; }
[[ "$silent" == TimedOut ]] || { echo "FAIL: a read on an accepted stream with nothing sent gave '$silent', want TimedOut"; exit 1; }
(( silent_ms >= READ_BUDGET_MS && silent_ms < CEILING_MS )) || {
	echo "FAIL: a ${READ_BUDGET_MS}ms read on an accepted stream returned after ${silent_ms}ms"; exit 1; }
[[ "$after_silent" == late ]] || { echo "FAIL: after a timed-out read the accepted stream read '$after_silent', want late"; exit 1; }
echo "ok: accept gives up at its budget (${idle_ms}ms), zero fails at once, and an accepted stream round-trips and bounds its reads (${silent_ms}ms)"
