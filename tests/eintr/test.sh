# A signal does not end a timed socket call early, or stretch its budget.
#
# Linux never restarts a socket call that has SO_RCVTIMEO/SO_SNDTIMEO: under
# ANY handler, SA_RESTART or not, the call returns EINTR. Measured on Linux 6.8
# (TCP recv, UDP recv, TCP send: EINTR at 0.70s of a 2s timeout, both flag
# settings). A terminal package's SIGWINCH handler turned every resize into
# `Interrupted` from Tcp and Udp. Measured against this test before the fix: a
# plain read and a UDP recv returned Interrupted at 1005ms, and read_line and
# the write returned TimedOut at 3006ms — std's `read_until` and `write_all`
# retried with the FULL timeout, and a send that has moved bytes returns their
# count rather than EINTR, so the next send started a fresh timeout. Each
# operation here must time out at its whole budget, not before and not well
# after, with the signal delivered during it.
#
# Both passes, without and with SA_RESTART, run on every platform. macOS
# restarts a call waiting under SO_RCVTIMEO with a fresh timeout when the
# handler has SA_RESTART (2.71s for a 2s budget), so the host now waits in
# `poll`, which a signal ends on both platforms whatever the flags.
source ../lib.sh
peer ../timeouts/deaf.py DEAF_PORT
readonly BUDGET_MS=2000
# An over-budget retry restarts the full timeout at 1000ms and ends near 3000.
readonly OVERRUN_MS=2800
make_world "$TMP/app" "$DEPS"
sed "s/@@DEAF@@/$DEAF_PORT/g" app.roc > "$TMP/app.roc"
build_app "$TMP/app" "$TMP/app.roc" eintr
rows=$(capped 120 "$(bin "$TMP/app" eintr)" 2>&1) || { echo "FAIL: the eintr app did not finish — $rows"; exit 1; }
python3 - "$rows" "$BUDGET_MS" "$OVERRUN_MS" 8 <<'EOF'
import sys
rows, budget, overrun, want = sys.argv[1].splitlines(), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
bad = []
for row in rows:
    name, outcome, ms, delivered = row.split("|")
    if delivered != "1":
        bad.append(f"{name}: {delivered} signals delivered, want 1 — the check proves nothing")
    elif outcome != "TimedOut":
        bad.append(f"{name}: {outcome} after {ms}ms, want TimedOut")
    elif not budget <= int(ms) < overrun:
        bad.append(f"{name}: TimedOut after {ms}ms, want {budget}..{overrun}ms")
if len(rows) != want:
    bad.append(f"{len(rows)} rows, want {want}:\n" + "\n".join(rows))
if bad:
    print("FAIL: a signal changed a timed socket call\n  " + "\n  ".join(bad)); sys.exit(1)
EOF
echo "ok: a signal mid-call leaves tcp read, read_until, write and udp recv at their full budget, handler with and without SA_RESTART"
