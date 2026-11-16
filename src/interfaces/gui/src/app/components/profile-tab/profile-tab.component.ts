import { CommonModule } from '@angular/common';
import { Component, EventEmitter, Output, inject } from '@angular/core';
import { StackReport } from 'ra8-rpc-client';
import { EmulatorService } from '../../services/emulator.service';
import { MetricsPanelComponent } from '../metrics-panel/metrics-panel.component';

@Component({
  selector: 'app-profile-tab',
  standalone: true,
  imports: [CommonModule, MetricsPanelComponent],
  template: `
    <div class="ob-page">
      <div class="ob-card">
        <div class="ob-card-head">
          <div class="ob-row">
            <h2 class="ob-card-title">Compute Timeline</h2>
            <span class="ob-pill ob-pill-accent">1.000 ms Window · 250 us/div</span>
          </div>
          <button type="button" class="ob-btn ob-btn-primary" data-testid="primary-cta" (click)="emu.captureProfileTrace()">
            Capture Trace
          </button>
        </div>
        <div class="ob-card-body">
          @for (core of emu.activeBoardConfig().cores; track core.id; let idx = $index) {
            <div class="ob-lane-row">
              <div class="ob-lane-meta">
                <strong class="mono">{{ core.id }}</strong>
                <span class="ob-muted">{{ core.arch }} &#64; {{ core.clockMhz }} MHz</span>
              </div>
              <div class="ob-track">
                <div class="ob-slice" [style.left.%]="8 + idx * 7" [style.width.%]="idx === 0 ? 44 : 22">
                  {{ idx === 0 ? 'vision_infer + MVE' : 'sensor_poll / DMA' }}
                </div>
                <div class="ob-slice ob-slice-sec" [style.left.%]="62" [style.width.%]="18">
                  {{ core.role }}
                </div>
              </div>
            </div>
          }

          @if (emu.activeBoardConfig().npuEnabled) {
            <div class="ob-lane-row">
              <div class="ob-lane-meta">
                <strong class="mono">NPU0</strong>
                <span class="ob-muted">Ethos-U55 &#64; {{ emu.activeBoardConfig().npuClockMhz }} MHz</span>
              </div>
              <div class="ob-track">
                <div class="ob-slice ob-slice-npu" style="left: 24%; width: 34%;">
                  Conv2D + Depthwise DMA Burst
                </div>
              </div>
            </div>
          }
        </div>
      </div>

      <div class="ob-grid-2">
        <div class="ob-card">
          <div class="ob-card-head">
            <h2 class="ob-card-title">CPU0 Flamegraph · Folded</h2>
            @if (emu.flamegraph().hotspot) {
              <span class="ob-pill ob-pill-err">
                Hotspot: {{ emu.flamegraph().hotspot!.name }} ({{ emu.flamegraph().hotspot!.percentage }}%)
              </span>
            }
          </div>
          <div class="ob-card-body">
            @for (row of emu.flamegraph().rows; track $index) {
              <div class="ob-fg-row">
                @for (node of row; track node.id) {
                  <button
                    type="button"
                    class="ob-fg-frame"
                    [style.left.%]="node.startPct"
                    [style.width.%]="node.widthPct"
                    [style.background]="node.color"
                    (click)="inspectFunction.emit(node.name)"
                    [title]="node.name + ' (' + node.samples + ' samples)'">
                    {{ node.name }} ({{ node.percentage }}%)
                  </button>
                }
              </div>
            }
            <span class="ob-muted">
              Total samples: {{ emu.flamegraph().totalSamples }} · Click any frame to inspect in Debug
            </span>
          </div>
        </div>

        <div class="ob-card">
          <div class="ob-card-head">
            <h2 class="ob-card-title">Stack &amp; Memory Health</h2>
          </div>
          <div class="ob-card-body">
            <div class="ob-subpanel ob-stack">
              <div class="ob-between">
                <span class="mono">CPU0 Stack Utilization</span>
                <span class="mono">{{ stackSummary(emu.cpu0Stack()) }}</span>
              </div>
              <div class="ob-bar-bg">
                <div class="ob-bar-fill" [style.width.%]="stackPercent(emu.cpu0Stack(), 42)"></div>
              </div>
              @if (emu.activeBoardConfig().cores.length > 1) {
                <div class="ob-between">
                  <span class="mono">CPU1 Stack Utilization</span>
                  <span class="mono">{{ stackSummary(emu.cpu1Stack()) }}</span>
                </div>
                <div class="ob-bar-bg">
                  <div class="ob-bar-fill" [style.width.%]="stackPercent(emu.cpu1Stack(), 28)"></div>
                </div>
              }
            </div>
            <app-metrics-panel />
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [
    `:host { display: block; height: 100%; overflow: auto; font-size: 12px; }
     .ob-muted { color: var(--text-secondary); font-size: 12px; }
     .ob-lane-row { display: grid; grid-template-columns: 200px minmax(0, 1fr); gap: 10px; align-items: center; }
     .ob-lane-meta { display: flex; flex-direction: column; }
     .ob-track { position: relative; height: 28px; background: var(--bg-void); border: 1px solid var(--border-hairline); border-radius: var(--radius-sm); overflow: hidden; }
     .ob-slice { position: absolute; top: 3px; bottom: 3px; background: rgba(10,132,255,0.28); border: 1px solid #0A84FF; border-radius: 3px; padding: 0 6px; font-size: 12px; display: flex; align-items: center; white-space: nowrap; overflow: hidden; }
     .ob-slice-sec { background: rgba(48,209,88,0.2); border-color: #30D158; }
     .ob-slice-npu { background: rgba(255,214,10,0.22); border-color: #FFD60A; }
     .ob-fg-row { position: relative; height: 26px; width: 100%; margin-bottom: 3px; }
     .ob-fg-frame { position: absolute; top: 0; bottom: 0; border: 1px solid rgba(255,255,255,0.18); color: #F2F2F7; font-size: 12px; text-align: left; padding: 0 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
     .ob-bar-bg { height: 8px; background: var(--bg-void); border-radius: 4px; overflow: hidden; }
     .ob-bar-fill { height: 100%; background: var(--accent); }`,
  ],
})
export class ProfileTabComponent {
  public readonly emu = inject(EmulatorService);
  @Output() public readonly inspectFunction = new EventEmitter<string>();

  public stackPercent(report: StackReport | null, fallbackPct: number): number {
    if (!report || !report.hasStack || report.size <= 0) return fallbackPct;
    const sp = report.lowMsp > 0 ? report.lowMsp : report.msp;
    const used = Math.max(0, Math.min(report.size, report.base - sp));
    return Math.round((used / report.size) * 100);
  }

  public stackSummary(report: StackReport | null): string {
    if (!report || !report.hasStack) return '42% estimated (connect target for watermark)';
    return `${this.stackPercent(report, 0)}% (${report.size}B window${report.overflow ? ' · OVERFLOW' : ''})`;
  }
}
