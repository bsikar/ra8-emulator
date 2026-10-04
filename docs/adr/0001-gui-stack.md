# ADR 0001: GUI stack

Status: accepted (2026-10-04). Tickets: RA8EMU-202 (parent RA8EMU-177), slices RA8EMU-617 (this ADR, the draw list, the CPU rasterizer, the platform seam) and RA8EMU-616 (SDL3 and the hello window).

## Context

The debugger GUI is native Zig and immediate mode, with no web UI. Its widgets are shared with ra8-firmware, it looks like the RAD Debugger, and it runs on Brighton's Mac, on Linux and on Windows 11. The emulator must never slow down because a window is open.

## Decision

1. **Platform layer: SDL3 behind our own seam.** `src/gui/platform.zig` is the whole contract: a window, input events, the drawable size, the DPI scale, and presenting an RGBA framebuffer. SDL3 is one backend (RA8EMU-616), built from source through the Zig build system (castholm/SDL) so cross-compiles need no system SDL. `src/gui/headless.zig` is another; it draws into memory for tests.
2. **Rendering: widgets emit a draw list.** `src/gui/draw_list.zig` has fills, lines, glyph quads from a font atlas and image quads, each carrying the clip in force when it was added. `src/gui/raster.zig` draws a list into an RGBA8 framebuffer on the CPU, source-over with straight alpha. The board draws its panes that way and golden-image tests compare those exact pixels. The first host backend presents the CPU framebuffer as one texture through SDL's renderer (Metal, D3D, Vulkan or GL picked at runtime, with a software fallback). Rasterizing on the GPU later (SDL's geometry path, then SDL_GPU) is a change inside the backend only.
3. **Display rate is decoupled from emulation speed.** The UI redraws at most once per vsync (default cap 60 Hz) and only when something changed.
4. **Threading.** The emulator runs on its own threads and never waits on the UI. State reaches the UI through a lock-free snapshot handoff (RA8EMU-221).
5. **Support policy.** GUI client only: macOS arm64, Linux x86_64 and aarch64 (X11 and Wayland), Windows 11 x64, on current OS releases. No 32-bit. `serve` stays headless, so the HIL box and lab VMs never need a display.
6. **Testing.** CI cross-builds every target. Pane tests render headless and compare against golden images. A real-window smoke test runs on Brighton's Mac, `dev` (X11 and Wayland) and `win` before GUI releases.

Still open, decided in their own tickets: font rasterization and the atlas format, and pane docking.

## Rejected

- **A web UI (Electron, Tauri, a browser front end).** Brighton ruled it out. It also brings a second language, toolchain and process boundary into the debugger.
- **Dear ImGui through C bindings.** Immediate mode, but C++. Its widgets can't run on the board, and its look is hard to bend toward the RAD Debugger.
- **GLFW plus our own GL renderer.** GL is deprecated on macOS, and GLFW has no clipboard MIME, IME or high-DPI story as complete as SDL3's.
- **Per-OS native backends (AppKit, Win32, Wayland).** Three seams to keep in step, for nothing SDL3 doesn't already give.
- **GPU-first rendering.** It would fork the pixels the board shows from the pixels the host shows, and golden tests would depend on the driver. The CPU path keeps one source of truth, and the GPU is the step up only if a budget is missed.

## Budgets (accepted by Brighton 2026-10-02)

1. Emulator throughput with the GUI attached is at least 95% of headless, same image and host, at max speed, over a 30-minute run.
2. The UI thread uses at most 15% of one core with a busy layout at 4K/60 Hz, and at most 2% when idle.
3. p99 frame time is within one refresh interval, with at most 1% of vsyncs missed.

These are measured on Brighton's Mac and on `win` through the sustained-load recipe (RA8EMU-223), recording the active render driver and GPU name with every result. The GPU matrix includes the Intel Arc A310 (RA8EMU-229).

## If a budget is missed

Re-measure after each step, in this order:

1. Profile where the time goes: draw-list build, rasterizing, upload, submit, snapshot copy, or emulator contention.
2. Do less work: redraw only dirty panes, cache unchanged panes, lower the rate for unfocused panes (for example the timeline at 15 Hz at max speed).
3. Upload less: dirty-rectangle texture updates only.
4. Move rasterizing to the GPU: SDL's renderer geometry path first (textured triangles, no shader toolchain), then SDL_GPU with LCD pixel-format conversion in a shader. The draw list stays the same.
5. Make the UI rate adaptive so budget 1 holds before frame rate does. For heavy soaks, run the emulator on a remote host.

## Spike measurements

Pending: filled in by the spike slice after RA8EMU-616, on Brighton's Mac and `win`.

| Host | Render driver / GPU | Throughput vs headless | UI CPU busy / idle | p99 frame / missed vsyncs |
|------|---------------------|------------------------|--------------------|---------------------------|
| Mac (arm64) | pending | pending | pending | pending |
| win (Windows 11) | pending | pending | pending | pending |
