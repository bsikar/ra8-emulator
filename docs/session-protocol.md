# Session wire protocol (RA8EMU-194)

The emulator uses the shared `ra8_rpc` framing and codec. Frames are binary:

- `u32` payload length, little-endian (payload only)
- `u16` frame kind, little-endian
- the kind-specific body, encoded in declaration order with no padding

The shared library defines `hello=1`, `request=2`, `response=3`, `event=4`, and `fault=5`; magic is `RA8R`, version is `1`. The peer exchanges hello frames before requests. A magic or version mismatch produces a fault frame. Capability bits are intersected by the clients; bit 0 announces LCD dirty-rectangle payloads and bit 1 the part methods (plug, unplug, set_fault, clear_fault).

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
