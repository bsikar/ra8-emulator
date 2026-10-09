`touch.elf` is the RA8EMU-812 touch fixture: a Cortex-M85 RA8 image linked at
MRAM `0x02000000` that reads the GT911 touch controller (`0x5D`) over the I3C
channel at `0x4035F000` in legacy I2C mode, after clearing the channel's
module stop (MSTPCRB bit 4, `0x40203004`).

Each frame it reads the status byte at `0x814E`. When a contact is ready it
reads the eight-byte point record at `0x814F`, stores x at SRAM `0x22000100`
and y at `0x22000102` (u16 each), adds one to the count at `0x22000104`, then
writes a zero back to status to acknowledge the frame.

`tests/interfaces/gui/session_touch_wire_test.zig` serves it with `serve --stdio`, taps
the board pane's shown panel through `board_touch` and reads the stored
contact back with `read_memory`.

The source is Zig, so the repository carries no C. Rebuild with Zig 0.17.0:

```sh
zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections touch.zig -femit-bin=touch.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,touch.ld touch.o -o touch.elf
```
