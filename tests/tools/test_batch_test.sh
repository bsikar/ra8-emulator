#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
# Runner integration tests use fake suites, without compiling the emulator.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
runner=$here/tools/test_batch.sh
cat >"$work/suite" <<'SUITE'
#!/bin/bash
echo suite-output
echo suite-error >&2
echo "memory=$(ulimit -v)"
case ${SUITE_MODE:-pass} in
    fail) exit 7 ;;
    slow) sleep 30 ;;
esac
SUITE
chmod +x "$work/suite"

run_status() {
    local expected=$1 status=0
    shift
    "$@" || status=$?
    if [ "$status" -ne "$expected" ]; then
        echo "expected exit $expected, got $status" >&2
        exit 1
    fi
}
log=$work/attempts.log
run_status 0 bash "$runner" "$work/suite" "$log"
grep -q '^COMPLETE .*exit=0$' "$log"
run_status 7 env SUITE_MODE=fail bash "$runner" "$work/suite" "$log"
grep -q '^FAILED .*exit=7$' "$log"
run_status 124 env SUITE_MODE=slow RA8_TEST_TIMEOUT_SECONDS=1 bash "$runner" "$work/suite" "$log"
grep -q '^CUT .*exit=124$' "$log"
# A rerun appends and preserves both the earlier success and the cut.
run_status 0 bash "$runner" "$work/suite" "$log"
[ "$(grep -c '^START ' "$log")" -eq 4 ]
[ "$(grep -c '^COMPLETE ' "$log")" -eq 2 ]
[ "$(grep -c '^suite-output$' "$log")" -eq 4 ]
[ "$(grep -c '^suite-error$' "$log")" -eq 4 ]
[ "$(grep -c '^memory=3000000$' "$log")" -eq 4 ]
for invalid in 0 801 99999999999999999999 abc 1.5; do
    run_status 2 env RA8_TEST_TIMEOUT_SECONDS="$invalid" bash "$runner" "$work/suite" "$log"
done
run_status 2 bash "$runner" "$work/missing" "$log"
run_status 1 bash "$runner" "$work/suite" "$work/missing/log"
echo 'test_batch: all checks passed'
