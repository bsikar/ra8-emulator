`blink.elf` is the RA8EMU-811 LED fixture: a Cortex-M85 RA8 image linked at
MRAM `0x02000000` that blinks LED1 (blue, P600, LED index 0) twice and then
parks in a loop.

It sets P600 to output low through PORT6's PCNTR1 (`0x400400C0`, PDR in the
low half, PODR in the high half), then writes high, low, high, low with a
short pause between, so the session's event stream carries four
`led_changed` events for LED 0 in that order. The word at SRAM `0x22000100`
counts the level writes and reads 4 once the blinking is done.

`tests/interfaces/gui/session_led_wire_test.zig` serves it with `serve --stdio`,
subscribes to the session topic and checks the four events arrive in order.

The source is Zig, so the repository carries no C. Rebuild with Zig 0.17.0:

```sh
zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections blink.zig -femit-bin=blink.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,gpio.ld blink.o -o blink.elf
```

`buttons.elf` is the RA8EMU-814 switch fixture, built the same way from
`buttons.zig`. It mirrors SW1 (P009, active low, read through PORT0's PCNTR2
at `0x40400004`) onto LED1, so a press on the board's input script shows up as
`led_changed` 0x100 on the session topic and the script's release as 0x000.
The word at SRAM `0x22000100` counts presses.
`tests/interfaces/gui/session_button_wire_test.zig` clicks SW1 through the board pane's
input handler and checks the LED comes on.
