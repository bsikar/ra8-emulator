#!/bin/sh
# Prove the RA8FW-624 ThreadX FPU image on the Zig core: both workers pass
# their register self-checks and every PendSV switches between them in order.
# usage: tools/fp_context.sh EMULATOR THREADX_FPU_CONTEXT_ELF
set -eu

usage() {
    echo "usage: $0 EMULATOR THREADX_FPU_CONTEXT_ELF" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
emulator=$1
image=$2

case "$emulator" in
    */*) ;;
    *) echo "$emulator: emulator path must contain /" >&2; exit 2 ;;
esac
[ -f "$emulator" ] || { echo "$emulator: emulator is not a regular file" >&2; exit 2; }
[ -x "$emulator" ] || { echo "$emulator: emulator is not executable" >&2; exit 2; }
[ -f "$image" ] || { echo "$image: ELF is not a regular file" >&2; exit 2; }
[ -r "$image" ] || { echo "$image: ELF is not readable" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fp_context.XXXXXX") || exit 2
log=$work/run
console=$work/console
expected=$work/expected
trace=$work/trace
counts=$work/counts
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if "$emulator" "$image" --cpu zig --instructions 20000000 --console \
    --until 'fpctx: PASS' --trace-rtos </dev/null >"$log" 2>&1; then
    :
else
    status=$?
    {
        echo "fp_context (zig): emulator exited $status"
        cat "$log"
    } >&2 || :
    exit "$status"
fi

awk '/^console> fpctx:/ { print substr($0, 10) }' "$log" >"$console"
printf '%s\n' \
    'fpctx: start' \
    'fpctx: thread=A PASS' \
    'fpctx: thread=B PASS' \
    'fpctx: PASS' >"$expected"
if ! cmp -s "$expected" "$console"; then
    echo "fp_context (zig): console verdict mismatch" >&2
    cat "$console" >&2
    exit 1
fi

awk '
/^  rtos trace    : / {
    print
    section = 1
    next
}
section && /^                  tick / {
    print
    next
}
section && /^                  and [0-9][0-9]* more, not kept$/ {
    print
    next
}
section { section = 0 }
' "$log" >"$trace"

if grep -Eq 'and [0-9][0-9]* more, not kept' "$trace"; then
    echo "fp_context (zig): RTOS trace was truncated" >&2
    cat "$trace" >&2
    exit 1
fi

if ! awk '
function reject(why) {
    print "fp_context (zig): RTOS trace " why
    bad = 1
    exit 1
}
/^  rtos trace    : / {
    headers++
    next
}
/^                  tick [0-9][0-9]* cpu0 enter PendSV$/ {
    if (state != 0) reject("has nested or unfinished PendSV entry")
    state = 1
    enters++
    next
}
/^                  tick [0-9][0-9]* cpu0 -> / {
    if (state != 1) reject("has a switch outside PendSV or more than one switch")
    name = $0
    sub(/^                  tick [0-9][0-9]* cpu0 -> 0x[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f] /, "", name)
    if (name == $0 || (name != "fpctx_a" && name != "fpctx_b")) {
        reject("names an unexpected thread: " name)
    }
    want = cycles % 2 == 0 ? "fpctx_a" : "fpctx_b"
    if (name != want) reject("switch order mismatch: expected " want ", got " name)
    if (name == "fpctx_a") a++
    if (name == "fpctx_b") b++
    cycles++
    state = 2
    next
}
/^                  tick [0-9][0-9]* cpu0 .*->/ {
    reject("has a malformed switch event")
}
/^                  tick [0-9][0-9]* cpu0 leave PendSV$/ {
    if (state != 2) reject("leaves without exactly one named switch")
    leaves++
    state = 0
    next
}
END {
    if (bad) exit 1
    if (headers != 1) reject("has " headers " report sections, expected 1")
    if (state != 0) reject("ends with an unfinished PendSV")
    if (enters != leaves || enters != cycles) reject("has unbalanced PendSV events")
    if (a < 8 || b < 8) reject("has too few switches: A=" a " B=" b)
    print a, b, enters, leaves
}
' "$trace" >"$counts"; then
    cat "$counts" >&2 || :
    cat "$trace" >&2 || :
    exit 1
fi

set -- $(cat "$counts")
echo "fp_context (zig): A=$1 B=$2, PendSV=$3/$4, console PASS"
