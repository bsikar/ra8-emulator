#!/bin/sh
# Check --trace-rtos on threadx_blink.elf against its known opening (RA8EMU-221),
# threads named from their TX_THREAD (RA8EMU-223), with the PendSV entries and
# returns around each switch and SysTick taken (RA8EMU-224), on Unicorn and on
# the Zig core (RA8EMU-261).
# usage: [CPU=zig] tools/rtos_trace.sh EMULATOR THREADX_BLINK_ELF
#
# SysTick lines are checked for presence, not position: the first SysTick
# lands before the first PendSV on Unicorn and after it on the Zig core,
# because the two engines reach tick 1 at different points in the boot.
set -eu
emu=$1
image=$2
trace=$("$emu" "$image" --instructions 3000000 ${CPU:+--cpu "$CPU"} --trace-rtos 2>&1 | sed -n '/^  rtos trace/,$p' | sed 's/tick [0-9]* //')
got=$(printf '%s\n' "$trace" | grep -v SysTick | head -11)
want='  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 16 event(s)
                  cpu0 idle
                  cpu0 enter PendSV
                  cpu0 -> 0x220010F0 blink_a
                  cpu0 leave PendSV
                  cpu0 enter PendSV
                  cpu0 idle
                  cpu0 -> 0x220011A0 blink_b
                  cpu0 leave PendSV
                  cpu0 enter PendSV
                  cpu0 idle'
if [ "$got" = "$want" ] && printf '%s\n' "$trace" | grep -q 'cpu0 enter SysTick' && printf '%s\n' "$trace" | grep -q 'cpu0 leave SysTick'; then
    echo "rtos_trace${CPU:+ ($CPU)}: threadx_blink opening switches, names and exceptions match"
else
    echo "rtos_trace${CPU:+ ($CPU)}: mismatch"; echo "$trace"; exit 1
fi
