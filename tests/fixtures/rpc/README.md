# RPC qualification peer

`version_mismatch.py` is a synthetic peer written for RA8EMU-1255. It reads a
real client hello, responds with the same magic and a different protocol
version, and verifies the client's version-mismatch fault. No firmware or
manufacturer binary is included.

The optional `--receipt PATH` writes a success line only after validating the
fault. The live runner checks the count after each invocation, independently
of the client's error message, so fixture rejection cannot qualify.

Framing and field widths come from the pinned ra8-firmware `ra8_rpc` library:
`frame.zig` (six-byte little-endian header), `envelope.zig` (Hello and Fault),
and `link.zig` (admission refusal). The fixture derives the incompatible
version from the incoming hello so it remains incompatible after upgrades.
