import { ChangeDetectionStrategy, Component, computed, effect, inject, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { DebugStore } from '../../core/stores/debug.store';
import { HardwareHilStore } from '../../core/stores/hardware-hil.store';
import { PreferencesStore } from '../../core/stores/preferences.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatHex32 } from '../../shared/utils/hex';
import { DebugMemoryPaneComponent } from './debug-memory-pane.component';
import {
  type InspectorTab,
  type RegisterDisplayRow,
  type RegisterGroupTab,
  filterRegisterEntries,
  parseRegisterOrMemoryValue,
} from './debug-view';

@Component({
  selector: 'app-debug-inspector-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, DebugMemoryPaneComponent],
  template: `
    <div class="insp-pane">
      <div class="insp-head">
        <div class="head-left">
          <app-section-kicker label="CORE REGISTERS" />
          <span class="mono es-meta">CPU{{ debug.activeCore() }}</span>
        </div>
        <div class="tab-strip">
          <button
            type="button"
            class="seg-tab"
            [class.is-active]="activeTab() === 'registers'"
            data-testid="debug-tab-registers"
            (click)="activeTab.set('registers')"
          >
            Registers (Δ <span class="mono">{{ changedCount() }}</span>)
          </button>
          <button
            type="button"
            class="seg-tab"
            [class.is-active]="activeTab() === 'memory'"
            data-testid="debug-tab-memory"
            (click)="openMemoryTab()"
          >
            Memory
          </button>
          <button
            type="button"
            class="seg-tab"
            [class.is-active]="activeTab() === 'peripherals'"
            data-testid="debug-tab-peripherals"
            (click)="openPeripheralsTab()"
          >
            Peripherals
          </button>
        </div>
      </div>

      @if (activeTab() === 'registers') {
        <div class="group-bar">
          <button
            type="button"
            class="grp-btn"
            [class.is-active]="regGroup() === 'gpr'"
            data-testid="debug-reg-group-gpr"
            (click)="regGroup.set('gpr')"
          >
            GPR
          </button>
          <button
            type="button"
            class="grp-btn"
            [class.is-active]="regGroup() === 'mve'"
            data-testid="debug-reg-group-mve"
            (click)="regGroup.set('mve')"
          >
            MVE
          </button>
          <button
            type="button"
            class="grp-btn"
            [class.is-active]="regGroup() === 'sys'"
            data-testid="debug-reg-group-sys"
            (click)="regGroup.set('sys')"
          >
            Sys
          </button>
        </div>

        @if (rpc.isConnected()) {
          <div class="reg-grid">
            @for (row of regRows(); track row.name) {
              <div
                class="reg-cell"
                [class.is-changed]="row.changed"
                [class.is-dimmed]="row.dimmed"
                [attr.data-reg]="row.name"
              >
                <span class="reg-name mono">{{ row.label }}</span>
                @if (editingReg() === row.name) {
                  <form class="reg-edit" (submit)="commitReg($event, row)">
                    <input
                      type="text"
                      class="reg-input mono"
                      data-testid="debug-reg-edit-input"
                      [value]="regDraft()"
                      (input)="onRegInput($event)"
                      (keydown.escape)="editingReg.set(null)"
                      aria-label="Edit register hex value"
                    />
                  </form>
                } @else {
                  <button
                    type="button"
                    class="reg-val mono"
                    [disabled]="rpc.observeOnly()"
                    (click)="beginEdit(row)"
                  >
                    {{ row.hex }}
                  </button>
                }
              </div>
            }
          </div>
        } @else {
          <p class="es-meta note">Connect a session to inspect registers.</p>
        }
      } @else if (activeTab() === 'memory') {
        <app-debug-memory-pane />
      } @else {
        <div class="periph-box">
          <div class="chip-row">
            @for (blk of periphChips(); track blk) {
              <button
                type="button"
                class="grp-btn mono"
                [class.is-active]="hil.selectedPeriphBlock() === blk"
                (click)="hil.selectPeriphBlock(blk, debug.activeCore())"
              >
                {{ blk }}
              </button>
            }
          </div>
          @if (hil.selectedPeriphText(); as dump) {
            <pre class="periph-pre mono">{{ dump }}</pre>
          } @else {
            <p class="es-meta note">Select a peripheral block to inspect MMIO registers.</p>
          }
        </div>
      }
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .insp-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; }
      .insp-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); flex-wrap: wrap; }
      .head-left, .tab-strip, .group-bar, .chip-row { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .group-bar, .chip-row { padding: 6px 12px; border-bottom: 1px solid var(--es-divider); }
      .seg-tab { border: 0; border-bottom: 2px solid transparent; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 3px 4px; cursor: pointer; }
      .seg-tab.is-active { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .grp-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-muted); border-radius: var(--es-radius-sm); font-size: 12px; padding: 1px 8px; cursor: pointer; }
      .grp-btn.is-active { color: var(--es-text-primary); background: var(--es-interactive); border-color: var(--es-signal-cursor); }
      .reg-grid { display: grid; grid-template-columns: repeat(2, minmax(140px, 1fr)); gap: 0 10px; padding: 6px 12px; overflow: auto; }
      .reg-cell { display: flex; align-items: center; justify-content: space-between; gap: 6px; min-height: 24px; padding: 2px 6px; border-left: 2px solid transparent; border-bottom: 1px solid var(--es-divider); font-size: 12px; min-width: 0; }
      .reg-cell.is-changed { border-left-color: var(--es-signal-cursor); }
      .reg-cell.is-dimmed { opacity: 0.45; }
      .reg-name { color: var(--es-text-muted); }
      .reg-val { border: 0; background: transparent; color: var(--es-text-secondary); font-size: 12px; padding: 0; cursor: pointer; }
      .reg-cell.is-changed .reg-val { color: var(--es-text-primary); }
      .reg-edit { display: inline-flex; }
      .reg-input { width: 92px; background: var(--es-container); border: 1px solid var(--es-signal-cursor); color: var(--es-text-primary); font-size: 12px; padding: 1px 4px; }
      .periph-box { display: flex; flex-direction: column; flex: 1; overflow: auto; }
      .periph-pre { margin: 0; padding: 8px 12px; font-size: 12px; color: var(--es-text-secondary); white-space: pre-wrap; }
      .note { margin: 8px 12px; }
    `,
  ],
})
export class DebugInspectorPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly debug = inject(DebugStore);
  protected readonly hil = inject(HardwareHilStore);
  protected readonly prefs = inject(PreferencesStore);

  protected readonly activeTab = signal<InspectorTab>('registers');
  protected readonly regGroup = signal<RegisterGroupTab>('gpr');
  protected readonly editingReg = signal<string | null>(null);
  protected readonly regDraft = signal<string>('');

  protected readonly regRows = computed(() =>
    filterRegisterEntries(
      this.regGroup(),
      this.debug.registers(),
      this.debug.previousRegisters(),
      this.prefs.prefs().dimZeroRegisters
    )
  );

  protected readonly changedCount = computed(
    () => this.regRows().filter((r) => r.changed).length
  );

  protected readonly periphChips = computed(() => {
    const blocks = this.hil.periphBlocks();
    return blocks.length > 0 ? blocks.slice(0, 8) : ['GLCDC', 'SCI8', 'RIIC0', 'GPT', 'ICU', 'IPC'];
  });

  constructor() {
    effect(() => {
      const core = this.debug.activeCore();
      const blk = this.hil.selectedPeriphBlock();
      if (this.activeTab() === 'peripherals' && this.rpc.isConnected() && blk) {
        void this.hil.selectPeriphBlock(blk, core);
      }
    });
  }

  protected openMemoryTab(): void {
    this.activeTab.set('memory');
    if (this.rpc.isConnected() && this.debug.memoryBytes().length === 0) {
      void this.debug.readMemoryPage(this.debug.memoryAddress(), 256, this.debug.activeCore(), true);
    }
  }

  protected openPeripheralsTab(): void {
    this.activeTab.set('peripherals');
    if (this.rpc.isConnected() && this.hil.periphBlocks().length === 0) {
      void this.hil.refreshPartsAndPeripherals(this.debug.activeCore());
    }
  }

  protected beginEdit(row: RegisterDisplayRow): void {
    if (this.rpc.observeOnly()) return;
    this.editingReg.set(row.name);
    this.regDraft.set(formatHex32(row.value));
  }

  protected onRegInput(event: Event): void {
    this.regDraft.set((event.target as HTMLInputElement).value);
  }

  protected async commitReg(event: Event, row: RegisterDisplayRow): Promise<void> {
    event.preventDefault();
    const parsed = parseRegisterOrMemoryValue(this.regDraft());
    if (parsed !== null) {
      await this.debug.writeRegister(row.reg, parsed, this.debug.activeCore());
    }
    this.editingReg.set(null);
  }
}
