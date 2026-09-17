# UDP is bounded too, and a stream op on a listener says so.
#
# `Udp.recv!` had no timeout of any kind — for a protocol with no delivery
# guarantee, "possibly never". And a stream read on a LISTENER used to return
# `Ok(len=0)`, which reads as a clean end of stream. A script rather than an app
# suite because the time bound is the claim: a stdout diff would hang, not fail.
source ../lib.sh
make_world "$TMP/app" "$DEPS"
build_app "$TMP/app" app.roc udptmo
start=$(now)
uout=$(capped 60 "$(bin "$TMP/app" udptmo)" 2>&1) || { echo "FAIL: the udp timeout app did not finish — $uout"; exit 1; }
elapsed=$(python3 -c "import time; print('%.1f' % (time.time() - $start))")
[[ "$uout" == "2 TimedOut TimedOut Unsupported" ]] || {
	echo "FAIL: udp outcomes were '$uout', want '2 TimedOut TimedOut Unsupported' (delivered wait zero listener-read)"; exit 1; }
python3 -c "import sys; sys.exit(0 if $elapsed < 15 else 1)" || {
	echo "FAIL: the udp app took ${elapsed}s — recv! is not bounded by its budget"; exit 1; }
echo "ok: a datagram arrives whole, a missing one times out, and a stream read on a listener is Unsupported"
