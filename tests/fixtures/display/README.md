`ra8_ui.elf` is the ra8-ui firmware image built at ra8-ui `92c693eb`
("Let panels paint their own background and bump firmware") with
`zig build image`, copied from `zig-out/image/ra8_ui.elf` and stripped of
debug sections with `arm-none-eabi-strip --strip-debug`. It is the public
harness fixture (`tests/session/harness/harness_test.zig` and
`files_test.zig`): open it, let it settle, and frame it.

`tap.input` is the touch script the harness feeds the image. Each line is
one tap as `x y delay_ms`.

The image's own source sits beside it:

- `app/` is the UI application (`app/root.zig` is the module root; screens,
  chrome, data). It imports `ra8_widget` and `canvas` from the ra8-firmware
  dependency pinned in ra8-ui's `build.zig.zon`.
- `board/src/main.zig` is the image's entry: it builds the UI module for the
  Cortex-M85 target and hands it to the board.

Rebuild from ra8-ui with Arm GNU 13.3.rel1 on `PATH`:

```sh
git checkout 92c693eb
zig build image
arm-none-eabi-strip --strip-debug -o ra8_ui.elf zig-out/image/ra8_ui.elf
```

If the image is rebuilt, update the commit hash in the harness tests' header
comment and re-check the expected frame sizes (1072x1448).
