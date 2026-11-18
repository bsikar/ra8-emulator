import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { type FlamegraphNode, getTopHotspots, toIcicleRows } from '../../shared/utils/flamegraph';

@Component({
  selector: 'app-profile-flamegraph-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="fg-pane">
      <div class="fg-head">
        <div class="grp">
          <app-section-kicker label="FOLDED STACK PROFILE" />
          <div class="seg-group">
            <button type="button" class="seg-tab" [class.is-active]="mode() === 'flame'" data-testid="profile-mode-flame" (click)="mode.set('flame')">Flamegraph</button>
            <button type="button" class="seg-tab" [class.is-active]="mode() === 'icicle'" data-testid="profile-mode-icicle" (click)="mode.set('icicle')">Icicle</button>
          </div>
          @if (execution.cpu1Attached()) {
            <select class="es-select mono" aria-label="Profile core" [value]="activeCore()" (change)="onCoreChange($event)">
              <option [value]="cpu0">CPU0</option>
              <option [value]="cpu1">CPU1</option>
            </select>
          }
        </div>
        <div class="grp">
          @if (zoomNodeId()) {
            <button type="button" class="mini-btn" (click)="zoomNodeId.set(null)">Reset Zoom</button>
          }
          <button type="button" class="mini-btn" data-testid="profile-capture-all-btn" [disabled]="!rpc.isConnected()" (click)="captureAll()">Capture All</button>
        </div>
      </div>

      <div class="fg-body">
        @if (profile.flamegraph().totalSamples > 0) {
          <div class="rows-box">
            @for (row of displayRows(); track $index) {
              <div class="fg-row">
                @for (node of row; track node.id) {
                  <button
                    type="button"
                    class="fg-bar mono"
                    [class.is-hotspot]="node.isHotspot"
                    [style.width.%]="scaledWidth(node)"
                    [title]="node.name + ' (' + node.samples + ' samples, ' + node.percentage + '%)'"
                    (click)="zoomNodeId.set(node.id)"
                  >
                    {{ node.name }} ({{ node.percentage }}%)
                  </button>
                }
              </div>
            }
          </div>

          <div class="hotspots-box">
            <app-section-kicker label="TOP HOTSPOTS" />
            @for (spot of hotspots(); track spot.id) {
              <div class="spot-row mono">
                <span class="spot-name">{{ spot.name }}</span>
                <span class="es-meta">{{ spot.selfSamples }} self · {{ spot.samples }} total ({{ spot.percentage }}% · {{ spot.timeMs }} ms)</span>
              </div>
            }
          </div>
        } @else {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'No folded stack samples yet (run with --profile-folded and Capture All).' : 'Connect a session to capture folded stacks.' }}
          </p>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .fg-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .fg-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .grp, .seg-group { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .seg-tab { border: 0; border-bottom: 2px solid transparent; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 2px 4px; cursor: pointer; }
      .seg-tab.is-active { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .fg-body { flex: 1; min-height: 0; overflow: auto; padding: 8px 12px; display: flex; flex-direction: column; gap: 12px; }
      .rows-box { display: flex; flex-direction: column; gap: 3px; }
      .fg-row { display: flex; gap: 2px; min-height: 24px; width: 100%; overflow: hidden; }
      .fg-bar { border: 1px solid var(--es-border); background: var(--es-container); color: var(--es-text-secondary); font-size: 12px; padding: 2px 6px; text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; min-width: 24px; }
      .fg-bar.is-hotspot { border-color: var(--es-signal-cursor); background: var(--es-interactive); color: var(--es-text-primary); }
      .hotspots-box { display: flex; flex-direction: column; gap: 4px; border-top: 1px solid var(--es-divider); padding-top: 8px; }
      .spot-row { display: flex; justify-content: space-between; gap: 8px; font-size: 12px; padding: 3px 0; border-bottom: 1px solid var(--es-divider); min-width: 0; }
      .spot-name { color: var(--es-text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
      .note { margin: 8px 0; }
    `,
  ],
})
export class ProfileFlamegraphPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly profile = inject(ProfileStore);

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly mode = signal<'flame' | 'icicle'>('flame');
  protected readonly activeCore = signal<Core>(Core.Cpu0);
  protected readonly zoomNodeId = signal<string | null>(null);

  protected readonly zoomedNode = computed<FlamegraphNode | null>(() => {
    const id = this.zoomNodeId();
    return id ? this.profile.flamegraph().nodes.find((n) => n.id === id) ?? null : null;
  });

  protected readonly displayRows = computed<FlamegraphNode[][]>(() => {
    const view = this.profile.flamegraph();
    const rawRows = this.mode() === 'icicle' ? view.rows : toIcicleRows(view);
    const zoom = this.zoomedNode();
    if (!zoom) return rawRows;
    const zEnd = zoom.startPct + zoom.widthPct;
    return rawRows
      .map((row) => row.filter((n) => n.startPct >= zoom.startPct - 0.01 && n.startPct + n.widthPct <= zEnd + 0.01))
      .filter((row) => row.length > 0);
  });

  protected readonly hotspots = computed(() => getTopHotspots(this.profile.flamegraph(), 8));

  protected scaledWidth(node: FlamegraphNode): number {
    const zoom = this.zoomedNode();
    if (!zoom || zoom.widthPct <= 0) return Math.max(2, node.widthPct);
    return Math.min(100, Math.max(2, (node.widthPct / zoom.widthPct) * 100));
  }

  protected onCoreChange(event: Event): void {
    const parsed = Number.parseInt((event.target as HTMLSelectElement).value, 10);
    this.activeCore.set(parsed === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0);
  }

  protected captureAll(): void {
    this.zoomNodeId.set(null);
    void this.profile.captureFolded(this.activeCore());
  }
}
