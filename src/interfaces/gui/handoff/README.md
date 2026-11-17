# Editorial Slate Angular PWA Handoff Bundle (`M4`–`M8`)

> [!NOTE]
> Temporary one-off handoff package created on branch `bsikar/RA8EMU-1242-gui` (at baseline commit `ec560b104`) so an autonomous Gemini AI Studio / API agent can complete **Milestones 4 through 8** without YouTrack, Stitch, or SSH access. Remove `src/interfaces/gui/HANDOFF_PROMPT.md` and `src/interfaces/gui/handoff/` once M4–M8 review is complete.

## Entrypoint

Start with **[`../HANDOFF_PROMPT.md`](../HANDOFF_PROMPT.md)**.

## Contents

### `skills/` — Mandatory Design, Angular, TypeScript & Test Rules
- [`ra8-editorial-slate.md`](skills/ra8-editorial-slate.md): Editorial Slate color system (`tokens.css` / `syntax.css`), Spatial Mode 1 vs Mode 2 rules, brand-neutral chrome, `>= 12px` font floor, inclusive terminology (`tools/terms.zig`), and file/function size caps (`tools/gate.mjs`).
- [`angular-19-signals-and-testing.md`](skills/angular-19-signals-and-testing.md): Angular 19 `OnPush` + Signals patterns, template/compiler pitfalls (`NG5002`, `@else if (...; as ...)`, `4.00 kB` CSS budget), `ra8-rpc-client` rebuild discipline, Vitest mocking patterns, and Playwright live-daemon E2E rules.

### `specs/` — Complete Architecture, Wire Protocol & YouTrack M4–M8 Specs
- [`milestones_m4_to_m8_youtrack.md`](specs/milestones_m4_to_m8_youtrack.md): Complete screen-by-screen visual transcriptions of Stitch `04b`–`04h`, `07`, `07b`, `08`–`12`, all remaining YouTrack ticket requirements (`RA8EMU-1336`..`1340` and all child/related tickets), and RPC client mappings.
- [`rewind_architecture_spec.md`](specs/rewind_architecture_spec.md): Deep-dive on `src/session/history/`, rooted single-parent CoW branch trees, `±Y` centered Spine vs Waterfall layout, `RA8EMU-1327` backend notes vs already-fixed `ra8-rpc-client` codecs.

### `stitch/` — Approved Editorial Slate Visual Reference Screenshots (`16` PNGs)
- `stitch_04_new_workspace.png`, `stitch_04a_board_details_modal.png`, `stitch_04b_create_board_modal.png`
- `stitch_04c_custom_component_modal.png`, `stitch_04d_configure_cores_modal.png`, `stitch_04e_add_preset_mcu_modal.png`, `stitch_04f_custom_silicon_modal.png`, `stitch_04g_add_memory_region_modal.png`, `stitch_04h_add_component_modal.png`
- `stitch_07_settings_modal.png`, `stitch_07b_settings_color_schemes.png`
- `stitch_08_workbench_debug.png`
- `stitch_09_workbench_monitor.png`
- `stitch_10_workbench_hardware.png`
- `stitch_11_workbench_rewind.png`
- `stitch_12_workbench_profile.png`
