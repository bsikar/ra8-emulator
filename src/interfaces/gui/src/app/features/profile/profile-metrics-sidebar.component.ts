import { ChangeDetectionStrategy, Component, computed, inject } from '@angular/core';
import type { StackReport } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../../shared/ui/status-dot.component';
import { NEVER_LOW_SP, computePspWatermark, formatStackSummary } from '../../shared/utils/stack-math';

interface PspDisplayState {
  summary: string;
  percentUsed: number;
  nearLimit: boolean;
}

function toSparklinePoints(values: readonly number[], maxFloor = 100): string {
  if (values.length === 0) return '';
  const peak = Math.max(1, maxFloor, ...values);
  return values
    .map((val, idx) => {
      const x = values.length === 1 ? 0 : Math.round((idx * 160) / (values.length - 1));
      const y = Math.round(26 - (Math.max(0, val) / peak) * 22);
      return `${x},${y}`;
    })
    .join(' ');
}

function computePspDisplay(rep: StackReport | null): PspDisplayState {
  const wm = computePspWatermark(rep, rep?.base ?? 0);
  if (!rep || !rep.hasStack || rep.size <= 0 || !wm.touched) {
    return { summary: wm.summary, percentUsed: 0, nearLimit: wm.nearLimit };
  }
  const effective = wm.lowPsp !== NEVER_LOW_SP ? wm.lowPsp : wm.psp;
  const top = (rep.base >>> 0) + (rep.size >>> 0);
  const rawUsed = top >= effective ? top - effective : 0;
  const used = Math.max(0, Math.min(rep.size >>> 0, rawUsed));
  const percentUsed = Math.min(100, Math.round((used / (rep.size >>> 0)) * 100));
  return {
    summary: wm.summary,
    percentUsed,
    nearLimit: wm.nearLimit || percentUsed >= 85,
  };
}

@Component({
  selector: 'app-profile-metrics-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent],
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
          <div class="kv-row"><span>CPU0 Load / RAM</span><span class="mono">{{ m.cpu0LoadPercent }}% · {{ formatRam(m.cpu0RamUsedBytes, m.cpu0RamTotalBytes) }}</span></div>
          @if (execution.cpu1Attached()) {
            <div class="kv-row"><span>CPU1 Load / RAM</span><span class="mono">{{ m.cpu1LoadPercent }}% · {{ formatRam(m.cpu1RamUsedBytes, m.cpu1RamTotalBytes) }}</span></div>
          }
          <div class="kv-row">
            <span>Real-Time Pacing</span>
            <span class="kv-val mono">
              <span>{{ pacingLabel() }}</span>
              @if (pacingBottleneck()) {
                <app-status-dot tone="fault" label="Slow (<0.35x)" data-testid="profile-pacing-alert" />
              }
            </span>
          </div>
          @if (pinnedAlertLabel(); as pinMsg) {
            <div class="kv-row" data-testid="profile-pinned-alert">
              <span>Host Saturation</span>
              <app-status-dot tone="fault" [label]="pinMsg" />
            </div>
          }

          @if (cpuSparkPoints()) {
            <div class="spark-wrap">
              <span class="es-meta">Host CPU Trend</span>
              <svg viewBox="0 0 160 28" class="spark-svg" data-testid="profile-cpu-sparkline" aria-hidden="true">
                <polyline [attr.points]="cpuSparkPoints()" fill="none" stroke="currentColor" stroke-width="1.5" />
              </svg>
            </div>
          }
          @if (rssSparkPoints()) {
            <div class="spark-wrap">
              <span class="es-meta">Host RSS Trend</span>
              <svg viewBox="0 0 160 28" class="spark-svg" data-testid="profile-rss-sparkline" aria-hidden="true">
                <polyline [attr.points]="rssSparkPoints()" fill="none" stroke="currentColor" stroke-width="1.5" />
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
          <span class="kv-val mono">
            <span [class.fault-txt]="cpu0Psp().nearLimit">{{ cpu0Psp().summary }}</span>
            @if (cpu0Psp().nearLimit) {
              <app-status-dot tone="fault" label="Near PSPLIM" data-testid="profile-cpu0-psp-alert" />
            }
          </span>
        </div>
        <div class="stack-bar"><div class="stack-fill" [class.is-fault]="cpu0Psp().nearLimit" [style.width.%]="cpu0Psp().percentUsed"></div></div>

        @if (execution.cpu1Attached()) {
          <div class="kv-row"><span>CPU1 MSP</span><span class="mono">{{ cpu1Summary() }}</span></div>
          <div class="stack-bar"><div class="stack-fill" [style.width.%]="profile.cpu1StackMetrics().percentUsed"></div></div>

          <div class="kv-row">
            <span>CPU1 PSP</span>
            <span class="kv-val mono">
              <span [class.fault-txt]="cpu1Psp().nearLimit">{{ cpu1Psp().summary }}</span>
              @if (cpu1Psp().nearLimit) {
                <app-status-dot tone="fault" label="Near PSPLIM" data-testid="profile-cpu1-psp-alert" />
              }
            </span>
          </div>
          <div class="stack-bar"><div class="stack-fill" [class.is-fault]="cpu1Psp().nearLimit" [style.width.%]="cpu1Psp().percentUsed"></div></div>
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
      .sec-head, .kv-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 12px; color: var(--es-text-secondary); min-width: 0; flex-wrap: wrap; }
      .kv-val { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .task-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--es-text-primary); min-width: 0; }
      .spark-wrap { display: flex; flex-direction: column; gap: 2px; margin-top: 4px; color: var(--es-signal-cursor); }
      .spark-svg { width: 100%; height: 28px; background: var(--es-chrome); border: 1px solid var(--es-divider); }
      .stack-bar { height: 4px; background: var(--es-interactive-high); border-radius: var(--es-radius-sm); overflow: hidden; }
      .stack-fill { height: 100%; background: var(--es-signal-cursor); }
      .stack-fill.is-fault { background: var(--es-signal-fault); }
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
  protected readonly pacingBottleneck = computed(() => {
    const r = this.profile.pacingRatio();
    return r !== null && r < 0.35;
  });
  protected readonly pinnedAlertLabel = computed(() => {
    const m = this.profile.metrics();
    if (!m) return '';
    const c0 = m.cpu0Pinned > 0;
    const c1 = this.execution.cpu1Attached() && m.cpu1Pinned > 0;
    if (c0 && c1) return 'CPU0 + CPU1 Pinned';
    if (c0) return 'CPU0 Pinned';
    if (c1) return 'CPU1 Pinned';
    return '';
  });

  protected readonly cpuSparkPoints = computed(() => toSparklinePoints(this.profile.hostCpuHistory(), 100));
  protected readonly rssSparkPoints = computed(() => toSparklinePoints(this.profile.hostRssHistory(), 1));
  protected readonly cpu0Summary = computed(() => formatStackSummary(this.profile.cpu0Stack()));
  protected readonly cpu1Summary = computed(() => formatStackSummary(this.profile.cpu1Stack()));
  protected readonly cpu0Psp = computed(() => computePspDisplay(this.profile.cpu0Stack()));
  protected readonly cpu1Psp = computed(() => computePspDisplay(this.profile.cpu1Stack()));

  protected formatRam(usedBytes: number, totalBytes: number): string {
    const usedKb = Math.round(usedBytes / 1024);
    if (totalBytes <= 0) return `${usedKb} KiB`;
    return `${usedKb} / ${Math.round(totalBytes / 1024)} KiB`;
  }

  protected refreshNow(): void {
    void this.profile.refreshMetrics();
    void this.profile.refreshStacks(this.execution.cpu1Attached());
  }
}
