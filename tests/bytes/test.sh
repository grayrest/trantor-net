# Bytes actually cross, and arrive whole.
#
# Nothing in the old gate moved a byte over a socket until this: it bound, it
# grepped for symbols, it failed a connect and a bind. So a defect that broke
# EVERY read was invisible — reads minted a stream resource per call, the hosted
# call owned it and released it on return, and the buffer inside died with
# whatever it had read past the request. `read_until!` could not succeed against
# any live peer. The peer sends a burst larger than one read and then echoes,
# which is the shape that exposes it: a second read has to find what the first
# left.
source ../lib.sh
peer peer.py PORT
make_world "$TMP/app" "$DEPS"
# The port is only known at run time and this compiler has no Str->U16, so it is
# substituted into the source rather than read from the environment.
sed "s/@@PORT@@/$PORT/" app.roc > "$TMP/app.roc"
build_app "$TMP/app" "$TMP/app.roc" bytes
got=$(capped 30 "$(bin "$TMP/app" bytes)" 2>&1) || { echo "FAIL: the byte-moving app did not run — $got"; exit 1; }
[[ "$got" == "ABCD/EFGH/until|" ]] || { echo "FAIL: bytes did not arrive whole — got '$got', want 'ABCD/EFGH/until|'"; exit 1; }
echo "ok: a burst survives two reads and a delimiter read returns the whole token"
