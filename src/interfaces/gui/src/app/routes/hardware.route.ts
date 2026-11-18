import { ChangeDetectionStrategy, Component, effect, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
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
        <span class="es-meta">{{ rpc.isConnected() ? 'Live Hardware Bus & Panel Inspector' : 'Connect a session to interact with board hardware.' }}</span>
      </div>

      <div class="hw-body">
        <app-split-pane primarySize="54%" persistKey="hardware-split" [minPrimaryPx]="320" [minSecondaryPx]="300">
          <app-hardware-panel-io pane-primary />
          <div pane-secondary class="right-col">
            <app-hardware-hil-faults />
            <app-hardware-mmio />
          </div>
        </app-split-pane>
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
      .right-col { display: flex; flex-direction: column; height: 100%; min-height: 0; min-width: 0; overflow: auto; }
    `,
  ],
})
export class HardwareRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  private readonly hil = inject(HardwareHilStore);
  private readonly prefs = inject(PreferencesStore);

  protected readonly layout = () => this.prefs.prefs().workbenchLayout;

  constructor() {
    effect(() => {
      if (this.rpc.isConnected()) void this.hil.refreshPartsAndPeripherals();
    });
  }

  protected setLayout(mode: WorkbenchLayoutMode): void {
    this.prefs.setWorkbenchLayout(mode);
  }
}
