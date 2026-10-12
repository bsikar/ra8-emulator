## Debugging the emulator from your IDE (RA8EMU-1155)

While `ra8_gui` is running it writes a discovery file that lists the RPC
address, one loopback gdb port per session, and the focus address. `ctl`
reads that file, so an IDE never spawns the emulator itself: the GUI owns
the process, gdb attaches to a session the GUI is showing.

```sh
# what is running
ra8_emulator ctl sessions
ra8_emulator ctl sessions --json

# a ready gdb target for a session (matches port or ELF name/suffix)
ra8_emulator ctl gdb-address
ra8_emulator ctl gdb-address threadx_blink
```

With no app running both commands print "start ra8_gui first" and exit 1.

### VS Code (cortex-debug)

`.vscode/launch.json` in this repository has two ready configurations.
The `Attach to hosted session (cortex-debug)` one uses the
`external` server type: copy the `target extended-remote 127.0.0.1:PORT`
line `ctl gdb-address` prints into its `target`'s `overrideLaunchCommands`.
The `Attach to hosted session (extended-remote)` one launches a plain
cppdbg-style gdb and is the fallback if the extension is not installed.

### gdb on the command line

```sh
gdb <the session's ELF>
(gdb) target extended-remote 127.0.0.1:PORT   # as ctl gdb-address prints
(gdb) monitor reset halt   # reboot the session from its ELF, stay paused
(gdb) monitor reload       # reload the ELF in place
(gdb) b main
(gdb) c
```

The port serves one client at a time; a second client waits or is
dropped, and run control (continue, step, interrupts) belongs to the
client that holds it. The GUI keeps painting while gdb is attached: the
pump serves gdb a frame at a time, so breakpoints land between frames.

### CLion and Zed

CLion's "Remote Debug (GDB)" run configuration takes the same
`target extended-remote` line. Zed's debugger accepts it as a
`tcpConnection`-style gdb attach. Nothing here is exclusive to VS Code;
the discovery file and `ctl` are the whole interface.
