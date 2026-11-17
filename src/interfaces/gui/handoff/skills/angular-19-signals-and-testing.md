# Angular 19 Signals, SDK, Vitest & Playwright Guide

This file consolidates the `angular-developer`, `vitest`, `playwright-cli`, `webapp-testing`, `web-design-guidelines`, and `frontend-design` rules tailored specifically to `src/interfaces/gui/`.

---

## 1. Angular 19 Rules & Compiler Gotchas

1. **100% Standalone + `OnPush` + Signals:**
   - Every `@Component` MUST set `changeDetection: ChangeDetectionStrategy.OnPush`.
   - Use `input()`, `output()`, `model()`, `viewChild()`, `inject()`, `signal()`, `computed()`, `effect()`, `@if`, `@else`, `@for (...; track ...)`, `@switch`.
   - Never use `@Input()`, `@Output()`, `@ViewChild()`, `*ngIf`, or `*ngFor` (`tools/gate.mjs` rejects them).
2. **NO Arrow Functions in Angular Templates (`NG5002`):**
   - Angular 19 templates reject inline arrow functions like `(click)="items().map(x => ...)"` or `(change)="fn($event, x => ...)"`. Move any projection/mapping to a `computed()` or class method.
3. **`@if (...; as alias)` Restriction:**
   - `"as" expression is only allowed on the primary @if block` — NEVER write `} @else if (sig(); as v) {`. Instead write:
     ```html
     } @else {
       @if (sig(); as v) { ... }
     }
     ```
4. **Component CSS Budget (`4.00 kB` per `.css` / inline style in `angular.json`):**
   - Angular's emulated view encapsulation appends `[_ngcontent-ng-cXXXXXX]` to **every single selector** in comma-separated lists. A 7-item comma selector adds ~200+ extra compiled bytes!
   - Keep component CSS concise (`< 3.5 kB` raw) without long comma-separated selector lists so `npm run build` produces **zero budget warnings**.
5. **Module Layering:**
   - `client/src/` -> pure TypeScript WebSocket RPC SDK (`ra8-rpc-client`). No Angular imports.
   - `src/app/core/` -> RPC client wrapper & Signal stores (`rpc-connection`, `execution`, `workspace`, `remote-hosts`, `board`, `board-storage`, `debug`, `debug-points`, `rewind`, `hardware-hil`, `profile`, `console`, `search-everywhere`, `vim`, `extension`). `core/` NEVER imports upward from `features/` or `routes/`.
   - `src/app/shared/` -> reusable `OnPush` primitives (`ui/`) and pure TS helpers (`utils/`).
   - `src/app/features/` -> domain view-models, panels, and sub-components.
   - `src/app/routes/` -> thin lazy route orchestrators declared in `app.routes.ts`.
6. **Always Rebuild `client/` Before Angular Checks:**
   - `package.json` depends on `"ra8-rpc-client": "file:./client"` (`./client/dist/index.js`). Any edit under `client/src/` requires `npm --prefix client run build` before `tsc --noEmit`, `ng build`, or `vitest` sees the updated types and runtime JS.

---

## 2. Backend Wire & Protocol Constraints You Must Know

- **`Workspace.list` Page Cap (`src/host/workspace/workspace.zig`):** `max_page_entries = 64`. Always pass `limit <= 64` and paginate with `offset += page.count` while `page.more` (already handled/clamped in `WorkspaceStore.listWorkspace`).
- **`ArtifactsExport` Spool Cleanup (`src/interfaces/rpc/artifacts/wire.zig`):** `exportBegin` holds an active transfer spool until `ArtifactsAbort` (`0x0185`) or disconnect. `client/src/wire/artifacts.ts` already calls `ArtifactsAbort` inside `finally`; keep that invariant!
- **`seekTarget` Grammar (`src/session/history/seek_target.zig`):** Valid seek target strings follow backend `seek_target.parse` (e.g., `'12ms'`, `'1234us'`, `'frame:5'`, `'isr:next'`, `'bm:name'`, round numbers without `'@'` prefix). Never pass `'@' + round`.
- **`SendInput` Virtual Timestamp (`0x011F`):** Always pass `atNs: this.execution.virtualTimeNs()` (never hardcoded `0n`, which the daemon rejects with `InputInPast` after `t > 0`).
- **HIL Fault Syntax (`0x0116`):** Always format as `MODEL@ENDPOINT=RULE` (using `formatFaultSpec` in `hardware-hil.store.ts`, splitting only on the **first** `'@'` so endpoints like `i2c:riic@0x6A` stay intact).
- **LED Events (`EventKind.LedChanged`):** `event.address` packs `ledIndex | (level << 8)` (decode via `decodeLedEvent`, not an 8-LED bitmask).

---

## 3. Vitest & Playwright Best Practices

### Vitest (`src/interfaces/gui/tests/`)
- `RpcConnectionStore.isConnected` is a `computed` signal; set `rpc.connectionState.set('connected')` in tests, NEVER `rpc.isConnected.set(...)`.
- After triggering async store actions or `effect()`, flush microtasks + Zone + `OnPush`:
  ```ts
  await Promise.resolve();
  await fixture.whenStable();
  fixture.detectChanges();
  ```
- Stub `HTMLAnchorElement.prototype.click = () => {}` when unit-testing `<a download>` exports under jsdom to avoid `Not implemented: navigation` noise.
- Remember `WorkspaceStore.savedHosts()` initializes with `['ws://127.0.0.1:4567']` when `localStorage` is empty.

### Playwright E2E (`src/interfaces/gui/e2e/`)
- Reuse `startServeFixture(relativeElfPath, extraArgs)` (`e2e/helpers/serve-fixture.ts`) which spawns `zig-out/bin/ra8_emulator[.exe] serve ... --listen tcp:127.0.0.1:0`. If `zig-out/bin/ra8_emulator[.exe]` is missing, build it once with `zig build -j1` from repo root.
- **Keep Active WebSocket Across Routes:** Only `/launch?ws=<url>` triggers auto-connect on load. After `await page.goto('/launch?ws=' + encodeURIComponent(served.wsUrl))` and waiting for `[data-testid="statusbar-connection-btn"]` to show `127.0.0.1`, navigate to `/debug`, `/hardware`, `/rewind`, `/profile`, `/console`, `/open`, `/import` using in-app UI links (`page.getByTestId('nav-debug').click()`, etc.) — NEVER `page.goto('/debug')`, which reloads the SPA and closes the live WebSocket!
- Always audit new screens and open modals with `await auditEditorialSlateScreen(page, name)` at **both** `{ width: 1440, height: 900 }` and `{ width: 1280, height: 720 }`.
- Check every `<canvas>` size with `devicePixelRatio` (`ResizeObserver`) and verify canvas coordinate math for scaled touch inputs (`Tap | Swipe | Longpress`) + Profiler zoom/pan/hit-testing.
