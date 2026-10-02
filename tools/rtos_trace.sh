#!/bin/sh
# Check --trace-rtos on threadx_blink.elf against its known opening (RA8EMU-221),
# threads named from their TX_THREAD (RA8EMU-223).
# usage: tools/rtos_trace.sh EMULATOR THREADX_BLINK_ELF
set -eu
emu=$1
image=$2
got=$("$emu" "$image" --instructions 3000000 --trace-rtos 2>&1 | grep -A5 '^  rtos trace' | sed 's/tick [0-9]* //')
want='  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 5 switch(es)
                  cpu0 idle
                  cpu0 -> 0x220010F0 blink_a
                  cpu0 idle
                  cpu0 -> 0x220011A0 blink_b
                  cpu0 idle'
if [ "$got" = "$want" ]; then
    echo "rtos_trace: threadx_blink opening sequence and thread names match"
else
    echo "rtos_trace: mismatch"; echo "$got"; exit 1
fi
