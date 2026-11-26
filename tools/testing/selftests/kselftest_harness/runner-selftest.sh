#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

src=$(dirname "$(readlink -f "$0")")
if [ -r "$src/run_kselftest.sh" ]; then
	runner="$src/run_kselftest.sh"
	helpers="$src"
else
	runner="$src/../run_kselftest.sh"
	helpers="$src/../kselftest"
fi

. "$helpers/ktap_helpers.sh"

ktap_print_header
if ! command -v bash >/dev/null; then
	ktap_skip_all 'Bash is required by the network namespace runner'
	exit "$KSFT_SKIP"
fi

work=$(mktemp -d) || ktap_exit_fail_msg 'Could not create temporary directory'
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

suite="$work/install"
mock="$work/bin"
state="$work/state"
tap="$work/tap"
errors="$work/stderr"
mkdir -p "$suite/kselftest" "$suite/alpha" "$suite/omega" "$mock" "$state" ||
	ktap_exit_fail_msg 'Could not prepare runner fixture directories'
cp "$runner" "$suite/run_kselftest.sh" || ktap_exit_fail_msg 'Could not copy the runner'
cp "$helpers/runner.sh" "$helpers/ktap_helpers.sh" "$helpers/prefix.pl" "$suite/kselftest/" ||
	ktap_exit_fail_msg 'Could not copy runner helpers'

# Give the runner an unprivileged stand-in for namespace setup and entry.
cat > "$mock/ip" <<'EOF'
#!/bin/sh
case "$1 $2" in
	'netns add') operation=add; ns="$3" ;;
	'netns del') operation=del; ns="$3" ;;
	'netns exec') operation=exec; ns="$3" ;;
	'-n '*) operation=link; ns="$2" ;;
	*) exit 1 ;;
esac

if [ "$operation" = "${KSFT_MOCK_FAIL:-}" ]; then
	echo "mock ip $operation failed" >&2
	exit 1
fi

case "$operation" in
	add) mkdir "$KSFT_MOCK_STATE/$ns" ;;
	del) rmdir "$KSFT_MOCK_STATE/$ns" ;;
	link) [ -d "$KSFT_MOCK_STATE/$ns" ] && [ "$3 $4 $5 $6" = 'link set lo up' ] ;;
	exec)
		[ -d "$KSFT_MOCK_STATE/$ns" ] || exit 1
		shift 3
		KSFT_MOCK_NAMESPACE="$ns" exec "$@"
		;;
esac
EOF
chmod +x "$mock/ip"

cat > "$work/fixture" <<'EOF'
#!/bin/sh
name=${0##*/}
printf 'fixture %s\n' "$name"
if [ "${KSFT_CHECK_PARALLEL:-}" = yes ]; then
	[ -n "${KSFT_MOCK_NAMESPACE:-}" ] || exit 1
	case "$name" in
		first.sh)
			# Wait for a later fixture to prove they execute concurrently.
			attempt=0
			while [ ! -f "$KSFT_MOCK_STATE/second-started" ] &&
			      [ "$attempt" -lt 100 ]; do
				sleep 0.05
				attempt=$((attempt + 1))
			done
			[ -f "$KSFT_MOCK_STATE/second-started" ] || exit 1
			;;
		skip.sh) touch "$KSFT_MOCK_STATE/second-started" ;;
	esac
fi

case "$name" in
	first.sh) exit 0 ;;
	skip.sh) exit 4 ;;
	xfail.sh) exit 2 ;;
	fail.sh) exit 1 ;;
esac
EOF

cat > "$suite/kselftest-list.txt" <<'EOF'
alpha:first.sh
alpha:skip.sh
alpha:xfail.sh
omega:fail.sh
EOF
while IFS=: read -r collection test; do
	install -m 755 "$work/fixture" "$suite/$collection/$test" ||
		ktap_exit_fail_msg "Could not install fixture $test"
done < "$suite/kselftest-list.txt"

cat > "$work/expected" <<'EOF'
ok 1 selftests: alpha: first.sh
ok 2 selftests: alpha: skip.sh # SKIP
ok 3 selftests: alpha: xfail.sh # XFAIL
not ok 4 selftests: omega: fail.sh # exit=1
EOF

export PATH="$mock:$PATH"
export KSFT_MOCK_STATE="$state"

run_runner()
{
	local shell="$1"
	shift
	rm -f "$state/second-started"
	# The runner also appends diagnostic writes through /dev/stdout.
	: > "$tap"
	"$shell" "$suite/run_kselftest.sh" "$@" >> "$tap" 2> "$errors"
}

check_results()
{
	grep -E '^(not )?ok ' "$tap" > "$work/results"
	grep -Fxq '1..4' "$tap" && diff -u "$work/expected" "$work/results" &&
		grep -Fxq '# Totals: pass:1 fail:1 xfail:1 xpass:0 skip:1 error:0' "$tap"
}

check_diagnostics()
{
	local test
	for test in first.sh skip.sh xfail.sh fail.sh; do
		grep -Fxq "# fixture $test" "$tap" || return 1
	done
}

check_sequential()
{
	run_runner sh
	[ "$?" -eq "$KSFT_FAIL" ] && check_results && check_diagnostics
}

check_parallel()
{
	KSFT_CHECK_PARALLEL=yes run_runner "$1" --netns
	[ "$?" -eq "$KSFT_FAIL" ] && check_results && check_diagnostics &&
		[ -f "$state/second-started" ]
}

check_per_test_logs()
{
	local logdir="$work/test logs" test
	run_runner sh --netns --no-error-on-fail --per-test-log "$logdir"
	[ "$?" -eq "$KSFT_PASS" ] && check_results || return 1
	for test in first.sh skip.sh xfail.sh fail.sh; do
		grep -Fxq "# fixture $test" "$logdir/$test" || return 1
	done
}

check_setup_failure()
{
	local operation="$1" message="$2"
	KSFT_MOCK_FAIL="$operation" run_runner sh --netns --test alpha:first.sh
	[ "$?" -eq "$KSFT_FAIL" ] &&
		grep -Fxq "not ok 1 selftests: alpha: first.sh # $message" "$tap" &&
		grep -Fxq "mock ip $operation failed" "$errors" &&
		! grep -Fq 'mock ip' "$tap" && ! grep -Fq 'fixture first.sh' "$tap"
}

check_cleanup()
{
	[ -z "$(find "$state" -mindepth 1 -type d)" ]
}

run_case()
{
	local name="$1"
	shift
	if "$@"; then
		ktap_test_pass "$name"
	else
		sed 's/^/# /' "$tap" "$errors"
		ktap_test_fail "$name"
	fi
}

ktap_set_plan 8
run_case 'sequential results' check_sequential
run_case 'parallel results and diagnostics in sh' check_parallel sh
run_case 'parallel results and diagnostics in Bash' check_parallel bash
run_case 'parallel per-test logs and failure override' check_per_test_logs
run_case 'namespace creation failure' check_setup_failure add 'Create NS failed'
run_case 'namespace loopback failure' check_setup_failure link 'Set up NS loopback failed'
run_case 'namespace entry failure' check_setup_failure exec 'Enter NS failed'
ktap_test_result 'network namespaces were cleaned up' check_cleanup
ktap_finished
