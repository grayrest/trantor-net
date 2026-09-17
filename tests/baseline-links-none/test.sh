# A baseline-only app links none of this package: a program that never opens a
# socket should not carry rustls, which is the reason for the split.
source ../lib.sh
make_world "$TMP/app" "$DEV_DEPS"
build_app "$TMP/app" app.roc a
A="$TMP/app/target/trantor/app/platform/targets/arm64mac"
n=$(ls "$A" | wc -l | tr -d ' ')
[[ "$n" -gt 0 ]] || { echo "FAIL: no archives staged, the count below would be vacuous"; exit 1; }
for bad in libsockets_host.a libhttp_host.a libtestnet_host.a; do
	[[ -f "$A/$bad" ]] && { echo "FAIL: $bad linked into a baseline-only app"; exit 1; }
done
echo "ok: a baseline-only app stages $n archive(s), none of the network's"
