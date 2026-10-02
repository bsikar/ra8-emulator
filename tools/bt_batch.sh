#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# bt_batch.sh -- RA8EMU-48: a backtrace from inside an interrupt handler,
# end to end on a zig-built image with DWARF lines and CFI.
#
#   tools/bt_batch.sh EMULATOR
#
# Builds a small firmware image whose thread pends PendSV and spins until
# the handler has run; the handler calls a leaf. A debug script breaks in
# the leaf and asks for bt, which has to walk leaf, handler, the exception
# frame, the interrupted thread function and reset, each with its source
# line, the way gdb numbers them. Exits 0 when every frame showed, 1 when
# one is missing, and 77 (skipped) when zig is not installed. ZIG
# overrides the zig binary.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 EMULATOR" >&2
    exit 2
fi
emulator=$(realpath "$1")
zig=${ZIG:-zig}
if ! command -v "$zig" >/dev/null; then
    echo "skipped: $zig is not installed"
    exit 77
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

cat >link.ld <<'LD'
ENTRY(reset)
MEMORY { RAM (rwx) : ORIGIN = 0x22000000, LENGTH = 0x10000 }
SECTIONS {
  .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) } > RAM
  .data : { *(.data*) *(.bss*) } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
LD

cat >irq.zig <<'ZIG'
var counter: u32 = 0;
export fn leaf(x: u32) callconv(.C) u32 {
    counter +%= x;
    return counter;
}
export fn pendsv() callconv(.C) void {
    const got = @call(.never_inline, leaf, .{7});
    counter +%= got;
}
export fn work(x: u32) callconv(.C) u32 {
    const icsr: *volatile u32 = @ptrFromInt(0xE000_ED04);
    icsr.* = 1 << 28;
    asm volatile ("dsb\nisb" ::: "memory");
    const seen: *volatile u32 = &counter;
    while (seen.* == 0) {}
    return x + seen.*;
}
export fn reset() callconv(.C) noreturn {
    _ = @call(.never_inline, work, .{3});
    while (true) {}
}
fn spin() callconv(.C) void {
    while (true) {}
}
extern const _stack_top: u32;
export const vectors linksection(".vectors") = [_]?*const anyopaque{
    @ptrCast(&_stack_top), @ptrCast(&reset), @ptrCast(&spin), @ptrCast(&spin),
    @ptrCast(&spin),       @ptrCast(&spin),  @ptrCast(&spin), null,
    null,                  null,             null,            @ptrCast(&spin),
    @ptrCast(&spin),       null,             @ptrCast(&pendsv), @ptrCast(&spin),
};
ZIG

"$zig" build-exe irq.zig -target thumb-freestanding-eabi -mcpu=cortex_m85 \
    -O ReleaseSmall -fno-strip -T link.ld -fentry=reset -femit-bin=irq.elf

printf 'break leaf\ncontinue\nbt\nquit\n' >bt.script
"$emulator" irq.elf --debug-script bt.script >bt.out 2>&1 || true

hex='0x[0-9A-F]{8}'
expected=(
    "^#0 $hex <leaf> at irq.zig:3$"
    "^#1 $hex <pendsv\\+[0-9]+> at irq.zig:7$"
    "^#2 <signal handler called>$"
    "^#3 $hex <work\\+[0-9]+> at irq.zig:15$"
    "^#4 $hex <reset\\+[0-9]+> at irq.zig:19$"
)
status=0
for line in "${expected[@]}"; do
    if ! grep -Eq "$line" bt.out; then
        echo "missing: $line"
        status=1
    fi
done
if [ $status -ne 0 ]; then
    cat bt.out
    exit 1
fi
echo "bt_batch: a backtrace from inside an interrupt handler passed"
