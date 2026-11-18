import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { Access, Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { type BreakpointEntry, DebugStore, type WatchpointEntry } from '../../core/stores/debug.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../../shared/ui/status-dot.component';
import { formatHex32, parseHexAddress } from '../../shared/utils/hex';
import { computePspWatermark, formatStackSummary } from '../../shared/utils/stack-math';
import { boardHasNpu } from './debug-view';

@Component({
  selector: 'app-debug-targets-stack',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent],
  template: `
    <div class="sidebar-wrap">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="TARGETS & THREADS" />
          <span class="es-meta">Sync Halt: {{ execution.cpu1Attached() ? 'ON' : 'CPU0' }}</span>
        </div>
        <button
          type="button"
          class="target-row"
          [class.is-active]="debug.activeCore() === cpu0"
          data-testid="debug-core-0"
          (click)="debug.selectCore(cpu0)"
        >
          <app-status-dot [tone]="rpc.isConnected() ? (execution.isRunning() ? 'cursor' : 'nominal') : 'muted'" label="Core 0 · Cortex-M85" />
          <span class="mono es-meta">{{ execution.executionStatus() }}</span>
        </button>
        @if (execution.cpu1Attached()) {
          <button
            type="button"
            class="target-row"
            [class.is-active]="debug.activeCore() === cpu1"
            data-testid="debug-core-1"
            (click)="debug.selectCore(cpu1)"
          >
            <app-status-dot tone="nominal" label="Core 1 · Cortex-M33" />
            <span class="mono es-meta">{{ execution.executionStatus() }}</span>
          </button>
        }
        @if (hasNpu()) {
          <div class="static-row">
            <span class="es-meta">ACCELERATOR</span>
            <span class="mono val-txt">Ethos-U55</span>
          </div>
        }
        @for (task of profile.rtosTasks(); track task.key) {
          <div class="static-row">
            <span class="ellipsis">{{ task.name }}</span>
            <span class="mono es-meta">{{ task.sharePercent }}%</span>
          </div>
        }
      </section>

      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="CALL STACK" />
          <span class="mono es-meta" data-testid="debug-stack-watermark">{{ mspSummary() }}</span>
        </div>
        @if (mspPercent() > 0) {
          <div class="stack-bar"><div class="stack-fill" [style.width.%]="mspPercent()"></div></div>
        }
        @if (pspInfo().touched) {
          <div class="static-row">
            <span class="es-meta">PSP</span>
            <span class="mono" [class.fault-txt]="pspInfo().nearLimit">{{ pspInfo().summary }}</span>
          </div>
        }
        @if (frames().length > 0) {
          @for (frame of frames(); track $index) {
            <button
              type="button"
              class="frame-row"
              [class.is-active]="debug.selectedFrameIndex() === $index"
              [attr.data-testid]="'debug-frame-' + $index"
              (click)="debug.selectFrame($index)"
            >
              <span class="ellipsis frame-fn mono">#{{ $index }} {{ frame.name || hex(frame.pc) }}</span>
              <span class="mono es-meta">{{ frame.file ? frame.file + ':' + frame.line : hex(frame.pc) }}</span>
            </button>
          }
        } @else {
          <p class="es-meta note">No stack frames sampled.</p>
        }
      </section>

      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="BREAKPOINTS" />
          <button
            type="button"
            class="icon-add"
            data-testid="debug-bp-add-toggle"
            [disabled]="!rpc.isConnected() || rpc.observeOnly()"
            (click)="addOpen.set(!addOpen())"
          >
            {{ addOpen() ? 'Close' : '+ Add' }}
          </button>
        </div>

        @if (addOpen()) {
          <div class="add-form" data-testid="debug-bp-add-form">
            <div class="mode-row">
              <button type="button" class="mini-tab" [class.is-active]="pointKind() === 'bp'" (click)="pointKind.set('bp')">Breakpoint</button>
              <button type="button" class="mini-tab" [class.is-active]="pointKind() === 'wp'" (click)="pointKind.set('wp')">Watchpoint</button>
            </div>
            <input
              type="text"
              class="es-input mono"
              data-testid="debug-bp-target-input"
              [value]="targetInput()"
              (input)="onTargetInput($event)"
              placeholder="0x02000100 or main"
            />
            @if (pointKind() === 'wp') {
              <div class="wp-opts">
                <select class="es-select mono" aria-label="Watchpoint access" [value]="wpAccess()" (change)="onWpAccess($event)">
                  <option value="write">W</option>
                  <option value="read">R</option>
                  <option value="access">RW</option>
                </select>
                <select class="es-select mono" aria-label="Watchpoint size" [value]="wpSize()" (change)="onWpSize($event)">
                  <option value="1">1B</option>
                  <option value="2">2B</option>
                  <option value="4">4B</option>
                  <option value="8">8B</option>
                </select>
              </div>
            }
            <button type="button" class="submit-btn" data-testid="debug-bp-submit-btn" (click)="submitPoint()">Arm</button>
          </div>
        }

        @for (bp of debug.allBreakpoints(); track bp.core + ':' + bp.id + ':' + bp.label) {
          <div class="bp-row" [attr.data-testid]="'debug-bp-item-' + bp.label">
            <span class="bp-dot"></span>
            <span class="mono ellipsis">{{ bp.label }}</span>
            @if (bp.deferred) {
              <span class="pending-tag mono">pending</span>
            }
            <button type="button" class="rm-btn" [disabled]="rpc.observeOnly()" (click)="removeBreakpoint(bp)">×</button>
          </div>
        }
        @for (wp of debug.watchpoints(); track wp.core + ':' + wp.id) {
          <div class="bp-row">
            <span class="wp-dot"></span>
            <span class="mono ellipsis">{{ hex(wp.first) }} [{{ accessLabel(wp.access) }}]</span>
            <button type="button" class="rm-btn" [disabled]="rpc.observeOnly()" (click)="removeWatchpoint(wp)">×</button>
          </div>
        }
        @if (debug.allBreakpoints().length === 0 && debug.watchpoints().length === 0) {
          <p class="es-meta note">Click code gutter or + Add to arm.</p>
        }
      </section>
    </div>
  `,
  styles: [
    `
      .sidebar-wrap { display: flex; flex-direction: column; min-width: 0; }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 6px; min-width: 0; }
      .sec-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
      .target-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; width: 100%; border: 0; border-left: 2px solid transparent; background: transparent; color: var(--es-text-secondary); padding: 4px 6px; cursor: pointer; text-align: left; font-size: 12px; min-width: 0; }
      .frame-row { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; width: 100%; border: 0; border-left: 2px solid transparent; background: transparent; color: var(--es-text-secondary); padding: 4px 6px; cursor: pointer; text-align: left; font-size: 12px; min-width: 0; }
      .target-row:hover, .frame-row:hover { background: var(--es-interactive); }
      .target-row.is-active, .frame-row.is-active { background: var(--es-interactive); border-left-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .static-row, .bp-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 12px; padding: 3px 4px; min-width: 0; }
      .bp-row { justify-content: flex-start; border-bottom: 1px solid var(--es-divider); }
      .ellipsis { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
      .frame-fn { color: var(--es-text-primary); width: 100%; }
      .val-txt { color: var(--es-text-primary); }
      .fault-txt { color: var(--es-signal-fault); }
      .stack-bar { height: 3px; background: var(--es-interactive-high); border-radius: var(--es-radius-sm); overflow: hidden; }
      .stack-fill { height: 100%; background: var(--es-signal-cursor); }
      .icon-add, .mini-tab, .rm-btn, .submit-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-tab.is-active { border-color: var(--es-signal-cursor); color: var(--es-text-primary); background: var(--es-interactive); }
      .rm-btn { margin-left: auto; border: 0; color: var(--es-text-muted); padding: 0 4px; }
      .add-form { display: flex; flex-direction: column; gap: 6px; padding: 8px; background: var(--es-container); border: 1px solid var(--es-border); border-radius: var(--es-radius); }
      .mode-row, .wp-opts { display: flex; gap: 6px; }
      .es-input, .es-select { background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 4px 2px; min-width: 0; width: 100%; }
      .es-select { background: var(--es-container); }
      .bp-dot, .wp-dot { width: 6px; height: 6px; border-radius: var(--es-radius-full); background: var(--es-signal-fault); flex-shrink: 0; }
      .wp-dot { background: var(--es-signal-cursor); }
      .pending-tag { font-size: 12px; color: var(--es-text-muted); border: 1px solid var(--es-border); padding: 0 4px; }
      .note { margin: 0; padding: 2px 0; }
    `,
  ],
})
export class DebugTargetsStackComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly debug = inject(DebugStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly profile = inject(ProfileStore);

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly addOpen = signal<boolean>(false);
  protected readonly pointKind = signal<'bp' | 'wp'>('bp');
  protected readonly targetInput = signal<string>('');
  protected readonly wpAccess = signal<'write' | 'read' | 'access'>('write');
  protected readonly wpSize = signal<number>(4);

  protected readonly hasNpu = computed(() => boardHasNpu(this.board.selectedPreset(), this.board.boardProfileRaw()));
  protected readonly frames = computed(() => this.debug.backtrace()?.frames ?? []);
  protected readonly activeStack = computed(() =>
    this.debug.activeCore() === Core.Cpu1 ? this.profile.cpu1Stack() : this.profile.cpu0Stack()
  );
  protected readonly activeStackMetrics = computed(() =>
    this.debug.activeCore() === Core.Cpu1 ? this.profile.cpu1StackMetrics() : this.profile.cpu0StackMetrics()
  );
  protected readonly mspSummary = computed(() => formatStackSummary(this.activeStack()));
  protected readonly mspPercent = computed(() => this.activeStackMetrics().percentUsed);
  protected readonly pspInfo = computed(() =>
    computePspWatermark(this.activeStack(), this.debug.registers()['psplim'] ?? 0)
  );

  protected hex(val: number): string {
    return formatHex32(val);
  }

  protected onTargetInput(event: Event): void {
    this.targetInput.set((event.target as HTMLInputElement).value);
  }

  protected onWpAccess(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'read' || val === 'access' || val === 'write') this.wpAccess.set(val);
  }

  protected onWpSize(event: Event): void {
    const val = Number.parseInt((event.target as HTMLSelectElement).value, 10);
    if (val === 1 || val === 2 || val === 4 || val === 8) this.wpSize.set(val);
  }

  protected async submitPoint(): Promise<void> {
    const raw = this.targetInput().trim();
    if (!raw) return;
    const addr = parseHexAddress(raw);
    if (this.pointKind() === 'bp') {
      if (addr !== null) await this.debug.toggleBreakpoint(addr, this.debug.activeCore(), formatHex32(addr));
      else await this.debug.addNamedBreakpoint(raw, this.debug.activeCore());
    } else if (addr !== null) {
      const acc = this.wpAccess() === 'read' ? Access.Read : this.wpAccess() === 'access' ? Access.Access : Access.Write;
      await this.debug.addWatchpoint(addr, this.wpSize(), acc, this.debug.activeCore());
    }
    this.targetInput.set('');
    this.addOpen.set(false);
  }

  protected removeBreakpoint(bp: BreakpointEntry): void {
    if (!bp.deferred) void this.debug.toggleBreakpoint(bp.address, bp.core);
  }

  protected removeWatchpoint(wp: WatchpointEntry): void {
    void this.debug.removeWatchpoint(wp);
  }

  protected accessLabel(acc: Access): string {
    if (acc === Access.Read) return 'R';
    if (acc === Access.Access) return 'RW';
    return 'W';
  }
}
