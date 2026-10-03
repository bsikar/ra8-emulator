#!/bin/sh
# Check the threadx_blink RTOS trace under Unicorn and Zig.
# Thread switches and names match, but the first SysTick does not: Unicorn
# takes it at tick 1 before PendSV; Zig enters three PendSVs at tick 0 first.
# Keep both complete opening sequences, including ticks, as regression checks.
# usage: [CPU=zig] tools/rtos_trace.sh EMULATOR THREADX_BLINK_ELF
set -eu
emu=$1
image=$2
backend=${CPU:-unicorn}
# Pass the backend every time: a bare run is the Zig core now (RA8EMU-471).
# The pointer's address moves with each firmware build, so drop it.
trace=$("$emu" "$image" --instructions 3000000 --cpu "$backend" \
    --trace-rtos 2>&1 | sed -n '/^  rtos trace/,$p' | sed '/^ran /,$d' |
    sed 's/_tx_thread_current_ptr @0x[0-9A-Fa-f]*/_tx_thread_current_ptr/')

case "$backend" in
    unicorn)
        want='  rtos trace    : _tx_thread_current_ptr, 16 event(s)
                  tick 0 cpu0 idle
                  tick 1 cpu0 enter SysTick
                  tick 1 cpu0 leave SysTick
                  tick 1 cpu0 enter PendSV
                  tick 1 cpu0 -> 0x22000840 blink_a
                  tick 1 cpu0 leave PendSV
                  tick 1 cpu0 enter PendSV
                  tick 1 cpu0 idle
                  tick 1 cpu0 -> 0x220008F0 blink_b
                  tick 1 cpu0 leave PendSV
                  tick 1 cpu0 enter PendSV
                  tick 1 cpu0 idle
                  tick 2 cpu0 enter SysTick
                  tick 2 cpu0 leave SysTick
                  tick 3 cpu0 enter SysTick
                  tick 3 cpu0 leave SysTick'
        ;;
    zig)
        want='  rtos trace    : _tx_thread_current_ptr, 16 event(s)
                  tick 0 cpu0 idle
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 -> 0x22000840 blink_a
                  tick 0 cpu0 leave PendSV
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 idle
                  tick 0 cpu0 -> 0x220008F0 blink_b
                  tick 0 cpu0 leave PendSV
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 idle
                  tick 1 cpu0 enter SysTick
                  tick 1 cpu0 leave SysTick
                  tick 2 cpu0 enter SysTick
                  tick 2 cpu0 leave SysTick
                  tick 3 cpu0 enter SysTick
                  tick 3 cpu0 leave SysTick'
        ;;
    *)
        echo "rtos_trace: unknown CPU '$backend' (expected unicorn or zig)" >&2
        exit 2
        ;;
esac

if [ "$trace" = "$want" ]; then
    echo "rtos_trace ($backend): opening switches, names and tick sequence match"
else
    echo "rtos_trace ($backend): mismatch"
    echo "$trace"
    exit 1
fi
