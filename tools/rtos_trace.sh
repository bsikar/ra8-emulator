#!/bin/sh
# Check the threadx_blink RTOS trace on the Zig core: three PendSVs at
# tick 0, then SysTick from tick 1. The complete opening sequence, ticks
# included, is the regression check.
# usage: [CPU=zig] tools/rtos_trace.sh EMULATOR THREADX_BLINK_ELF
set -eu
emu=$1
image=$2
backend=${CPU:-zig}
# The pointer's and each thread's address move with each firmware build,
# so drop them.
trace=$("$emu" "$image" --instructions 3000000 --cpu "$backend" \
    --trace-rtos 2>&1 | sed -n '/^  rtos trace/,$p' | sed '/^ran /,$d' |
    sed 's/_tx_thread_current_ptr @0x[0-9A-Fa-f]*/_tx_thread_current_ptr/' |
    sed 's/-> 0x[0-9A-Fa-f]* /-> /')

want='  rtos trace    : _tx_thread_current_ptr, 16 event(s)
                  tick 0 cpu0 idle
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 -> blink_a
                  tick 0 cpu0 leave PendSV
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 idle
                  tick 0 cpu0 -> blink_b
                  tick 0 cpu0 leave PendSV
                  tick 0 cpu0 enter PendSV
                  tick 0 cpu0 idle
                  tick 1 cpu0 enter SysTick
                  tick 1 cpu0 leave SysTick
                  tick 2 cpu0 enter SysTick
                  tick 2 cpu0 leave SysTick
                  tick 3 cpu0 enter SysTick
                  tick 3 cpu0 leave SysTick'

if [ "$trace" = "$want" ]; then
    echo "rtos_trace ($backend): opening switches, names and tick sequence match"
else
    echo "rtos_trace ($backend): mismatch"
    echo "$trace"
    exit 1
fi
