# ADR 0003: real-board session backend

Status: accepted (RA8EMU-193). Related epic: RA8EMU-174.

## Context

The desktop GUI and agent CLI need to inspect a physical RA8D2 both beside the
client and on the HIL host. The emulator session owns virtual time, faults,
and modeled devices; a debug probe can only expose operations the target and
probe support. The EK-RA8D2 HIL host already uses SEGGER J-Link GDB Server.

## Decisions

1. Keep one client-facing session API and select a backend when opening the
   session. The emulator backend owns a virtual board; the probe backend
   delegates to a GDB server. The GUI never speaks GDB RSP.
2. Advertise backend capabilities as data: register and memory inspection,
   halt, resume, and step for the probe; no virtual speed control, idle
   fast-forward, or emulator-device fault injection. GUI controls are enabled
   only when their capability is present.
3. Use GDB RSP as the first probe transport. J-Link GDB Server, OpenOCD, and
   pyOCD are server choices behind the same transport. The server and physical
   probe run on the host attached to the board. A remote client reaches that
   host through SSH, which supplies authentication and forwarding.
4. Keep target selection and server startup outside the protocol client.
   The operator configures the server for the correct target and core; the
   client only connects to its host and port. Do not expose flash/program
   commands in the initial backend.
5. Treat halt and resume as explicit hardware actions. Reads do not implicitly
   resume or reset the target. The backend reports core and capabilities.

## Spike

The command ra8_emulator ctl probe HOST PORT ACTION speaks GDB RSP to an
already running server. It supports register reads, bounded memory reads,
halt, step, resume, and a JSON capabilities snapshot without loading an ELF or
programming flash. This transport spike will adapt to the versioned session
wire protocol after that protocol is available.
