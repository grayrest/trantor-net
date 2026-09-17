# A read that times out part way keeps what it read, and a read is bounded by
# its whole budget however the peer paces its bytes.
#
# Both reads that loop took bytes off the socket's buffer and dropped them with
# the timeout: a peer sending "abc", then "def|rest" after the read gave up,
# made the next read_until! return "def|", with "abc" gone and the stream still
# readable but misaligned. And read_exactly! was a Roc loop of reads, each with
# a fresh budget, so a peer sending a byte every 300ms held a 500ms read open
# for 5.8s. read_up_to! must take from what a failed read kept, and a stream
# ending short keeps its bytes too (D-S2-55). A limit reached without the
# delimiter consumes them, as basic-cli does: kept, a loop that skips over-long
# lines retried the same bytes forever.
source ../lib.sh
peer trickle.py PORT
make_world "$TMP/app" "$DEPS"
sed "s/@@PORT@@/$PORT/g" app.roc > "$TMP/app.roc"
build_app "$TMP/app" "$TMP/app.roc" partial
got=$(capped 60 "$(bin "$TMP/app" partial)" 2>&1) || { echo "FAIL: the partial-read app did not finish — $got"; exit 1; }
# Fields are bracketed so an empty one cannot shift the rest.
unbracket() { sed 's/^\[//; s/\]$//' <<<"$1"; }
read -r until_first until_second exactly_first exactly_second up_to_first up_to_second up_to_third limited after_limit short after_short trickled ms <<<"$got"
for v in until_first until_second exactly_first exactly_second up_to_first up_to_second up_to_third limited after_limit short after_short trickled ms; do
	printf -v "$v" '%s' "$(unbracket "${!v}")"
done
[[ "$until_first" == TimedOut && "$until_second" == "abcdef|" ]] || { echo "FAIL: read_until! across a timeout gave '$until_first' then '$until_second', want TimedOut then 'abcdef|'"; exit 1; }
[[ "$exactly_first" == TimedOut && "$exactly_second" == "abcdef|" ]] || { echo "FAIL: read_exactly! across a timeout gave '$exactly_first' then '$exactly_second', want TimedOut then 'abcdef|'"; exit 1; }
[[ "$up_to_first" == TimedOut && "$up_to_second" == ab && "$up_to_third" == "cdef|" ]] || { echo "FAIL: read_up_to! after a timed-out read gave '$up_to_second' then '$up_to_third', want 'ab' then 'cdef|'"; exit 1; }
[[ "$limited" == LimitExceeded && "$after_limit" == "defgh|" ]] || { echo "FAIL: a limit without the delimiter gave '$limited' then '$after_limit', want LimitExceeded then 'defgh|' (its bytes consumed, as basic-cli does)"; exit 1; }
[[ "$short" == UnexpectedEOF && "$after_short" == xyz ]] || { echo "FAIL: a stream ending short gave '$short' then '$after_short', want UnexpectedEOF then 'xyz'"; exit 1; }
[[ "$trickled" == TimedOut ]] || { echo "FAIL: a trickled read_exactly! gave '$trickled', want TimedOut"; exit 1; }
(( ms < 1500 )) || { echo "FAIL: a 500ms read_exactly! against a trickling peer took ${ms}ms"; exit 1; }
echo "ok: a timed-out read keeps what it took, and a trickled read gives up at its budget (${ms}ms)"
