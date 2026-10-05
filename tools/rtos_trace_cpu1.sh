#!/bin/sh
# Check --trace-rtos on a dual-core run whose CPU1 runs ThreadX (RA8EMU-265):
# threadx_cpu1.elf keeps CPU0 bare metal and starts ThreadX on CPU1 from
# threadx_cpu1_cpu1.elf, so the trace must come back tagged cpu1, with the
# ticker thread named from its TX_THREAD and PendSV around each switch.
# usage: [CPU=zig] tools/rtos_trace_cpu1.sh EMULATOR CPU0_ELF CPU1_ELF
#
# SysTick lines are checked for presence, not position, as in rtos_trace.sh.
set -eu
emu=$1
image=$2
cpu1=$3
trace=$("$emu" "$image" --instructions 3000000 ${CPU:+--cpu "$CPU"} --cpu1 "$cpu1" --trace-rtos 2>&1 | sed -n '/^  rtos cpu1/,$p' | sed 's/tick [0-9]* //')
got=$(printf '%s\n' "$trace" | grep -v SysTick | sed 's/, [0-9]* event(s)$//' | head -7)
want='  rtos cpu1     : _tx_thread_current_ptr @0x221905AC
                  cpu1 idle
                  cpu1 enter PendSV
                  cpu1 -> 0x22190008 ticker
                  cpu1 leave PendSV
                  cpu1 enter PendSV
                  cpu1 idle'
if [ "$got" = "$want" ] && printf '%s\n' "$trace" | grep -q 'cpu1 enter SysTick' && printf '%s\n' "$trace" | grep -q 'cpu1 leave SysTick'; then
    echo "rtos_trace_cpu1${CPU:+ ($CPU)}: threadx_cpu1 opening switches, names and exceptions match on cpu1"
else
    echo "rtos_trace_cpu1${CPU:+ ($CPU)}: mismatch"; echo "$trace"; exit 1
fi
