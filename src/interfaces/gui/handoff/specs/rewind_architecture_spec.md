# `ra8-emulator` Time-Travel Architecture, Tree/Wire Analysis & `RA8EMU-1327`

Code-level reference across `src/session/history/`, `src/session/`, `src/snapshot/`, `src/interfaces/rpc/`, and `src/interfaces/gui/client/`, paired with the architectural design for **Screen 11 (`/rewind`)**.

> [!IMPORTANT]
> **Status of Client SDK Codec Fixes (`src/interfaces/gui/client/`):**
> During **Milestone 0**, the TypeScript client bugs originally identified in early prototypes were **already fixed** in `src/interfaces/gui/client/src/wire/history.ts` and `src/interfaces/gui/client/src/binary/`:
> - `decodeDiff` (`0x013C`) decodes the exact **45-byte header** (`18B posA + 18B posB + 1B order + counts`) plus `regs`, `pages`, and `periphs`.
> - `setMarker` (`0x013A`) decodes the **43-byte `NavQueryResult`**.
> - `shared/utils/rewind-layout.ts` (`computeRewindTreeLayout`) implements the Centered Spine (`±Y` with Hemisphere Locking) and `Waterfall` (`+Y`) layouts.
> Your work in **Milestone 7 (`Screen 11`)** is to build the Angular UI, wire every `RewindStore` action (`stepBack`, `play`, `seek`, `navQuery`, `setMarker`, `switchBranch`, `confirmFork`, `deleteBranch`, `compareDiff`), and pass live `--history` E2E tests without changing Zig wire contracts unnecessarily.

---

## 1. Explicit Checkpoints vs. Implicit States & Scrubbing Architecture

### 1.1 Canonical Execution Position & Dual Checkpoint Materialization
- **18-Byte Canonical Coordinate (`Position`, `src/session/history/position.zig`)**:
  `(branch: u32, r: u64, phase: enum { cpu0=0, cpu1=1, board=2 }, o: u32, gap: enum { retired=0, polled=1 })`. Closed rounds default to `1024` instructions (`src/session/zig/boundary.zig`) or cut early on SysTick/IRQ/board/vsync/GPT/input boundaries (`src/session/board/boundary.zig`).
- **Explicit Checkpoint Cadence (`src/session/history/checkpoint.zig`)**:
  - `Checkpoint.every: u32 = 64` closed rounds (`HistoryOpts.checkpoint_every = 64` in `src/interfaces/rpc/served_setup.zig`), with synchronous `CP0` on attach (`served_history.zig`).
  - Online disk-budget pressure doubles `self.every` in place; offline thinning applies an `rr`-style exponential curve while pinning first/last/`pinned`/`fork_base` checkpoints.
- **Dual Format Stored per Checkpoint (`src/session/history/checkpoint_engine.zig`)**:
  1. **Loose sparse `RA8SNAP\x00` v14 object** (36 snapshot sections omitting zero 4 KiB RAM pages, unresident SDRAM, unwritten `0xFF` flash sectors, and unwritten 512 B card blocks).
  2. **Content-addressed CoW 4 KiB pages + `Manifest` + `Touched`**: Blake3-128 deduplicated 4 KiB pages stored in `objects/pack-NNNNNN.{pack,idx}` (`PackStore`).
- **Implicit In-Between States (`src/session/history/seek_engine.zig`)**:
  - Intermediate states between 64-round checkpoints are **never written to disk**. `seek_engine.plan` selects the cheapest base among `Base.window` (active `ReverseWindow`), `Base.current` (forward seeks), or `Base.checkpoint` (nearest checkpoint `<= target`, or common ancestor via `cross_seek.zig`), then replays deterministically to the exact `r:phase:o:gap`.

### 1.2 Backend Engine Layers (`src/session/history/` & `src/interfaces/rpc/`)
| Layer | Role | Current Behavior Relevant to UI |
|---|---|---|
| **`ReverseWindow`** (`window_engine.zig`) | Trailing live window behind playhead | Serves fast `stepBack` / intra-window seeks |
| **`Prefetch` Pool** (`prefetch.zig`) | Bracketing checkpoints `-1 / +1` | Loads neighboring raw `RA8SNAP` blobs |
| **`FrameCache`** (`frame_cache.zig`) | 60 Hz LCD keyframe + deltas | Exposes frame counts via `frame_status` (`0x013B`) |
| **`BranchGraph`** (`branch.zig`) | Rooted single-parent CoW fork tree | Exposes `branch_list` (`0x0130`), `branch_switch` (`0x0131`), `branch_delete` (`0x0132`), `branch_confirm_fork` (`0x0133`), `branch_status` (`0x0135`) |

---

## 2. Rooted Single-Parent CoW Fork Tree (Not a General Merge Graph)

- `BranchGraph` (`src/session/history/branch.zig`) is a **strict single-parent rooted tree** (`root_branch_id = 0`).
- Every child branch stores one `parent: BranchId`, `fork_at: Position`, `recorded_end: Position`, `reason: ForkReason` (`0..8`), `is_live`, `kept`, `pruned_tail`. Branches never merge.
- **Counterfactual Fork Safety:** When executing/stepping/writing on an earlier non-head point, the daemon enters a pending counterfactual fork state (`branch_status` `0x0135`: `ForkStatus.pending = true`). Screen 11 should surface `forkStatus().pending` in a clean confirmation bar calling `confirmFork` (`0x0133`).
- **`Method.Seek` Target Grammar (`src/session/history/seek_target.zig`)**:
  - Accepted target strings match Zig `seek_target.parse` (time units like `12ms`, `48000us`, `100ns`, numeric round `1842`, `frame:N`, `isr:prev`/`isr:next`, `bm:<name>`).
  - Never send `'@1842'` — backend rejects `@` prefixes with `BadArgs`.

---

## 3. Spine (`±Y` Centered) vs. Waterfall (`+Y`) Layout Modes

- **Default (`Spine: Center ±Y` in `shared/utils/rewind-layout.ts`)**:
  - Pins the active lineage across `y = 0`, alternates sibling/child branches above (`-y`) and below (`+y`) without crossing lines (Hemisphere Locking), leaving vertical clarity for explicit `◆` 64-round checkpoints, semantic markers, and `[A]` / `[B]` diff cursors.
- **Waterfall (`+Y` Top-Down Toggle)**:
  - One-click toggle to render every branch in strict `0..N` downward rows for multi-branch audit sessions.

---

## 4. Related Backend Companion Ticket (`RA8EMU-1327`, Reference Only)

`RA8EMU-1327` tracks optional future backend speedups in Zig (`src/session/history` and `src/interfaces/rpc`: bidirectional `±Δ` checkpoint delta cache, incremental CoW restore in `Bridge.restore`, semantic auto-tagging in `NavFeed`/`FrameTap`, and `rewind_viewport_query` batched RPC). **Do not modify Zig history internals unless strictly required**; implement **Milestone 7 (`Screen 11`)** cleanly over the existing working `ra8-rpc-client` and `RewindStore` RPC methods (`0x012D..0x013C`).
