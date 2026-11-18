import { ChangeDetectionStrategy, Component, computed, effect, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { BoardStore } from '../core/stores/board.store';
import { HardwareHilStore } from '../core/stores/hardware-hil.store';
import { PreferencesStore, type WorkbenchLayoutMode } from '../core/stores/preferences.store';
import { HardwareHilFaultsComponent } from '../features/hardware/hardware-hil-faults.component';
import { HardwareMmioComponent } from '../features/hardware/hardware-mmio.component';
import { HardwarePanelIoComponent } from '../features/hardware/hardware-panel-io.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-hardware-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, HardwarePanelIoComponent, HardwareHilFaultsComponent, HardwareMmioComponent],
  template: `
    <div class="hw-shell">
      <div class="hw-toolbar">
        <div class="layout-switcher" data-testid="hardware-layout-switcher">
          <button type="button" class="sw-tab" [class.is-active]="layout() === 'board'" (click)="setLayout('board')">Board</button>
          <button type="button" class="sw-tab" [class.is-active]="layout() === 'debugger'" (click)="setLayout('debugger')">Debugger</button>
          <button type="button" class="sw-tab" [class.is-active]="layout() === 'split'" (click)="setLayout('split')">Split</button>
        </div>
        <span class="es-meta mono">{{ statusSummary() }}</span>
      </div>

      <div class="hw-body">
        @if (layout() === 'board') {
          <app-split-pane primarySize="52%" persistKey="hardware-board-split" [minPrimaryPx]="320" [minSecondaryPx]="300">
            <app-hardware-panel-io pane-primary />
            <app-hardware-hil-faults pane-secondary />
          </app-split-pane>
        } @else if (layout() === 'debugger') {
          <app-split-pane primarySize="46%" persistKey="hardware-debug-split" [minPrimaryPx]="300" [minSecondaryPx]="320">
            <app-hardware-hil-faults pane-primary />
            <app-hardware-mmio pane-secondary />
          </app-split-pane>
        } @else {
          <app-split-pane primarySize="34%" persistKey="hardware-col1-split" [minPrimaryPx]="310" [minSecondaryPx]="600">
            <app-hardware-panel-io pane-primary />
            <app-split-pane pane-secondary primarySize="49%" persistKey="hardware-col2-split" [minPrimaryPx]="290" [minSecondaryPx]="300">
              <app-hardware-hil-faults pane-primary />
              <app-hardware-mmio pane-secondary />
            </app-split-pane>
          </app-split-pane>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; }
      .hw-shell { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .hw-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .layout-switcher { display: inline-flex; border: 1px solid var(--es-border); border-radius: var(--es-radius); overflow: hidden; background: var(--es-container); }
      .sw-tab { border: 0; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 3px 10px; cursor: pointer; }
      .sw-tab.is-active { background: var(--es-interactive); color: var(--es-text-primary); }
      .hw-body { flex: 1; min-height: 0; min-width: 0; }
    `,
  ],
})
export class HardwareRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  private readonly board = inject(BoardStore);
  private readonly hil = inject(HardwareHilStore);
  private readonly prefs = inject(PreferencesStore);

  protected readonly layout = () => this.prefs.prefs().workbenchLayout;

  protected readonly statusSummary = computed(() => {
    const target = this.board.selectedPreset()?.targetId.toUpperCase() || this.board.boardProfileName().toUpperCase();
    const faults = this.hil.fittedParts().filter((p) => p.activeFault !== null).length;
    if (!this.rpc.isConnected()) return `${target} · Offline — connect a session to inspect board hardware.`;
    return `${target} · ${faults} active HIL fault(s) · ${this.hil.periphBlocks().length} MMIO blocks`;
  });

  constructor() {
    effect(() => {
      if (this.rpc.isConnected()) void this.hil.refreshPartsAndPeripherals();
    });
  }

  protected setLayout(mode: WorkbenchLayoutMode): void {
    this.prefs.setWorkbenchLayout(mode);
  }
}
