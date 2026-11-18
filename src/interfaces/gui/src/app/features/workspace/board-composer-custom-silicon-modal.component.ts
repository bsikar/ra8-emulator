import { ChangeDetectionStrategy, Component, OnInit, input, output, signal } from '@angular/core';
import type {
  ComposerCoreEntry,
  ComposerMcuSocket,
  ComposerOnChipRegion,
} from '../../core/stores/board-composer.types';
import { loadCustomSiliconPresets, saveCustomSiliconPresets } from '../../core/stores/board-storage';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { DEFAULT_PERIPHERAL_BLOCKS } from './board-composer-catalog';

const DEFAULT_CUSTOM_CORES: ComposerCoreEntry[] = [
  { id: 'c0', slotLabel: 'Core 0', arch: 'Cortex-M85', clockMhz: 1000, features: 'Helium MVE + FPU + TZ', tcmKb: 256, cacheLabel: '32K/32K', bootMode: 'Primary Boot', enabled: true },
  { id: 'c1', slotLabel: 'Core 1', arch: 'Cortex-M85', clockMhz: 1000, features: 'Helium MVE + FPU + TZ', tcmKb: 256, cacheLabel: '32K/32K', bootMode: 'SMP / IPC Peer', enabled: true },
  { id: 'c2', slotLabel: 'Core 2', arch: 'Cortex-M33', clockMhz: 250, features: 'FPU + DSP', tcmKb: 128, cacheLabel: '16K', bootMode: 'Safety / Housekeeping', enabled: true },
  { id: 'n0', slotLabel: 'NPU 0', arch: 'Ethos-U55', clockMhz: 500, features: '256 MACs (256 GOPS)', tcmKb: 0, cacheLabel: 'AXI Initiator', bootMode: 'AXI Initiator', enabled: true },
];

const DEFAULT_ON_CHIP_MEM: ComposerOnChipRegion[] = [
  { id: 'code-nvm', name: 'Code NVM (MRAM / Flash)', baseHex: '0x02000000', sizeKb: 2048, modeLabel: 'R/X + Prog' },
  { id: 'sys-sram', name: 'System SRAM', baseHex: '0x22000000', sizeKb: 4096, modeLabel: 'R/W/X · Shared' },
];

@Component({
  selector: 'app-board-composer-custom-silicon-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  styleUrl: './board-composer.css',
  template: `
    <div
      class="composer-card"
      role="dialog"
      aria-modal="true"
      aria-label="Define Custom Silicon / MCU Preset"
      data-testid="composer-custom-silicon-modal"
      (click)="$event.stopPropagation()"
    >
      <div class="composer-head">
        <div>
          <app-section-kicker label="CUSTOM SILICON DEFINITION" />
          <h2 class="composer-title">Define Custom Silicon / MCU Preset</h2>
        </div>
        <button type="button" class="icon-btn" aria-label="Close custom silicon" (click)="cancelled.emit()">x</button>
      </div>

      <div class="field-grid-3">
        <label class="field-stack">
          <app-section-kicker label="PART / PRESET NAME" />
          <input type="text" class="box-input mono" data-testid="custom-silicon-name" [value]="customName()" (input)="onCustomName($event)" />
        </label>
        <label class="field-stack">
          <app-section-kicker label="PACKAGE &amp; GPIO PORTS" />
          <select class="box-input" [value]="customPackage()" (change)="onCustomPkg($event)">
            <option value="289-BGA · P0-PB (196 pins)">289-BGA · P0-PB (196 pins)</option>
            <option value="144-LQFP · P0-P9 (112 pins)">144-LQFP · P0-P9 (112 pins)</option>
            <option value="64-LQFP · P0-P5 (48 pins)">64-LQFP · P0-P5 (48 pins)</option>
          </select>
        </label>
        <label class="field-stack">
          <app-section-kicker label="SOCKET ROLE" />
          <select class="box-input" [value]="nextDesignator()" (change)="onDesignatorChange($event)">
            <option value="U1">U1 · Primary</option>
            <option value="U2">U2 · Companion</option>
            <option value="U3">U3 · Companion</option>
          </select>
        </label>
      </div>

      <div class="sec-block">
        <div class="sec-head">
          <app-section-kicker label="CORE &amp; ACCELERATOR STACK" />
          <div class="sec-actions">
            <button type="button" class="es-ghost-link" (click)="addCustomCore('Cortex-M85', 1000)">+ Cortex-M85</button>
            <button type="button" class="es-ghost-link" (click)="addCustomCore('Cortex-M33', 250)">+ Cortex-M33</button>
            <button type="button" class="es-ghost-link" (click)="addCustomCore('Ethos-U55', 500)">+ Ethos-U55</button>
          </div>
        </div>
        <div class="item-table">
          @for (core of customCores(); track core.id; let idx = $index) {
            <div class="item-row">
              <div class="row-inline">
                <span class="es-meta mono">{{ core.slotLabel }}</span>
                <span class="row-title">{{ core.arch }}</span>
                <input
                  type="number"
                  class="box-input mono"
                  style="width: 74px"
                  aria-label="Silicon core clock MHz"
                  [value]="core.clockMhz"
                  (input)="onCoreClockInput(idx, $event)"
                />
                <span class="es-meta">MHz</span>
                @if (core.arch !== 'Ethos-U55') {
                  <select class="box-input mono" aria-label="TCM size KB" [value]="core.tcmKb" (change)="onCoreTcmChange(idx, $event)">
                    <option [value]="256">TCM 256 KB</option>
                    <option [value]="128">TCM 128 KB</option>
                    <option [value]="64">TCM 64 KB</option>
                    <option [value]="32">TCM 32 KB</option>
                    <option [value]="0">No TCM</option>
                  </select>
                } @else {
                  <select class="box-input mono" aria-label="NPU MAC config" [value]="core.features" (change)="onNpuConfigChange(idx, $event)">
                    <option value="256 MACs (256 GOPS)">256 MACs (256 GOPS)</option>
                    <option value="128 MACs (128 GOPS)">128 MACs (128 GOPS)</option>
                  </select>
                }
              </div>
              <div class="row-inline">
                <span class="es-meta">{{ core.bootMode }}</span>
                @if (customCores().length > 1) {
                  <button type="button" class="icon-btn" aria-label="Remove core" (click)="removeCustomCore(idx)">x</button>
                }
              </div>
            </div>
          }
        </div>
      </div>

      <div class="sec-block">
        <div class="sec-head">
          <app-section-kicker label="ON-CHIP MEMORY MAP" />
          <button type="button" class="es-ghost-link" data-testid="custom-silicon-add-onchip-btn" (click)="addOnChipRegion()">+ Add On-Chip Region</button>
        </div>
        <div class="item-table">
          @for (mem of onChipMemory(); track mem.id; let idx = $index) {
            <div class="item-row">
              <div class="row-inline">
                <input type="text" class="box-input" style="width: 170px" aria-label="On-chip memory name" [value]="mem.name" (input)="onMemNameInput(idx, $event)" />
                <span class="es-meta">Base</span>
                <input type="text" class="box-input mono" style="width: 108px" aria-label="On-chip memory base" [value]="mem.baseHex" (input)="onMemBaseInput(idx, $event)" />
                <select class="box-input mono" aria-label="On-chip memory size KB" [value]="mem.sizeKb" (change)="onMemSizeChange(idx, $event)">
                  <option [value]="128">Size 128 KB</option>
                  <option [value]="544">Size 544 KB</option>
                  <option [value]="1024">Size 1 MiB</option>
                  <option [value]="2048">Size 2 MiB</option>
                  <option [value]="4096">Size 4 MiB</option>
                </select>
              </div>
              <div class="row-inline">
                <span class="es-meta mono">{{ mem.modeLabel }}</span>
                @if (onChipMemory().length > 1) {
                  <button type="button" class="icon-btn" aria-label="Remove on-chip region" (click)="removeOnChipRegion(idx)">x</button>
                }
              </div>
            </div>
          }
        </div>
      </div>

      <div class="sec-block">
        <app-section-kicker label="ON-CHIP PERIPHERAL BLOCKS" />
        <div class="chip-grid">
          @for (block of peripheralBlocks; track block) {
            <button
              type="button"
              class="chip-pill"
              [style.borderColor]="selectedBlocks().includes(block) ? 'var(--es-signal-cursor)' : null"
              (click)="toggleBlock(block)"
            >
              {{ selectedBlocks().includes(block) ? '✓ ' + block : block }}
            </button>
          }
        </div>
      </div>

      <div class="composer-foot">
        <label class="row-inline">
          <input type="checkbox" [checked]="saveToLibrary()" (change)="onSaveLibToggle($event)" />
          <span class="es-meta">Save to Preset MCU Library</span>
        </label>
        <div class="sec-actions">
          <app-tonal-button variant="ghost" (pressed)="cancelled.emit()">Cancel</app-tonal-button>
          <app-tonal-button testId="custom-silicon-submit" (pressed)="submitCustomSilicon()">
            {{ editingPreset() ? 'Save Preset Changes' : 'Add Silicon to Board' }}
          </app-tonal-button>
        </div>
      </div>
    </div>
  `,
})
export class BoardComposerCustomSiliconModalComponent implements OnInit {
  public readonly existingCount = input<number>(1);
  public readonly editingPreset = input<ComposerMcuSocket | null>(null);
  public readonly cancelled = output<void>();
  public readonly mcuAdded = output<ComposerMcuSocket>();
  public readonly presetSaved = output<void>();

  protected readonly peripheralBlocks = DEFAULT_PERIPHERAL_BLOCKS;
  protected readonly nextDesignator = signal<string>('U2');
  protected readonly customName = signal<string>('RA8X-DualM85-Hil');
  protected readonly customPackage = signal<string>('289-BGA · P0-PB (196 pins)');
  protected readonly saveToLibrary = signal<boolean>(true);
  protected readonly selectedBlocks = signal<string[]>(DEFAULT_PERIPHERAL_BLOCKS.slice(0, 9));
  protected readonly customCores = signal<ComposerCoreEntry[]>(structuredClone(DEFAULT_CUSTOM_CORES));
  protected readonly onChipMemory = signal<ComposerOnChipRegion[]>(structuredClone(DEFAULT_ON_CHIP_MEM));

  public ngOnInit(): void {
    const preset = this.editingPreset();
    if (preset) {
      this.customName.set(preset.partLabel);
      this.customPackage.set(preset.packageLabel);
      this.nextDesignator.set(preset.designator);
      this.selectedBlocks.set([...preset.peripherals]);
      this.customCores.set(structuredClone(preset.cores));
      this.onChipMemory.set(structuredClone(preset.onChipMemory));
      return;
    }
    this.nextDesignator.set(this.existingCount() <= 0 ? 'U1' : this.existingCount() === 1 ? 'U2' : 'U3');
  }

  protected onDesignatorChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.nextDesignator.set(e.target.value);
  }
  protected onCustomName(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.customName.set(e.target.value);
  }
  protected onCustomPkg(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.customPackage.set(e.target.value);
  }
  protected onSaveLibToggle(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.saveToLibrary.set(e.target.checked);
  }

  protected addCustomCore(arch: ComposerCoreEntry['arch'], clockMhz: number): void {
    const idx = this.customCores().length;
    this.customCores.update((list) => [
      ...list,
      {
        id: `cc-${Date.now().toString(36)}-${idx}`,
        slotLabel: arch === 'Ethos-U55' ? `NPU ${idx}` : `Core ${idx}`,
        arch,
        clockMhz,
        features: arch === 'Cortex-M85' ? 'Helium MVE + FPU + TZ' : arch === 'Cortex-M33' ? 'FPU + DSP' : '256 MACs (256 GOPS)',
        tcmKb: arch === 'Cortex-M85' ? 256 : arch === 'Cortex-M33' ? 128 : 0,
        cacheLabel: '32K',
        bootMode: 'IPC Peer',
        enabled: true,
      },
    ]);
  }

  protected onCoreClockInput(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLInputElement)) return;
    const clockMhz = Math.max(10, Number.parseInt(e.target.value, 10) || 100);
    this.customCores.update((list) => list.map((c, i) => (i === idx ? { ...c, clockMhz } : c)));
  }

  protected onCoreTcmChange(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const tcmKb = Number.parseInt(e.target.value, 10) || 0;
    this.customCores.update((list) => list.map((c, i) => (i === idx ? { ...c, tcmKb } : c)));
  }

  protected onNpuConfigChange(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const features = e.target.value;
    this.customCores.update((list) => list.map((c, i) => (i === idx ? { ...c, features } : c)));
  }

  protected removeCustomCore(idx: number): void {
    this.customCores.update((list) => list.filter((_, i) => i !== idx));
  }

  protected addOnChipRegion(): void {
    const idx = this.onChipMemory().length;
    this.onChipMemory.update((list) => [
      ...list,
      { id: `ocm-${Date.now().toString(36)}-${idx}`, name: `Auxiliary SRAM ${idx}`, baseHex: '0x24000000', sizeKb: 544, modeLabel: 'R/W · Data' },
    ]);
  }

  protected onMemNameInput(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLInputElement)) return;
    const name = e.target.value;
    this.onChipMemory.update((list) => list.map((m, i) => (i === idx ? { ...m, name } : m)));
  }

  protected onMemBaseInput(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLInputElement)) return;
    const baseHex = e.target.value;
    this.onChipMemory.update((list) => list.map((m, i) => (i === idx ? { ...m, baseHex } : m)));
  }

  protected onMemSizeChange(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const sizeKb = Number.parseInt(e.target.value, 10) || 1024;
    this.onChipMemory.update((list) => list.map((m, i) => (i === idx ? { ...m, sizeKb } : m)));
  }

  protected removeOnChipRegion(idx: number): void {
    this.onChipMemory.update((list) => list.filter((_, i) => i !== idx));
  }

  protected toggleBlock(block: string): void {
    this.selectedBlocks.update((cur) => (cur.includes(block) ? cur.filter((b) => b !== block) : [...cur, block]));
  }

  protected submitCustomSilicon(): void {
    const des = this.nextDesignator();
    const editing = this.editingPreset();
    const socket: ComposerMcuSocket = {
      id: editing?.id ?? `custom-mcu-${Date.now().toString(36)}`,
      designator: des,
      role: des === 'U1' ? 'Primary' : 'Companion',
      silicon: 'ra8p1',
      partLabel: this.customName().trim() || 'RA8X-Custom',
      packageLabel: this.customPackage(),
      interconnect: des === 'U1' ? 'None' : 'U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)',
      cores: structuredClone(this.customCores()),
      onChipMemory: structuredClone(this.onChipMemory()),
      peripherals: [...this.selectedBlocks()],
    };
    if (this.saveToLibrary() || editing) {
      const existing = loadCustomSiliconPresets();
      const nextLib = editing
        ? existing.map((item) => (item.id === editing.id ? socket : item))
        : [socket, ...existing];
      saveCustomSiliconPresets(nextLib);
    }
    if (editing) {
      this.presetSaved.emit();
      return;
    }
    this.mcuAdded.emit(socket);
  }
}
