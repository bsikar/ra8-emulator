#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# gdb_batch.sh -- RA8EMU-56: drive the emulator's --gdb stub with a real
# gdb-multiarch in batch mode, on one core and then on two.
#
#   tools/gdb_batch.sh EMULATOR [GDB]
#
# Builds a small firmware image with zig, serves it with --gdb on a local
# port, and runs gdb -batch against it: attach, break, continue, stepi,
# registers, memory read and write, a backtrace, a hardware watchpoint and
# detach; then the same image on both cores, with the second as thread 2
# taking the break, a step, a memory read, a backtrace and a watchpoint;
# then a Cycle Counter comparator set from gdb, which must stop the run
# with DFSR.DWTTRAP (RA8EMU-98);
# then a continue into the endless loop, run past the old instruction
# budget and stopped by a Ctrl-C (SIGINT to gdb, sent on as 0x03); then a
# second image that prints a line through ITM port 0, which must show on
# gdb's console (RA8EMU-77).
# Exits 0 when every expected line showed, 1 when one is missing, and 77
# (skipped) when gdb or zig is not installed. ZIG overrides the zig binary.
# CPU=zig serves every session from the Zig core (--cpu zig, RA8EMU-118),
# the two-core one included (RA8EMU-338).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 EMULATOR [GDB]" >&2
    exit 2
fi
emulator=$(realpath "$1")
gdb=${2:-gdb-multiarch}
zig=${ZIG:-zig}
for tool in "$gdb" "$zig"; do
    if ! command -v "$tool" >/dev/null; then
        echo "skipped: $tool is not installed"
        exit 77
    fi
done

work=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT
cd "$work"

cat >fw.zig <<'ZIG'
var counter: u32 = 0;
export fn target(x: u32) callconv(.C) u32 {
    counter +%= x;
    return counter;
}
export fn reset() callconv(.C) noreturn {
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = @call(.never_inline, target, .{i});
    while (true) {
        _ = @call(.never_inline, target, .{1});
    }
}
extern const _stack_top: u32;
export const vectors linksection(".vectors") = [_]?*const anyopaque{ @ptrCast(&_stack_top), @ptrCast(&reset) };
ZIG
cat >link.ld <<'LD'
ENTRY(reset)
MEMORY { RAM (rwx) : ORIGIN = 0x22000000, LENGTH = 0x10000 }
SECTIONS {
  .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) } > RAM
  .data : { *(.data*) *(.bss*) } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
LD
"$zig" build-obj fw.zig -target thumb-freestanding-eabi -mcpu cortex_m33 -O Debug -femit-bin=fw.o
"$zig" ld.lld --gc-sections -T link.ld fw.o -o fw.elf

cat >itm.zig <<'ZIG'
const stim0: *volatile u8 = @ptrFromInt(0xE000_0000);
const ter: *volatile u32 = @ptrFromInt(0xE000_0E00);
const tcr: *volatile u32 = @ptrFromInt(0xE000_0E80);
export fn done() callconv(.C) noreturn {
    while (true) {}
}
export fn reset() callconv(.C) noreturn {
    tcr.* = 1;
    ter.* = 1;
    for ("hello from itm\n") |c| stim0.* = c;
    @call(.never_inline, done, .{});
}
extern const _stack_top: u32;
export const vectors linksection(".vectors") = [_]?*const anyopaque{ @ptrCast(&_stack_top), @ptrCast(&reset) };
ZIG
"$zig" build-obj itm.zig -target thumb-freestanding-eabi -mcpu cortex_m33 -O Debug -femit-bin=itm.o
"$zig" ld.lld --gc-sections -T link.ld itm.o -o itm.elf
image=fw.elf

cpu=${CPU:-zig}
cpu_args=(--cpu "$cpu")
port=$((20000 + RANDOM % 20000))
failed=0

# serve NAME [EMULATOR ARGS...] -- GDB COMMANDS...: one gdb session.
serve() {
    local name=$1
    shift
    local args=()
    while [ "$1" != "--" ]; do
        args+=("$1")
        shift
    done
    shift
    local commands=()
    for command in "$@"; do commands+=(-ex "$command"); done
    port=$((port + 1))
    "$emulator" "$image" "${cpu_args[@]}" "${args[@]}" --gdb "$port" 2>"$name.emu" &
    pid=$!
    for _ in $(seq 50); do
        grep -q listening "$name.emu" && break
        sleep 0.1
    done
    "$gdb" -batch -nx "$image" -ex "target remote :$port" "${commands[@]}" >"$name.out" 2>&1 || true
    wait "$pid" || true
    pid=
}

# interrupt NAME: continue with nothing to stop on, then interrupt gdb
# the way Ctrl-C does after two seconds, and read where the core stopped.
interrupt() {
    local name=$1
    port=$((port + 1))
    "$emulator" fw.elf "${cpu_args[@]}" --gdb "$port" 2>"$name.emu" &
    pid=$!
    for _ in $(seq 50); do
        grep -q listening "$name.emu" && break
        sleep 0.1
    done
    "$gdb" -batch -nx fw.elf -ex "target remote :$port" -ex continue \
        -ex 'info registers pc' -ex 'bt 2' -ex detach >"$name.out" 2>&1 &
    local client=$!
    sleep 2
    kill -INT "$client" 2>/dev/null || true
    wait "$client" || true
    wait "$pid" || true
    pid=
}

# expect NAME TEXT...: each text must appear in that session's output.
expect() {
    local name=$1
    shift
    for text in "$@"; do
        if ! grep -qF -- "$text" "$name.out"; then
            echo "$name: missing: $text"
            failed=1
        fi
    done
}

serve one -- 'break target' continue continue stepi 'info registers pc' \
    "x/1xw &'fw.counter'" "set var 'fw.counter' = 100" "p 'fw.counter'" 'bt 2' delete \
    "watch 'fw.counter'" continue detach
expect one '<fw.counter>:' 'Breakpoint 1, ' 'fw.target (x=0) at fw.zig:' '<fw.target+' \
    '$1 = 100' 'fw.target (x=1) at fw.zig:3' \
    'in fw.reset () at fw.zig:8' 'Hardware watchpoint 2' \
    'Old value = 100' 'New value = 101' '[Inferior 1 (Remote target) detached]'

sessions="one two cycle stop itm"
serve two --cpu1 fw.elf -- 'info threads' 'thread 2' 'info registers pc' \
    'break target' continue stepi bt "x/1xw &'fw.counter'" delete \
    "watch 'fw.counter'" continue detach
expect two '[Switching to thread 2 (Thread 2)]' '<fw.reset>' \
    'Thread 2 hit Breakpoint 1, ' 'in fw.reset () at fw.zig:8' \
    '<fw.counter>:' 'Thread 2 hit Hardware watchpoint 2' 'New value = ' \
    '[Inferior 1 (Remote target) detached]'

# RA8EMU-98: a Cycle Counter comparator armed from gdb stops the run with
# DFSR.DWTTRAP (bit 2) set. RA8EMU-101: on the instruction that brings
# CYCCNT to its value, not at the next clock charge.
serve cycle -- 'set *(unsigned*)0xE000EDFC = 0x01000000' 'set *(unsigned*)0xE0001000 = 1' \
    'set *(unsigned*)0xE0001020 = 400' 'set *(unsigned*)0xE0001028 = 0x11' continue \
    'p/x *(unsigned*)0xE000ED30' 'p *(unsigned*)0xE0001004 - 400 <= 1' detach
expect cycle 'Program received signal SIGTRAP' '$1 = 0x4' '$2 = 1' \
    '[Inferior 1 (Remote target) detached]'

interrupt stop
expect stop 'Program received signal SIGINT, Interrupt.' 'in fw.reset () at fw.zig:' \
    '[Inferior 1 (Remote target) detached]'

image=itm.elf
serve itm -- 'break done' continue detach
expect itm 'hello from itm' 'Breakpoint 1, ' '[Inferior 1 (Remote target) detached]'

if [ "$failed" -ne 0 ]; then
    for name in $sessions; do
        echo "--- $name"
        cat "$name.out" "$name.emu"
    done
    exit 1
fi
echo "gdb_batch ($cpu): $sessions passed"
