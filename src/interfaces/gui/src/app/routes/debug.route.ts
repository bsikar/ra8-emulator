import { ChangeDetectionStrategy, Component, computed, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { DebugStore } from '../core/stores/debug.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';
import { formatHex32 } from '../shared/utils/hex';

const REG_KEYS = ['pc', 'sp', 'lr', 'xpsr', 'r0', 'r1', 'r2', 'r3'] as const;

@Component({
  selector: 'app-debug-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, SectionKickerComponent, StatusDotComponent, TonalButtonComponent],
  template: `
    <app-split-pane primarySize="280px">
      <div pane-primary class="pane-body">
        <div class="pane-head">
          <app-section-kicker label="CORE REGISTERS" />
          <span class="es-subline">CPU{{ debug.activeCore() }}</span>
        </div>

        @if (rpc.isConnected()) {
          <div class="reg-list">
            @for (row of regRows(); track row.name) {
              <div class="reg-row" [class.is-changed]="row.changed" [attr.data-reg]="row.name">
                <span class="reg-name mono">{{ row.name.toUpperCase() }}</span>
                <span class="reg-val mono">{{ row.hex }}</span>
              </div>
            }
          </div>
        } @else {
          <p class="es-meta empty-note">Connect a session to inspect registers.</p>
        }
      </div>

      <div pane-secondary class="pane-body">
        <div class="pane-head">
          <div class="head-left">
            <app-section-kicker label="DISASSEMBLY" />
            <app-status-dot
              [tone]="rpc.isConnected() ? (execution.isRunning() ? 'cursor' : 'nominal') : 'muted'"
              [label]="execution.executionStatus()"
            />
            @if (rpc.observeOnly()) {
              <span class="observe-pill" data-testid="debug-observe-pill">OBSERVE · Read-Only</span>
            }
          </div>
          <div class="head-actions">
            <app-tonal-button
              testId="debug-step-btn"
              [disabled]="!rpc.isConnected() || execution.isRunning() || rpc.observeOnly()"
              (pressed)="execution.step()"
            >
              Step
            </app-tonal-button>
            <app-tonal-button
              testId="debug-run-btn"
              [disabled]="!rpc.isConnected() || rpc.observeOnly()"
              (pressed)="toggleRun()"
            >
              {{ execution.isRunning() ? 'Pause' : 'Continue' }}
            </app-tonal-button>
          </div>
        </div>

        @if (debug.disasm().length > 0) {
          <div class="es-code-buffer" data-testid="debug-disasm">
            @for (row of debug.disasm(); track row.address) {
              <div class="es-code-line" [class.is-active]="row.address === pcValue()">
                <span class="es-code-ln mono">{{ hex(row.address) }}</span>
                <span class="tok-id">{{ row.text }}</span>
              </div>
            }
          </div>
        } @else {
          <p class="es-meta empty-note">No active disassembly buffer.</p>
        }
      </div>
    </app-split-pane>
  `,
  styles: [
    `
      .pane-body {
        padding: 12px 16px;
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .pane-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        padding-bottom: 8px;
        border-bottom: 1px solid var(--es-divider);
      }
      .head-left,
      .head-actions {
        display: inline-flex;
        align-items: center;
        gap: 10px;
      }
      .reg-list {
        display: flex;
        flex-direction: column;
      }
      .reg-row {
        display: flex;
        justify-content: space-between;
        align-items: center;
        min-height: 24px;
        padding: 2px 6px;
        border-left: 2px solid transparent;
        border-bottom: 1px solid var(--es-divider);
        font-size: 12px;
      }
      .reg-row.is-changed {
        border-left-color: var(--es-signal-cursor);
      }
      .reg-name {
        color: var(--es-text-muted);
      }
      .reg-val {
        color: var(--es-text-secondary);
      }
      .reg-row.is-changed .reg-val {
        color: var(--es-text-primary);
      }
      .empty-note {
        margin: 0;
        padding: 12px 0;
      }
      .observe-pill {
        padding: 2px 8px;
        border-radius: var(--es-radius-sm);
        border: 1px solid var(--es-signal-cursor);
        background: var(--es-interactive);
        color: var(--es-signal-cursor);
        font-size: 12px;
        font-weight: 500;
      }
    `,
  ],
})
export class DebugRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly debug = inject(DebugStore);

  protected readonly pcValue = computed(() => (this.debug.registers()['pc'] ?? 0) >>> 0);
  protected readonly regRows = computed(() => {
    const cur = this.debug.registers();
    const prev = this.debug.previousRegisters();
    return REG_KEYS.map((name) => {
      const val = cur[name];
      const hasPrev = prev[name] !== undefined;
      return {
        name,
        hex: val !== undefined ? formatHex32(val) : '—',
        changed: hasPrev && prev[name] !== val,
      };
    });
  });

  protected hex(addr: number): string {
    return formatHex32(addr);
  }

  protected toggleRun(): void {
    if (this.execution.isRunning()) {
      void this.execution.pause();
    } else {
      void this.execution.run();
    }
  }
}
