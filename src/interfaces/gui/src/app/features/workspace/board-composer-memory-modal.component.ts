import { ChangeDetectionStrategy, Component, OnInit, input, output, signal } from '@angular/core';
import type {
  ComposerBackingKind,
  ComposerMcuSocket,
  ComposerMemoryKind,
  ComposerMemoryRegion,
} from '../../core/stores/board-composer.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';

const MEMORY_KINDS: readonly ComposerMemoryKind[] = [
  'Octal-SPI (OSPI)',
  'SDRAM',
  'Quad-SPI NOR',
  'HyperRAM',
  'Custom MMIO',
];

const BACKING_KINDS: readonly ComposerBackingKind[] = [
  'Zero-Initialized',
  'Preload .bin / .hex',
  'Persistent Host File',
];

function controllerNameForKind(kind: ComposerMemoryKind): string {
  switch (kind) {
    case 'SDRAM':
      return 'SDRAM CS0';
    case 'Quad-SPI NOR':
      return 'QSPI0 CS0';
    case 'HyperRAM':
      return 'OSPI1 HyperBus';
    case 'Custom MMIO':
      return 'External Bus MMIO';
    default:
      return 'OSPI0 CS0';
  }
}

@Component({
  selector: 'app-board-composer-memory-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  styleUrl: './board-composer.css',
  template: `
    <div
      class="composer-card"
      role="dialog"
      aria-modal="true"
      aria-label="Add Memory Region"
      data-testid="composer-memory-modal"
      (click)="$event.stopPropagation()"
    >
      <div class="composer-head">
        <div>
          <app-section-kicker label="EXTERNAL MEMORY &amp; BUS TIMING" />
          <h2 class="composer-title">{{ initialRegion() ? 'Edit Memory Region' : 'Add Memory Region' }}</h2>
        </div>
        <button type="button" class="icon-btn" aria-label="Close memory modal" (click)="cancelled.emit()">x</button>
      </div>

      <div class="field-stack">
        <app-section-kicker label="INTERFACE TYPE" />
        <div class="seg-bar" role="radiogroup" aria-label="Memory interface type">
          @for (k of kinds; track k) {
            <button
              type="button"
              role="radio"
              class="seg-opt"
              [class.is-active]="kind() === k"
              [attr.aria-checked]="kind() === k"
              (click)="selectKind(k)"
            >
              {{ k }}
            </button>
          }
        </div>
      </div>

      <div class="field-grid-2">
        <label class="field-stack">
          <app-section-kicker label="MOUNT ON MCU &amp; CONTROLLER" />
          <select class="box-input" data-testid="memory-mount-select" [value]="mountSocket()" (change)="onMountChange($event)">
            @for (m of mcus(); track m.id) {
              <option [value]="m.designator">{{ m.designator }} · {{ m.silicon.toUpperCase() }} · {{ controllerForKind() }}</option>
            }
          </select>
        </label>

        <label class="field-stack">
          <app-section-kicker label="BASE ADDRESS" />
          <input type="text" class="box-input mono" data-testid="memory-base-input" [value]="baseHex()" (input)="onBaseInput($event)" />
        </label>
      </div>

      <div class="field-grid-3">
        <label class="field-stack">
          <app-section-kicker label="CAPACITY" />
          <select class="box-input" data-testid="memory-size-select" [value]="sizeMib()" (change)="onSizeChange($event)">
            <option [value]="8">8 MiB (64 Mbit)</option>
            <option [value]="16">16 MiB (128 Mbit)</option>
            <option [value]="32">32 MiB (256 Mbit)</option>
            <option [value]="64">64 MiB (512 Mbit)</option>
            <option [value]="128">128 MiB (1 Gbit)</option>
            @if (kind() !== 'SDRAM') {
              <option [value]="256">256 MiB (2 Gbit)</option>
            }
          </select>
        </label>

        <label class="field-stack">
          <app-section-kicker label="BUS WIDTH &amp; MODE" />
          <select class="box-input" data-testid="memory-width-select" [value]="widthBits()" (change)="onWidthChange($event)">
            @if (kind() === 'SDRAM') {
              <option [value]="32">32-bit SDRAM</option>
              <option [value]="16">16-bit SDRAM</option>
              <option [value]="8">8-bit SDRAM</option>
            } @else {
              <option [value]="8">8-bit Octal DDR (xSPI)</option>
              <option [value]="4">4-bit Quad SPI</option>
              <option [value]="2">2-bit Dual SPI</option>
              <option [value]="1">1-bit Serial SPI</option>
            }
          </select>
        </label>

        <label class="field-stack">
          <app-section-kicker label="XIP &amp; SECURITY" />
          <select class="box-input" [value]="xipLabel()" (change)="onXipChange($event)">
            <option value="XIP + DOTF Enabled">XIP + DOTF Enabled</option>
            <option value="XIP Read-Only">XIP Read-Only</option>
            <option value="Standard Bus">Standard Bus</option>
          </select>
        </label>
      </div>

      <div class="field-grid-3">
        <label class="field-stack">
          <app-section-kicker label="BUS CLOCK (MHZ)" />
          <input type="number" class="box-input mono" data-testid="memory-clock-input" [value]="clockMhz()" (input)="onClockInput($event)" />
        </label>

        <label class="field-stack">
          <app-section-kicker label="READ LATENCY (CYCLES)" />
          <input type="number" class="box-input mono" data-testid="memory-latency-input" [value]="latencyCycles()" (input)="onLatencyInput($event)" />
        </label>

        <label class="field-stack">
          <app-section-kicker label="BURST &amp; WINDOW" />
          <select class="box-input" [value]="burst()" (change)="onBurstChange($event)">
            <option value="incrementing16">Incrementing 16-beat · 1M cyc</option>
            <option value="single">Single beat · 1M cyc</option>
          </select>
        </label>
      </div>

      <div class="field-stack">
        <app-section-kicker label="BACKING STORAGE" />
        <div class="seg-bar" role="radiogroup" aria-label="Backing storage">
          @for (b of backings; track b) {
            <button
              type="button"
              role="radio"
              class="seg-opt"
              [class.is-active]="backing() === b"
              [attr.aria-checked]="backing() === b"
              (click)="backing.set(b)"
            >
              {{ b }}
            </button>
          }
        </div>
        @if (backing() !== 'Zero-Initialized') {
          <input
            type="text"
            class="box-input mono"
            data-testid="memory-backing-path"
            [value]="backingPath()"
            (input)="onBackingPathInput($event)"
            placeholder="fixtures/flash_preload.bin"
          />
        }
      </div>

      <div class="composer-foot">
        <span></span>
        <div class="sec-actions">
          <app-tonal-button variant="ghost" (pressed)="cancelled.emit()">Cancel</app-tonal-button>
          <app-tonal-button testId="memory-submit-btn" (pressed)="submit()">
            {{ initialRegion() ? 'Save Memory Region' : 'Add Memory Region' }}
          </app-tonal-button>
        </div>
      </div>
    </div>
  `,
})
export class BoardComposerMemoryModalComponent implements OnInit {
  public readonly mcus = input<readonly ComposerMcuSocket[]>([]);
  public readonly initialRegion = input<ComposerMemoryRegion | null>(null);
  public readonly cancelled = output<void>();
  public readonly added = output<ComposerMemoryRegion>();

  protected readonly kinds = MEMORY_KINDS;
  protected readonly backings = BACKING_KINDS;
  protected readonly kind = signal<ComposerMemoryKind>('Octal-SPI (OSPI)');
  protected readonly mountSocket = signal<string>('U1');
  protected readonly baseHex = signal<string>('0x80000000');
  protected readonly sizeMib = signal<number>(64);
  protected readonly widthBits = signal<number>(8);
  protected readonly xipLabel = signal<string>('XIP + DOTF Enabled');
  protected readonly clockMhz = signal<number>(166);
  protected readonly latencyCycles = signal<number>(8);
  protected readonly burst = signal<'single' | 'incrementing16'>('incrementing16');
  protected readonly backing = signal<ComposerBackingKind>('Zero-Initialized');
  protected readonly backingPath = signal<string>('');

  public ngOnInit(): void {
    const initial = this.initialRegion();
    if (!initial) {
      const firstSocket = this.mcus()[0]?.designator;
      if (firstSocket) this.mountSocket.set(firstSocket);
      return;
    }
    this.kind.set(initial.kind);
    this.mountSocket.set(initial.mountSocket);
    this.baseHex.set(initial.baseHex);
    this.sizeMib.set(initial.sizeMib);
    this.widthBits.set(initial.widthBits);
    this.xipLabel.set(initial.xipSecurityLabel);
    this.clockMhz.set(initial.clockMhz);
    this.latencyCycles.set(initial.latencyCycles);
    this.burst.set(initial.burst);
    this.backing.set(initial.backing);
  }

  protected controllerForKind(): string {
    return controllerNameForKind(this.kind());
  }

  protected selectKind(next: ComposerMemoryKind): void {
    this.kind.set(next);
    if (next === 'SDRAM') {
      this.baseHex.set('0x90000000');
      this.widthBits.set(32);
      this.clockMhz.set(133);
      this.latencyCycles.set(3);
      return;
    }
    this.baseHex.set(next === 'Custom MMIO' ? '0x60000000' : '0x80000000');
    this.widthBits.set(next === 'Quad-SPI NOR' ? 4 : 8);
    this.clockMhz.set(166);
    this.latencyCycles.set(8);
  }

  protected onMountChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.mountSocket.set(e.target.value);
  }
  protected onBaseInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.baseHex.set(e.target.value);
  }
  protected onSizeChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.sizeMib.set(Number.parseInt(e.target.value, 10) || 64);
  }
  protected onWidthChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.widthBits.set(Number.parseInt(e.target.value, 10) || 8);
  }
  protected onXipChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.xipLabel.set(e.target.value);
  }
  protected onClockInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.clockMhz.set(Math.max(1, Number.parseInt(e.target.value, 10) || 100));
  }
  protected onLatencyInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.latencyCycles.set(Math.max(0, Number.parseInt(e.target.value, 10) || 3));
  }
  protected onBurstChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) {
      this.burst.set(e.target.value === 'single' ? 'single' : 'incrementing16');
    }
  }
  protected onBackingPathInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.backingPath.set(e.target.value);
  }

  protected submit(): void {
    const w = this.widthBits();
    const initial = this.initialRegion();
    this.added.emit({
      id: initial?.id ?? `mem-${Date.now().toString(36)}`,
      kind: this.kind(),
      mountSocket: this.mountSocket(),
      controllerLabel: this.controllerForKind(),
      baseHex: this.baseHex().trim() || '0x80000000',
      sizeMib: this.sizeMib(),
      widthBits: w,
      widthModeLabel: w === 8 && this.kind() === 'Octal-SPI (OSPI)' ? '8-bit Octal DDR (xSPI)' : `${w}-bit`,
      xipSecurityLabel: this.xipLabel(),
      clockMhz: this.clockMhz(),
      latencyCycles: this.latencyCycles(),
      burst: this.burst(),
      backing: this.backing(),
    });
  }
}
