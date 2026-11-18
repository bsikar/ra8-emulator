import { ChangeDetectionStrategy, Component, computed, inject } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { computePspWatermark, formatStackSummary } from '../../shared/utils/stack-math';

function toSparklinePoints(values: readonly number[], maxVal = 100): string {
  if (values.length === 0) return '';
  const peak = Math.max(1, maxVal, ...values);
  return values
    .map((val, idx) => {
      const x = values.length === 1 ? 0 : Math.round((idx * 160) / (values.length - 1));
      const y = Math.round(26 - (Math.max(0, val) / peak) * 22);
      return `${x},${y}`;
    })
    .join(' ');
}

@Component({
  selector: 'app-profile-metrics-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <aside class="metrics-side">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="METRICS & STACKS" />
          <button type="button" class="mini-btn" data-testid="profile-refresh-btn" [disabled]="!rpc.isConnected()" (click)="refreshNow()">Refresh</button>
        </div>

        @if (profile.metrics(); as m) {
          <div class="kv-row"><span>Host CPU / Threads</span><span class="mono">{{ m.hostCpuPercent }}% · {{ m.hostThreads }} thr</span></div>
          <div class="kv-row"><span>Host Memory RSS</span><span class="mono">{{ m.hostRssMb }} MiB</span></div>
          <div class="kv-row"><span>CPU0 Load / RAM</span><span class="mono">{{ m.cpu0LoadPercent }}% · {{ formatKb(m.cpu0RamUsedBytes) }}</span></div>
          @if (execution.cpu1Attached()) {
            <div class="kv-row"><span>CPU1 Load / RAM</span><span class="mono">{{ m.cpu1LoadPercent }}% · {{ formatKb(m.cpu1RamUsedBytes) }}</span></div>
          }
          <div class="kv-row"><span>Real-Time Pacing</span><span class="mono">{{ pacingLabel() }}</span></div>

          @if (cpuSparkPoints()) {
            <div class="spark-wrap">
              <span class="es-meta">Host CPU Trend</span>
              <svg viewBox="0 0 160 28" class="spark-svg" aria-hidden="true">
                <polyline [attr.points]="cpuSparkPoints()" fill="none" stroke="currentColor" stroke-width="1.5" />
              </svg>
            </div>
          }
        } @else {
          <p class="es-meta note">{{ rpc.isConnected() ? 'Awaiting metrics sample...' : 'Connect a session to view telemetry.' }}</p>
        }
      </section>

      <section class="sec">
        <app-section-kicker label="STACK WATERMARKS" />
        <div class="kv-row"><span>CPU0 MSP</span><span class="mono">{{ cpu0Summary() }}</span></div>
        <div class="stack-bar"><div class="stack-fill" [style.width.%]="profile.cpu0StackMetrics().percentUsed"></div></div>
        <div class="kv-row">
          <span>CPU0 PSP</span>
          <span class="mono" [class.fault-txt]="cpu0Psp().nearLimit">
            {{ cpu0Psp().summary }}{{ cpu0Psp().nearLimit ? ' · Near PSPLIM' : '' }}
          </span>
        </div>
        @if (execution.cpu1Attached()) {
          <div class="kv-row"><span>CPU1 MSP</span><span class="mono">{{ cpu1Summary() }}</span></div>
          <div class="stack-bar"><div class="stack-fill" [style.width.%]="profile.cpu1StackMetrics().percentUsed"></div></div>
        }
      </section>

      <section class="sec">
        <app-section-kicker label="RTOS TASK SHARE" />
        @if (profile.rtosTasks().length > 0) {
          @for (task of profile.rtosTasks(); track task.key) {
            <div class="kv-row mono">
              <span class="task-name">CPU{{ task.core }} · {{ task.name }}</span>
              <span>{{ task.switches }} ({{ task.sharePercent }}%)</span>
            </div>
          }
        } @else {
          <p class="es-meta note">No RTOS thread switches recorded.</p>
        }
      </section>
    </aside>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .metrics-side { display: flex; flex-direction: column; height: 100%; overflow: auto; background: var(--es-canvas); }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 6px; min-width: 0; }
      .sec-head, .kv-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 12px; color: var(--es-text-secondary); min-width: 0; }
      .task-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--es-text-primary); min-width: 0; }
      .spark-wrap { display: flex; flex-direction: column; gap: 2px; margin-top: 4px; color: var(--es-signal-cursor); }
      .spark-svg { width: 100%; height: 28px; background: var(--es-chrome); border: 1px solid var(--es-divider); }
      .stack-bar { height: 4px; background: var(--es-interactive-high); border-radius: var(--es-radius-sm); overflow: hidden; }
      .stack-fill { height: 100%; background: var(--es-signal-cursor); }
      .fault-txt { color: var(--es-signal-fault); }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .note { margin: 0; }
    `,
  ],
})
export class ProfileMetricsSidebarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly profile = inject(ProfileStore);

  protected readonly pacingLabel = computed(() => {
    const r = this.profile.pacingRatio();
    return r === null ? '--' : `${r.toFixed(2)}x`;
  });
  protected readonly cpuSparkPoints = computed(() => toSparklinePoints(this.profile.hostCpuHistory(), 100));
  protected readonly cpu0Summary = computed(() => formatStackSummary(this.profile.cpu0Stack()));
  protected readonly cpu1Summary = computed(() => formatStackSummary(this.profile.cpu1Stack()));
  protected readonly cpu0Psp = computed(() => {
    const rep = this.profile.cpu0Stack();
    return computePspWatermark(rep, rep?.base ?? 0);
  });

  protected formatKb(bytes: number): string {
    return `${Math.round(bytes / 1024)} KiB`;
  }

  protected refreshNow(): void {
    void this.profile.refreshMetrics();
    void this.profile.refreshStacks(this.execution.cpu1Attached());
  }
}
