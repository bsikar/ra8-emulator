import { ChangeDetectionStrategy, Component, computed, effect, inject, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { HardwareHilStore } from '../../core/stores/hardware-hil.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { parseHexAddress } from '../../shared/utils/hex';
import {
  CORE_SYSTEM_MMIO_ADDRESSES,
  MMIO_QUICK_BLOCKS,
  filterPeriphBlocks,
  findQuickBlockMatch,
  formatMmioHexDump,
  parsePeriphDump,
} from './hardware-mmio-parser';

export { formatMmioHexDump };

@Component({
  selector: 'app-hardware-mmio',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="mmio-box">
      <div class="sec-head">
        <app-section-kicker label="MMIO PERIPHERALS" />
        <select
          class="es-select mono"
          aria-label="Peripheral core"
          data-testid="hardware-mmio-core"
          [value]="activeCore()"
          (change)="onCoreChange($event)"
        >
          <option [value]="cpu0">CPU0 · M85</option>
          @if (execution.cpu1Attached()) {
            <option [value]="cpu1">CPU1 · M33</option>
          }
        </select>
      </div>

      <input
        type="text"
        class="es-input mono"
        data-testid="hardware-mmio-filter"
        [value]="blockFilter()"
        (input)="onFilterInput($event)"
        placeholder="Filter peripheral or 0x40..."
      />

      <div class="chip-row" role="group" aria-label="Quick peripheral blocks">
        @for (chip of quickBlocks; track chip) {
          <button
            type="button"
            class="chip-btn mono"
            [class.is-active]="isQuickChipActive(chip)"
            [attr.data-testid]="'hardware-mmio-chip-' + chip"
            (click)="selectQuickChip(chip)"
          >
            {{ chip }}
          </button>
        }
      </div>

      <div class="block-bar">
        <select
          class="es-select mono block-sel"
          aria-label="Peripheral block"
          data-testid="hardware-periph-select"
          [value]="hil.selectedPeriphBlock()"
          (change)="onBlockChange($event)"
        >
          @for (blk of filteredBlocks(); track blk) {
            <option [value]="blk">{{ blk }}</option>
          }
        </select>
        <form class="raw-form" (submit)="readRawMmio($event)">
          <input
            type="text"
            class="es-input mono addr-in"
            data-testid="hardware-mmio-addr"
            [value]="rawAddr()"
            (input)="onRawAddrInput($event)"
            placeholder="0x40000000"
          />
          <button type="submit" class="mini-btn" data-testid="hardware-mmio-read-btn" [disabled]="!rpc.isConnected()">Read 64B</button>
        </form>
      </div>

      @if (rawDump()) {
        <pre class="mmio-pre mono" data-testid="hardware-mmio-raw">{{ rawDump() }}</pre>
      } @else if (parsedDump().kind === 'registers' && parsedDump().registers.length > 0) {
        <div class="reg-tree" data-testid="hardware-mmio-tree">
          @for (reg of parsedDump().registers; track reg.name) {
            <div class="reg-item">
              <button type="button" class="reg-row mono" (click)="toggleRegister(reg.name)">
                <span class="reg-name">{{ isExpanded(reg.name) ? '▾' : '▸' }} {{ reg.name }} <span class="es-meta">+{{ reg.offsetHex }}</span></span>
                <span class="reg-val">{{ reg.valueHex ?? 'descriptor' }}</span>
              </button>
              @if (isExpanded(reg.name)) {
                <div class="reg-fields mono">
                  <div class="field-row es-meta"><span>Width</span><span>{{ reg.widthBits ? reg.widthBits + '-bit' : '32-bit' }}</span></div>
                  @for (sl of reg.slices; track sl.label) {
                    <div class="field-row"><span>{{ sl.label }}</span><span>{{ sl.valueHex }}</span></div>
                  }
                </div>
              }
            </div>
          }
        </div>
      } @else if (hil.selectedPeriphText()) {
        <pre class="mmio-pre mono" data-testid="hardware-mmio-dump">{{ hil.selectedPeriphText() }}</pre>
      } @else {
        <p class="es-meta note">Select a peripheral block or read a 64-byte MMIO window.</p>
      }
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: auto; }
      .mmio-box { padding: 10px 12px; display: flex; flex-direction: column; gap: 8px; height: 100%; min-height: 0; min-width: 0; background: var(--es-canvas); }
      .sec-head, .block-bar, .raw-form, .chip-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .sec-head, .block-bar { justify-content: space-between; }
      .block-sel { max-width: 130px; }
      .raw-form { flex: 1; min-width: 150px; }
      .addr-in { min-width: 88px; }
      .chip-btn, .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 7px; cursor: pointer; }
      .chip-btn.is-active { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .es-input { flex: 1; min-width: 0; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .reg-tree { flex: 1; min-height: 0; overflow: auto; border-top: 1px solid var(--es-border); }
      .reg-item { border-bottom: 1px solid var(--es-divider); }
      .reg-row { width: 100%; display: flex; justify-content: space-between; gap: 8px; padding: 5px 4px; background: transparent; border: 0; color: var(--es-text-primary); font-size: 12px; cursor: pointer; text-align: left; }
      .reg-row:hover { background: var(--es-interactive); }
      .reg-fields { padding: 4px 12px 6px; display: flex; flex-direction: column; gap: 2px; background: var(--es-chrome); font-size: 12px; color: var(--es-text-secondary); }
      .field-row { display: flex; justify-content: space-between; }
      .mmio-pre { flex: 1; min-height: 0; overflow: auto; margin: 0; padding: 8px; background: var(--es-chrome); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; color: var(--es-text-secondary); white-space: pre-wrap; word-break: break-word; }
      .note { margin: 0; font-size: 12px; }
    `,
  ],
})
export class HardwareMmioComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly hil = inject(HardwareHilStore);
  protected readonly execution = inject(ExecutionStore);

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly quickBlocks = MMIO_QUICK_BLOCKS;
  protected readonly activeCore = signal<Core>(Core.Cpu0);
  protected readonly blockFilter = signal<string>('');
  protected readonly rawAddr = signal<string>('0x40000000');
  protected readonly rawDump = signal<string>('');
  protected readonly liveBlockBytes = signal<Uint8Array | null>(null);
  protected readonly expandedRegs = signal<ReadonlySet<string>>(new Set());

  protected readonly filteredBlocks = computed(() =>
    filterPeriphBlocks(this.hil.periphBlocks(), this.blockFilter())
  );

  protected readonly parsedDump = computed(() =>
    parsePeriphDump(this.hil.selectedPeriphText(), this.liveBlockBytes())
  );

  constructor() {
    effect(() => {
      const dump = parsePeriphDump(this.hil.selectedPeriphText());
      const core = this.activeCore();
      if (dump.kind === 'registers' && dump.baseAddress !== null && this.rpc.isConnected()) {
        void this.loadLiveRegisterBytes(core, dump.baseAddress, Math.min(Math.max(dump.sizeBytes ?? 64, 16), 256));
      } else {
        this.liveBlockBytes.set(null);
      }
    });
  }

  protected isQuickChipActive(chip: string): boolean {
    return this.hil.selectedPeriphBlock().toUpperCase().startsWith(chip.toUpperCase());
  }

  protected isExpanded(name: string): boolean {
    return this.expandedRegs().has(name);
  }

  protected toggleRegister(name: string): void {
    this.expandedRegs.update((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  }

  protected onCoreChange(event: Event): void {
    const val = Number.parseInt((event.target as HTMLSelectElement).value, 10);
    const core = val === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0;
    this.activeCore.set(core);
    const blk = this.hil.selectedPeriphBlock();
    if (blk) void this.hil.selectPeriphBlock(blk, core);
  }

  protected onFilterInput(event: Event): void {
    this.blockFilter.set((event.target as HTMLInputElement).value);
  }

  protected selectQuickChip(chip: string): void {
    this.rawDump.set('');
    const blocks = this.hil.periphBlocks();
    const target = findQuickBlockMatch(blocks, chip);
    if (blocks.includes(target)) {
      void this.hil.selectPeriphBlock(target, this.activeCore());
      return;
    }
    const coreAddr = CORE_SYSTEM_MMIO_ADDRESSES[chip.toUpperCase()];
    if (coreAddr !== undefined) {
      const hex = `0x${(coreAddr >>> 0).toString(16).toUpperCase().padStart(8, '0')}`;
      this.rawAddr.set(hex);
      if (this.rpc.isConnected()) void this.readRawAddress(coreAddr);
      return;
    }
    void this.hil.selectPeriphBlock(target, this.activeCore());
  }

  protected onBlockChange(event: Event): void {
    this.rawDump.set('');
    void this.hil.selectPeriphBlock((event.target as HTMLSelectElement).value, this.activeCore());
  }

  protected onRawAddrInput(event: Event): void {
    this.rawAddr.set((event.target as HTMLInputElement).value);
  }

  protected async readRawMmio(event: Event): Promise<void> {
    event.preventDefault();
    const addr = parseHexAddress(this.rawAddr());
    if (addr === null) return;
    await this.readRawAddress(addr);
  }

  private async readRawAddress(addr: number): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const bytes = await client.readMemory(this.activeCore(), addr, 64);
      this.rawDump.set(formatMmioHexDump(addr, bytes));
    } catch (err) {
      this.rpc.reportError('Raw MMIO read failed', err);
    }
  }

  private async loadLiveRegisterBytes(core: Core, baseAddr: number, length: number): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.liveBlockBytes.set(await client.readMemory(core, baseAddr, length));
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
  }
}
