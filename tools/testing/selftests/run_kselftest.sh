#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Run installed kselftest tests.
#

BASE_DIR=$(cd "$(dirname "$0")" && pwd -P)

cd $BASE_DIR
TESTS="$BASE_DIR"/kselftest-list.txt
if [ ! -r "$TESTS" ] ; then
	echo "$0: Could not find list of tests to run ($TESTS)" >&2
	available=""
else
	available="$(cat "$TESTS")"
fi

. ./kselftest/runner.sh

usage()
{
	cat <<EOF
Usage: $0 [OPTIONS]
  -s | --summary		Print summary with detailed log in output.log (conflict with -p)
  -p | --per-test-log [DIR]	Print test log in /tmp or DIR with each test name (conflict with -s)
  -t | --test COLLECTION:TEST	Run TEST from COLLECTION
  -S | --skip COLLECTION:TEST	Skip TEST from COLLECTION
  -c | --collection COLLECTION	Run all tests from COLLECTION
  -l | --list			List the available collection:test entries
  -d | --dry-run		Don't actually run any tests
  -f | --no-error-on-fail	Don't exit with an error just because tests failed
  -n | --netns			Run each test in namespace
  -h | --help			Show this usage info
  -o | --override-timeout	Number of seconds after which we timeout
EOF
	exit $1
}

COLLECTIONS=""
TESTS=""
SKIP=""
dryrun=""
kselftest_override_timeout=""
ERROR_ON_FAIL=true
while true; do
	case "$1" in
		-s | --summary)
			logfile="$BASE_DIR"/output.log
			cat /dev/null > $logfile
			shift ;;
		-p | --per-test-log)
			per_test_logging=1
			if [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
				per_test_log_dir="$2"
				if [ -e "$per_test_log_dir" ] && [ ! -d "$per_test_log_dir" ]; then
					echo "Per-test log path is not a dir:" \
					     "$per_test_log_dir" >&2
					exit 1
				fi
				if [ ! -d "$per_test_log_dir" ] && \
				   ! mkdir -p "$per_test_log_dir"; then
					echo "Could not create log dir:" \
					     "$per_test_log_dir" >&2
					exit 1
				fi
				per_test_log_dir=$(cd "$per_test_log_dir" && pwd -P)
				if [ -z "$per_test_log_dir" ]; then
					echo "Could not resolve per-test log directory" >&2
					exit 1
				fi
				if [ ! -w "$per_test_log_dir" ]; then
					echo "Per-test log dir is not writable:" \
					     "$per_test_log_dir" >&2
					exit 1
				fi
				shift 2
			else
				shift
			fi ;;
		-t | --test)
			TESTS="$TESTS $2"
			shift 2 ;;
		-S | --skip)
			SKIP="$SKIP $2"
			shift 2 ;;
		-c | --collection)
			COLLECTIONS="$COLLECTIONS $2"
			shift 2 ;;
		-l | --list)
			echo "$available"
			exit 0 ;;
		-d | --dry-run)
			dryrun="echo"
			shift ;;
		-f | --no-error-on-fail)
			ERROR_ON_FAIL=false
			shift ;;
		-n | --netns)
			RUN_IN_NETNS=1
			shift ;;
		-o | --override-timeout)
			kselftest_override_timeout="$2"
			shift 2 ;;
		-h | --help)
			usage 0 ;;
		"")
			break ;;
		*)
			usage 1 ;;
	esac
done

collection_tests()
{
	local entry
	printf '%s\n' "$available" | grep -F -e "$1:" |
		while IFS= read -r entry; do
			case "$entry" in
			"$1":*) printf '%s\n' "$entry" ;;
			esac
		done
}

select_tests()
(
	# Split selector lists on whitespace without expanding pathnames.
	set -f

	# Add all selected collections to the explicit test list.
	for collection in $COLLECTIONS ; do
		found="$(collection_tests "$collection")"
		if [ -z "$found" ] ; then
			echo "No such collection '$collection'" >&2
			exit 1
		fi
		TESTS="$TESTS $found"
	done

	# Replace the available list with explicitly selected tests.
	if [ -n "$TESTS" ]; then
		valid=""
		for test in $TESTS ; do
			found="$(printf '%s\n' "$available" | grep -Fx -e "$test")"
			if [ -z "$found" ] ; then
				echo "No such test '$test'" >&2
				exit 1
			fi
			valid="$valid$found
"
		done
		available="$valid"
	fi

	# Remove only the tests named in the skip list.
	for skipped in $SKIP ; do
		available="$(printf '%s\n' "$available" | grep -Fvx -e "$skipped")"
	done
	printf '%s\n' "$available"
)

available="$(select_tests)" || exit 1

curdir=$(pwd)
total=$(echo "$available" | wc -w)
collections=$(echo "$available" | cut -d: -f1 | sort | uniq)

ktap_print_header
ktap_set_plan "$total"

for collection in $collections ; do
	[ -w /dev/kmsg ] && echo "kselftest: Running tests in $collection" >> /dev/kmsg
	tests=$(collection_tests "$collection" | cut -d: -f2)
	$dryrun cd "$collection" && $dryrun run_many $tests
	$dryrun cd "$curdir"
done

ktap_print_totals
if "$ERROR_ON_FAIL" && [ "$KTAP_CNT_FAIL" -ne 0 ]; then
	exit "$KSFT_FAIL"
else
	exit "$KSFT_PASS"
fi
