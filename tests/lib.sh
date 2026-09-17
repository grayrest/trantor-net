# Shared by the tests/*/test.sh suites. `trantor test` hands each script
# TRANTOR, ROC, PKG, TMP, DEPS (the package and its dev-deps) and DEV_DEPS.
# bash 3.2 compatible: macOS's /bin/bash fails on an empty array under set -u.
set -euo pipefail

# make_world DIR DEPS_BODY — DIR must be named `app`: trantor stages a world
# under target/trantor/<its directory name>, and an app's header says
# ../target/trantor/app/platform/main.roc.
make_world() {
	mkdir -p "$1/app"
	printf '[world]\nname = "app"\n\n[deps]\n%s' "$2" > "$1/world.toml"
}

# build_app WORLD SOURCE OUT — build SOURCE as bin/OUT, showing why on failure.
build_app() {
	cp "$2" "$1/app/main.roc"
	local out
	if ! out=$("$TRANTOR" build "$1" --app app --out "$3" 2>&1); then
		echo "FAIL: build $3" >&2; echo "$out" | tail -20 >&2; exit 1
	fi
}

bin() { echo "$1/target/trantor/app/bin/$2"; }

# capped SECONDS CMD... — a hung socket op fails the suite instead of hanging it.
capped() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

# peer SCRIPT VAR — start a python peer that prints its port, and set VAR to
# that port. Not `PORT=$(peer x.py)`: a command substitution is a subshell, and
# a peer started there outlived the suite.
#
# A watcher ends the peer when the suite's shell exits. Not an EXIT trap: bash
# 3.2 runs one with $? = 0 after a `set -u` error and exits with the trap's
# status, so a suite that failed that way passed.
peer() {
	local portfile="$TMP/$(basename "$1").port"
	python3 "$1" > "$portfile" 2> "$portfile.err" &
	# $$ is the outermost shell even in a subshell; a child's parent is the
	# shell actually running the suite, and bash 3.2 has no $BASHPID.
	local pid=$! suite
	suite=$(exec sh -c 'echo $PPID')
	( while kill -0 "$suite" 2>/dev/null; do sleep 0.2; done; kill "$pid" 2>/dev/null ) > /dev/null 2>&1 &
	for _ in $(seq 1 80); do [[ -s "$portfile" ]] && break; sleep 0.1; done
	[[ -s "$portfile" ]] || { echo "FAIL: $(basename "$1") never reported a port" >&2; cat "$portfile.err" >&2; exit 1; }
	printf -v "$2" '%s' "$(head -1 "$portfile")"
}

now() { python3 -c 'import time; print(time.time())'; }
