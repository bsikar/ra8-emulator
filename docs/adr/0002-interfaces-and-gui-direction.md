# ADR 0002: interfaces and GUI direction

Status: accepted (2026-10-02). Related epics: RA8EMU-176 (time control), RA8EMU-174 (session server and remote targets), RA8EMU-177 (native GUI debugger), and RA8EMU-175 (pluggable peripherals and fault injection).

## Context

The emulator serves two users: AI agents that need reliable, machine-readable control, and Brighton working at his desk. It must support both the board connected to the local machine and a board attached to a remote host such as the HIL box, a Raspberry Pi, or a Proxmox VM. Time must be useful for both ordinary real-time runs and accelerated soaks or slow-motion inspection. The detailed GUI rendering and platform choices are recorded in [ADR 0001](0001-gui-stack.md).

## Decisions

1. **No web UI.** The emulator does not serve a browser interface. Human interaction uses a desktop GUI; agent interaction uses the CLI and session interfaces.
2. **Native GUI with shared widgets.** The human front end is a native Zig immediate-mode GUI. Improve the ra8-firmware GUI pieces so widgets can run on the board and in host applications, including the emulator debugger. The debugger's visual direction follows the RAD Debugger; its time navigation and profiling borrow from SEGGER Ozone.
3. **CLI and GUI serve different users through common capabilities.** The CLI is the agent interface and provides machine-readable output consistently. Brighton uses the GUI. The GUI and command-line control operate on the same session capabilities rather than maintaining separate emulator control models.
4. **Local and remote operation.** The same workflows work with a locally attached board and with a session on a remote host. Remote connection is initiated by the client over SSH, in the style of JetBrains remote development; the emulator remains headless on the remote machine.
5. **Virtual time is controllable and observable.** Normal execution targets real time at 1x. Users can enter arbitrary speed factors, including slow motion and accelerated runs. Timers, clocks, and dates reflect virtual time accurately. This supports transient-frame inspection as well as long soaks that expose crashes, buffer overflows, and watchdog behavior. Report requested and achieved speed where host throughput limits the requested factor.
6. **Dual-core visibility is required.** The GUI must be able to show both cores; the exact pane arrangement is left to the GUI work.
7. **Peripherals and modules are pluggable.** Devices can be attached, removed, and faulted during a run, including scheduled faults such as a sensor disconnect. The GUI and session controls expose these capabilities.
8. **GDB RSP stays; DAP is deferred.** Keep the GDB Remote Serial Protocol interface. Defer the Debug Adapter Protocol because it is difficult to validate consistently across IDEs.

## Consequences

The session API and its versioned wire protocol are the shared boundary for local and remote control, GUI use, and agent tooling. The GUI is a client of that boundary, not a second emulator front end. Time control, remote sessions, the GUI, and pluggable devices are tracked by the four related epics listed above.

The initial design does not fix the dual-core layout or the exact GUI controls for every operation. Those details belong to the GUI implementation work while preserving these interface decisions.
