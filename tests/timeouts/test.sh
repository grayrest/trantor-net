# Timeouts exist and bound what they name.
#
# Three defects, all invisible to a gate that never waited on anything:
# `connect!` applied its budget AFTERWARDS as the socket's read timeout, so the
# connect itself was unbounded (500ms budget, 8.01s to return, measured against
# this same saturated listener); `write!` had no write-timeout leaf, so a write
# to a peer that accepts and never reads blocked forever; and a ZERO budget
# disabled the timeout instead of failing immediately.
source ../lib.sh
peer deaf.py DEAF_PORT
peer backlog.py BL_PORT
# The saturated listener must actually be saturated, or the connect check proves
# nothing. Asserted rather than assumed.
python3 saturated.py "$BL_PORT" || { echo "FAIL: could not saturate the listener — the connect-timeout check cannot run here"; exit 1; }
make_world "$TMP/app" "$DEPS"
sed "s/@@DEAF@@/$DEAF_PORT/g; s/@@BACKLOG@@/$BL_PORT/g" app.roc > "$TMP/app.roc"
build_app "$TMP/app" "$TMP/app.roc" tmo
start=$(now)
tmo=$(capped 90 "$(bin "$TMP/app" tmo)" 2>&1) || { echo "FAIL: the timeout app did not finish — $tmo"; exit 1; }
elapsed=$(python3 -c "import time; print('%.1f' % (time.time() - $start))")
[[ "$tmo" == "TimedOut TimedOut TimedOut TimedOut" ]] || {
	echo "FAIL: timeout outcomes were '$tmo', want 'TimedOut TimedOut TimedOut TimedOut' (connect0 connect500 read0 write)"; exit 1; }
# Every budget is at most 2s, so the run is seconds. Unbounded, the connect alone
# took 8s and the write never returned.
python3 -c "import sys; sys.exit(0 if $elapsed < 20 else 1)" || {
	echo "FAIL: the timeout app took ${elapsed}s — a budget is not bounding its operation"; exit 1; }
echo "ok: a zero budget fails at once, and connect and write are bounded by theirs (${elapsed}s)"
