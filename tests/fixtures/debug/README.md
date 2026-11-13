# Debugger conformance fixtures

These Zig sources are built in Debug mode for Cortex-M33/M85 with Zig
0.17.0 and `link.ld` (`link_cpu1.ld` for CPU1). No firmware binary is committed. The normal image
initializes `known_word` to `0x11223344`, stops at an optional register
checkpoint with `r0=0x11223344` and `r1=0x55667788`, executes a small call
and a 30,000-iteration callee, calls `nested_outer(35)` and then
`nested_inner(35)`, and loops forever. The inner function stores 42 to
`stage`. The fault image reaches the fixed unsupported `0xba80` encoding
also used by the core's stop tests, so its decoder stop PC is explicit.

Global assembly labels name exact call and return PCs. They are the
independent oracle for instruction stepping, not addresses recovered from
an adapter's output. Source breakpoints use the marked line in
`machine.zig`. The host conformance runner reads the ELF symbol table and
source itself to produce an oracle JSON file.

The CPU1 image uses a separate M33 entry point and memory region. The
peripheral image enables SCI1 Simple-SPI, queues three idle receive bytes
(`0xff`) through firmware writes, and pauses at a label before draining
them. The GDB test reads RDR twice and then checks the guest's three drain
values and final empty status, proving debugger reads preserve queued data.
Register addresses and setup follow the SCI and MSTP model tests; hardware
references are indexed by RA8EMU-A-30.
