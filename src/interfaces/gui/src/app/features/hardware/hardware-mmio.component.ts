import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../../core/stores/hardware-hil.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatHexByte, formatHexUpper32, parseHexAddress } from '../../shared/utils/hex';

export function formatMmioHexDump(base: number, bytes: Uint8Array): string {
  const lines: string[] = [];
  for (let off = 0; off < bytes.length; off += 16) {
    const addr = formatHexUpper32((base + off) >>> 0);
    const cols: string[] = [];
    for (let i = off; i < Math.min(off + 16, bytes.length); i++) {
      cols.push(formatHexByte(bytes[i] ?? 0));
    }
    lines.push(`${addr}: ${cols.join(' ')}`);
  }
  return lines.join('\n');
}

@Component({
  selector: 'app-hardware-mmio',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="mmio-box">
      <div class="sec-head">
        <app-section-kicker label="PERIPHERAL MMIO" />
        <select
          class="es-select mono"
          aria-label="Peripheral block"
          data-testid="hardware-periph-select"
          [value]="hil.selectedPeriphBlock()"
          (change)="onBlockChange($event)"
        >
          @for (blk of hil.periphBlocks(); track blk) {
            <option [value]="blk">{{ blk }}</option>
          }
        </select>
      </div>

      <form class="raw-form" (submit)="readRawMmio($event)">
        <input
          type="text"
          class="es-input mono"
          data-testid="hardware-mmio-addr"
          [value]="rawAddr()"
          (input)="onRawAddrInput($event)"
          placeholder="0x40000000"
        />
        <button type="submit" class="mini-btn" data-testid="hardware-mmio-read-btn" [disabled]="!rpc.isConnected()">Read 64B</button>
      </form>

      @if (rawDump()) {
        <pre class="mmio-pre mono" data-testid="hardware-mmio-raw">{{ rawDump() }}</pre>
      } @else if (hil.selectedPeriphText()) {
        <pre class="mmio-pre mono">{{ hil.selectedPeriphText() }}</pre>
      } @else {
        <p class="es-meta note">Select a peripheral block or read a 64-byte MMIO window.</p>
      }
    </div>
  `,
  styles: [
    `
      .mmio-box { padding: 10px 14px; display: flex; flex-direction: column; gap: 8px; flex: 1; min-height: 0; min-width: 0; }
      .sec-head, .raw-form { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .es-input { flex: 1; min-width: 0; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .mmio-pre { flex: 1; min-height: 0; overflow: auto; margin: 0; padding: 8px; background: var(--es-chrome); border: 1px solid var(--es-border); border-radius: var(--es-radius); font-size: 12px; color: var(--es-text-secondary); white-space: pre-wrap; word-break: break-word; }
      .note { margin: 0; }
    `,
  ],
})
export class HardwareMmioComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly hil = inject(HardwareHilStore);

  protected readonly rawAddr = signal<string>('0x40000000');
  protected readonly rawDump = signal<string>('');

  protected onBlockChange(event: Event): void {
    this.rawDump.set('');
    void this.hil.selectPeriphBlock((event.target as HTMLSelectElement).value, Core.Cpu0);
  }

  protected onRawAddrInput(event: Event): void {
    this.rawAddr.set((event.target as HTMLInputElement).value);
  }

  protected async readRawMmio(event: Event): Promise<void> {
    event.preventDefault();
    const client = this.rpc.activeClient;
    const addr = parseHexAddress(this.rawAddr());
    if (!client || addr === null) return;
    try {
      const bytes = await client.readMemory(Core.Cpu0, addr, 64);
      this.rawDump.set(formatMmioHexDump(addr, bytes));
    } catch (err) {
      this.rpc.reportError('Raw MMIO read failed', err);
    }
  }
}
