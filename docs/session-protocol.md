# Session wire protocol (RA8EMU-194)

The emulator uses the shared `ra8_rpc` framing and codec. Frames are binary:

- `u32` payload length, little-endian (payload only)
- `u16` frame kind, little-endian
- the kind-specific body, encoded in declaration order with no padding

The shared library defines `hello=1`, `request=2`, `response=3`, `event=4`, and `fault=5`; magic is `RA8R`, version is `1`. The peer exchanges hello frames before requests. A magic or version mismatch produces a fault frame. Capability bits are intersected by the clients; bit 0 announces LCD dirty-rectangle payloads and bit 1 the part methods (plug, unplug, set_fault, clear_fault), bit 2 `advance`, and bit 3 `snapshot` and `restore`.

Request, response, and event envelopes use the shared library's u32 request id, u16 method/topic, and binary argument payload. A response carries either the reply bytes or an application error. Events are pushed independently of outstanding requests. Request ids correlate out-of-order responses. `run` acknowledges when the core starts; the later stop is a `stop` event.

## Methods

| ID | Name | Request | Reply |
|---:|---|---|---|
| 0x0100 | load | core and length-prefixed ELF bytes | acknowledgement |
| 0x0101 | run | core, run mode, instruction budget | acknowledgement |
| 0x0102 | pause | core | acknowledgement |
| 0x0103 | step | core | acknowledgement |
| 0x0104 | set_speed | core, speed in thousandths | acknowledgement |
| 0x0105 | read_register | core, register | u32 value |
| 0x0106 | write_register | core, register, u32 value | acknowledgement |
| 0x0107 | read_memory | core, address, length | length-prefixed bytes |
| 0x0108 | write_memory | core, address, length-prefixed bytes | acknowledgement |
| 0x0109 | set_breakpoint | core, address | u32 point id |
| 0x010a | clear_breakpoint | core, point id | acknowledgement |
| 0x010b | set_watchpoint | core, first, last, access | u32 point id |
| 0x010c | clear_watchpoint | core, point id | acknowledgement |
| 0x010d | subscribe | core, topic | acknowledgement |
| 0x010e | unsubscribe | core, topic | acknowledgement |
| 0x010f | now | core | u64 virtual nanoseconds |
| 0x0110 | interrupt | core | stop result |
| 0x0111 | set_run_budget | core, instruction budget | acknowledgement |
| 0x0112 | remove_point | core, point id | breakpoint or watchpoint kind |
| 0x0113 | plug | core, length-prefixed `MODEL@ENDPOINT` text | acknowledgement |
| 0x0114 | unplug | core, length-prefixed `ENDPOINT` text | acknowledgement |
| 0x0115 | set_fault | core, length-prefixed `MODEL@ENDPOINT=MODE` or `@ENDPOINT=MODE` text | acknowledgement |
| 0x0116 | clear_fault | core, length-prefixed `ENDPOINT` text | acknowledgement |
| 0x0117 | advance | core, `u64` virtual nanoseconds | core, `from_ns`, `to_ns`, stop reason, PC |
| 0x0118 | snapshot | path on the serving host | ack |
| 0x0119 | restore | path on the serving host | ack |

Part specs travel as text in the same syntax as the `--attach` and `--fault` flags, and the server parses them with the same parsers, so the two cannot drift. A spec that does not parse is refused as bad arguments; one the board cannot honour (an unknown endpoint, a mode that does not fit the part's bus) is refused with the session's refusal code. Capability bit 1 announces these four methods.

## Events

| Topic | Payload |
|---:|---|
| 0x0100 | stop reason, core, address, and reason-specific detail |
| 0x0101 | core, SCI channel, raw UART bytes |
| 0x0102 | core and achieved speed |
| 0x0103 | core, rectangle origin and size, virtual timestamp, raw grayscale pixels |
| 0x0104 | core and trace bytes |
| 0x0105 | core, session event kind, optional address encoded as zero when absent |

LCD pixels are binary bytes for only the dirty rectangle; they are never text or base64. Transports carry the same frames over stdin/stdout, Unix domain sockets, or TCP. A desktop client owns presentation; the emulator serves no web UI.

## Remote hosts (RA8EMU-196)

`ctl --host NAME --image ELF` starts a `serve --stdio` for one command on the host a
profile names, instead of connecting to a running `serve`. Each call is a fresh machine
booted from ELF. For one long-lived session on another machine, run `serve --listen` there
and use `ctl --connect`.

Profiles live in a hosts file, read from `--hosts FILE`, else `$RA8_HOSTS`, else
`~/.config/ra8_emulator/hosts`. One profile per line, `#` starts a comment:

```
local here
ssh lab bsikar@labvm emulator=/opt/ra8/ra8_emulator cache=/var/cache/ra8 ssh=ssh
```

An ssh profile asks the remote `test -f CACHE/<sha256>.elf` first and copies the image over
ssh stdin only when it is missing, then runs `EMULATOR serve --stdio CACHE/<sha256>.elf`.
`emulator` defaults to `ra8_emulator` on the remote PATH, `cache` to
`.cache/ra8_emulator/images` under the remote home, and `ssh` to `ssh`. A server that speaks
another protocol version fails the handshake with `VersionMismatch` and a message saying to
run the same build on both ends.

## Advance

`advance` (RA8EMU-654) runs a core until board time has moved the given virtual nanoseconds, then replies with where it began and ended and how it stopped. The server converts the duration with the board's own rate, so a client never needs it. A breakpoint, watchpoint, pause or fault ends it early with that stop and the time reached. The core's run budget is put back afterwards. A sleeping core goes by in wide chunks (RA8EMU-767), so ten minutes of WFI cost well under a host second. `ctl advance 600s` sends it; with `--json` it prints `{"advanced":{"core":"cpu0","from_ns":N,"to_ns":M,"reason":"count","pc":P}}`. Capability bit 2 announces it.

## Snapshot and restore

`snapshot` (RA8EMU-768) writes the whole run to a path on the serving host: the same file `--save-state` writes (board, guest memory, CPU0, the two SysTick bases, and a stretch section with nothing owed), so `--load-state` starts from it and a session restores one `--save-state` wrote. `restore` reads such a file back into the live session: a file from another part is refused before anything changes, the store is wiped so pages written since read as they were saved, and a stop still owed to the client is dropped. Both are refused while CPU1 is attached, as the CLI refuses it. `ctl snapshot PATH` and `ctl restore PATH` send them; with `--json` they print `{"snapshot":PATH}` and `{"restored":PATH}`. Capability bit 3 announces them.
