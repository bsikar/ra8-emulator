import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { DebugStore } from '../../core/stores/debug.store';
import { formatHex32, parseHexAddress } from '../../shared/utils/hex';
import { buildMemoryHexRows, parseRegisterOrMemoryValue } from './debug-view';

@Component({
  selector: 'app-debug-memory-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="mem-pane">
      <div class="mem-bar">
        <div class="preset-row">
          <button type="button" class="chip" data-testid="debug-mem-mram" (click)="jumpRegion('mram')">MRAM</button>
          <button type="button" class="chip" data-testid="debug-mem-sram" (click)="jumpRegion('sram')">SRAM</button>
          <button type="button" class="chip" data-testid="debug-mem-tcm" (click)="jumpRegion('tcm')">TCM</button>
          <button type="button" class="chip" data-testid="debug-mem-sp" (click)="jumpReg('sp')">SP</button>
          <button type="button" class="chip" data-testid="debug-mem-pc" (click)="jumpReg('pc')">PC</button>
        </div>
        <form class="jump-form" (submit)="onJumpSubmit($event)">
          <input
            type="text"
            class="addr-input mono"
            data-testid="debug-mem-addr-input"
            [value]="addrDraft()"
            (input)="onAddrInput($event)"
            placeholder="0x20000000"
          />
          <button type="submit" class="chip" data-testid="debug-mem-go-btn">Go</button>
          <button type="button" class="chip" (click)="pageBy(-256)">-256B</button>
          <button type="button" class="chip" (click)="pageBy(256)">+256B</button>
          <button type="button" class="chip" (click)="watchCurrent()">+ Watch</button>
        </form>
      </div>

      @if (rows().length > 0) {
        <div class="mem-grid mono" data-testid="debug-memory-grid">
          @for (row of rows(); track row.baseAddr) {
            <div class="mem-row">
              <span class="mem-addr">{{ row.addrHex }}</span>
              <span class="mem-bytes">
                @for (cell of row.cells; track cell.offset) {
                  @if (pokeAddr() === cell.address) {
                    <form class="poke-form" (submit)="commitPoke($event, cell.address)">
                      <input
                        type="text"
                        class="poke-input mono"
                        data-testid="debug-mem-poke-input"
                        maxlength="4"
                        [value]="pokeDraft()"
                        (input)="onPokeInput($event)"
                        aria-label="Write memory byte hex"
                      />
                    </form>
                  } @else {
                    <button
                      type="button"
                      class="byte-btn mono"
                      [class.is-changed]="cell.changed"
                      [attr.data-mem-offset]="cell.offset"
                      [disabled]="rpc.observeOnly()"
                      (click)="beginPoke(cell.address, cell.hex)"
                    >
                      {{ cell.hex }}
                    </button>
                  }
                }
              </span>
              <span class="mem-ascii">{{ row.ascii }}</span>
            </div>
          }
        </div>
      } @else {
        <p class="es-meta note">Select a region or enter an address to inspect CPU{{ debug.activeCore() }} memory.</p>
      }
    </div>
  `,
  styles: [
    `
      .mem-pane { display: flex; flex-direction: column; gap: 6px; padding: 6px 10px; min-width: 0; }
      .mem-bar { display: flex; align-items: center; justify-content: space-between; gap: 6px; flex-wrap: wrap; }
      .preset-row, .jump-form { display: inline-flex; align-items: center; gap: 4px; flex-wrap: wrap; }
      .chip { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; cursor: pointer; }
      .chip:hover { background: var(--es-interactive); color: var(--es-text-primary); }
      .addr-input { width: 102px; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 2px 4px; }
      .mem-grid { display: flex; flex-direction: column; font-size: 12px; overflow: auto; }
      .mem-row { display: flex; align-items: center; gap: 10px; min-height: 22px; border-bottom: 1px solid var(--es-divider); white-space: nowrap; }
      .mem-addr { color: var(--es-text-muted); flex-shrink: 0; }
      .mem-bytes { display: inline-flex; align-items: center; gap: 3px; }
      .byte-btn { border: 0; border-bottom: 1px solid transparent; background: transparent; color: var(--es-text-secondary); font-size: 12px; padding: 0 2px; cursor: pointer; }
      .byte-btn:hover:not(:disabled) { background: var(--es-interactive); color: var(--es-text-primary); }
      .byte-btn.is-changed { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .poke-form { display: inline-flex; }
      .poke-input { width: 32px; background: var(--es-container); border: 1px solid var(--es-signal-cursor); color: var(--es-text-primary); font-size: 12px; padding: 0 2px; }
      .mem-ascii { color: var(--es-text-muted); margin-left: auto; }
      .note { margin: 4px 0; }
    `,
  ],
})
export class DebugMemoryPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly debug = inject(DebugStore);

  protected readonly addrDraft = signal<string>('');
  protected readonly pokeAddr = signal<number | null>(null);
  protected readonly pokeDraft = signal<string>('');

  protected readonly rows = computed(() =>
    buildMemoryHexRows(this.debug.memoryAddress(), this.debug.memoryBytes(), this.debug.memoryPrevBytes())
  );

  protected onAddrInput(event: Event): void {
    this.addrDraft.set((event.target as HTMLInputElement).value);
  }

  protected onJumpSubmit(event: Event): void {
    event.preventDefault();
    const parsed = parseHexAddress(this.addrDraft());
    if (parsed !== null) void this.jumpTo(parsed);
  }

  protected jumpRegion(region: 'mram' | 'sram' | 'tcm'): Promise<Uint8Array | null> {
    const base = region === 'mram' ? 0x0200_0000 : region === 'sram' ? 0x2200_0000 : 0x2000_0000;
    return this.jumpTo(base);
  }

  protected jumpTo(addr: number): Promise<Uint8Array | null> {
    const aligned = addr >>> 0;
    this.addrDraft.set(formatHex32(aligned));
    return this.debug.readMemoryPage(aligned, 256, this.debug.activeCore());
  }

  protected jumpReg(name: 'sp' | 'pc'): void {
    const val = this.debug.registers()[name];
    if (val !== undefined) void this.jumpTo(val & ~0xf);
  }

  protected pageBy(delta: number): void {
    const next = (this.debug.memoryAddress() + delta) >>> 0;
    void this.jumpTo(next);
  }

  protected watchCurrent(): void {
    this.debug.addWatchExpression(formatHex32(this.debug.memoryAddress()));
  }

  protected beginPoke(address: number, hexByte: string): void {
    this.pokeAddr.set(address);
    this.pokeDraft.set(hexByte);
  }

  protected onPokeInput(event: Event): void {
    this.pokeDraft.set((event.target as HTMLInputElement).value);
  }

  protected async commitPoke(event: Event, address: number): Promise<void> {
    event.preventDefault();
    const raw = this.pokeDraft().trim();
    const normalized = raw.startsWith('0x') || raw.startsWith('0X') ? raw : `0x${raw}`;
    const parsed = parseRegisterOrMemoryValue(normalized);
    if (parsed !== null && parsed <= 0xff) {
      await this.debug.writeMemoryBytes(address, Uint8Array.of(parsed & 0xff), this.debug.activeCore());
    }
    this.pokeAddr.set(null);
  }
}
