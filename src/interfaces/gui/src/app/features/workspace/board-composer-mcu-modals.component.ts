import { ChangeDetectionStrategy, Component, computed, input, output, signal } from '@angular/core';
import type { ComposerCoreEntry, ComposerMcuSocket } from '../../core/stores/board-composer.types';
import { loadCustomSiliconPresets, saveCustomSiliconPresets } from '../../core/stores/board-storage';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import {
  BUILTIN_SILICON_CATALOG,
  DEFAULT_PERIPHERAL_BLOCKS,
  type SiliconCatalogItem,
  buildSocketFromCatalog,
} from './board-composer-catalog';

export type McuSubModalKind = 'preset-mcu' | 'custom-silicon';
type SiliconFilterTab = 'All' | 'RA8' | 'RA4 / RA6' | 'Saved Presets';

@Component({
  selector: 'app-board-composer-mcu-modals',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  styleUrl: './board-composer.css',
  template: `
    @if (mode() === 'preset-mcu') {
      <div
        class="composer-card"
        role="dialog"
        aria-modal="true"
        aria-label="Add Preset MCU"
        data-testid="composer-preset-mcu-modal"
        (click)="$event.stopPropagation()"
      >
        <div class="composer-head">
          <div>
            <app-section-kicker label="SILICON CATALOG" />
            <h2 class="composer-title">Add Preset MCU</h2>
          </div>
          <button type="button" class="icon-btn" aria-label="Close silicon catalog" (click)="cancelled.emit()">x</button>
        </div>

        <div class="sec-head">
          <input
            type="text"
            class="box-input"
            style="flex: 1; min-width: 200px"
            data-testid="preset-mcu-search"
            placeholder="Search silicon part, family, or core..."
            [value]="search()"
            (input)="onSearchInput($event)"
          />
          <div class="sec-actions">
            @for (tab of filterTabs; track tab) {
              <button
                type="button"
                class="es-ghost-link"
                [style.color]="filter() === tab ? 'var(--es-text-primary)' : null"
                (click)="filter.set(tab)"
              >
                {{ tab }}
              </button>
            }
          </div>
        </div>

        <div class="item-table">
          @if (filter() !== 'Saved Presets') {
            @for (item of filteredBuiltins(); track item.id) {
              <div
                class="item-row is-selectable"
                [class.is-active]="selectedId() === item.id"
                [attr.data-testid]="'preset-mcu-row-' + item.id"
                (click)="selectedId.set(item.id)"
              >
                <div>
                  <div class="row-inline">
                    <span class="row-title">{{ item.title }}</span>
                    <span class="es-meta mono">{{ item.partLabel }}</span>
                    <span class="es-meta">{{ item.summary }}</span>
                  </div>
                  <div class="es-subline">{{ item.subline }}</div>
                </div>
                <span class="es-meta">Built-in</span>
              </div>
            }
          }
          @for (saved of savedPresets(); track saved.id) {
            <div
              class="item-row is-selectable"
              [class.is-active]="selectedId() === saved.id"
              (click)="selectedId.set(saved.id)"
            >
              <div>
                <div class="row-title">{{ saved.partLabel }}</div>
                <div class="es-subline">{{ saved.packageLabel }} · {{ saved.cores.length }} core(s)</div>
              </div>
              <span class="es-meta">Saved Preset</span>
            </div>
          }
        </div>

        <div class="field-grid-2">
          <label class="field-stack">
            <app-section-kicker label="DESIGNATOR &amp; ROLE" />
            <select class="box-input" data-testid="preset-mcu-designator" [value]="nextDesignator()" (change)="onDesignatorChange($event)">
              <option value="U2">U2 · Companion MCU</option>
              <option value="U3">U3 · Companion MCU</option>
              <option value="U1">U1 · Primary MCU</option>
            </select>
          </label>
          <label class="field-stack">
            <app-section-kicker label="INTER-MCU LINK" />
            <select class="box-input mono" [value]="interconnect()" (change)="onLinkChange($event)">
              <option value="U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)">U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)</option>
              <option value="U1.SCI2 (UART) <-> U2.SCI0">U1.SCI2 (UART) <-> U2.SCI0</option>
              <option value="None">Independent Bus</option>
            </select>
          </label>
        </div>

        <div class="composer-foot">
          <button type="button" class="es-ghost-link" data-testid="switch-to-custom-silicon" (click)="switchMode.emit('custom-silicon')">
            + Create New MCU Preset...
          </button>
          <div class="sec-actions">
            <app-tonal-button variant="ghost" (pressed)="cancelled.emit()">Cancel</app-tonal-button>
            <app-tonal-button testId="preset-mcu-submit" (pressed)="submitPresetMcu()">Add MCU to Board</app-tonal-button>
          </div>
        </div>
      </div>
    } @else {
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
                  <span class="es-meta mono">{{ core.clockMhz }} MHz · {{ core.features }}</span>
                </div>
                @if (customCores().length > 1) {
                  <button type="button" class="icon-btn" aria-label="Remove core" (click)="removeCustomCore(idx)">x</button>
                }
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
            <app-tonal-button testId="custom-silicon-submit" (pressed)="submitCustomSilicon()">Add Silicon to Board</app-tonal-button>
          </div>
        </div>
      </div>
    }
  `,
})
export class BoardComposerMcuModalsComponent {
  public readonly mode = input.required<McuSubModalKind>();
  public readonly existingCount = input<number>(1);
  public readonly cancelled = output<void>();
  public readonly switchMode = output<McuSubModalKind>();
  public readonly mcuAdded = output<ComposerMcuSocket>();

  protected readonly filterTabs: readonly SiliconFilterTab[] = ['All', 'RA8', 'RA4 / RA6', 'Saved Presets'];
  protected readonly peripheralBlocks = DEFAULT_PERIPHERAL_BLOCKS;
  protected readonly search = signal<string>('');
  protected readonly filter = signal<SiliconFilterTab>('All');
  protected readonly selectedId = signal<string>(BUILTIN_SILICON_CATALOG[0]!.id);
  protected readonly nextDesignator = signal<string>('U2');
  protected readonly interconnect = signal<string>('U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)');
  protected readonly savedPresets = signal<ComposerMcuSocket[]>(loadCustomSiliconPresets());

  protected readonly customName = signal<string>('RA8X-DualM85-Hil');
  protected readonly customPackage = signal<string>('289-BGA · P0-PB (196 pins)');
  protected readonly saveToLibrary = signal<boolean>(true);
  protected readonly selectedBlocks = signal<string[]>(DEFAULT_PERIPHERAL_BLOCKS.slice(0, 9));
  protected readonly customCores = signal<ComposerCoreEntry[]>([
    { id: 'c0', slotLabel: 'Core 0', arch: 'Cortex-M85', clockMhz: 1000, features: 'Helium MVE + FPU + TZ', tcmKb: 256, cacheLabel: '32K/32K', bootMode: 'Primary Boot', enabled: true },
    { id: 'c1', slotLabel: 'Core 1', arch: 'Cortex-M33', clockMhz: 250, features: 'FPU + DSP', tcmKb: 128, cacheLabel: '16K', bootMode: 'IPC Peer', enabled: true },
    { id: 'n0', slotLabel: 'NPU 0', arch: 'Ethos-U55', clockMhz: 500, features: '256 MACs (256 GOPS)', tcmKb: 0, cacheLabel: 'AXI Initiator', bootMode: 'AXI Initiator', enabled: true },
  ]);

  protected readonly filteredBuiltins = computed<SiliconCatalogItem[]>(() => {
    const q = this.search().trim().toLowerCase();
    const tab = this.filter();
    return BUILTIN_SILICON_CATALOG.filter((item) => {
      if (tab !== 'All' && tab !== 'Saved Presets' && item.family !== tab) return false;
      if (!q) return true;
      return item.title.toLowerCase().includes(q) || item.partLabel.toLowerCase().includes(q) || item.summary.toLowerCase().includes(q);
    });
  });

  protected onSearchInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.search.set(e.target.value);
  }
  protected onDesignatorChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.nextDesignator.set(e.target.value);
  }
  protected onLinkChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.interconnect.set(e.target.value);
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
        bootMode: 'Reset',
        enabled: true,
      },
    ]);
  }

  protected removeCustomCore(idx: number): void {
    this.customCores.update((list) => list.filter((_, i) => i !== idx));
  }

  protected toggleBlock(block: string): void {
    this.selectedBlocks.update((cur) => (cur.includes(block) ? cur.filter((b) => b !== block) : [...cur, block]));
  }

  protected submitPresetMcu(): void {
    const des = this.nextDesignator();
    const role = des === 'U1' ? 'Primary' : 'Companion';
    const saved = this.savedPresets().find((s) => s.id === this.selectedId());
    if (saved) {
      this.mcuAdded.emit({ ...structuredClone(saved), id: `mcu-${Date.now().toString(36)}`, designator: des, role, interconnect: this.interconnect() });
      return;
    }
    const item = BUILTIN_SILICON_CATALOG.find((s) => s.id === this.selectedId()) ?? BUILTIN_SILICON_CATALOG[3]!;
    this.mcuAdded.emit(buildSocketFromCatalog(item, des, role, this.interconnect()));
  }

  protected submitCustomSilicon(): void {
    const des = this.nextDesignator();
    const socket: ComposerMcuSocket = {
      id: `custom-mcu-${Date.now().toString(36)}`,
      designator: des,
      role: des === 'U1' ? 'Primary' : 'Companion',
      silicon: 'ra8p1',
      partLabel: this.customName().trim() || 'RA8X-Custom',
      packageLabel: this.customPackage(),
      interconnect: des === 'U1' ? 'None' : this.interconnect(),
      cores: structuredClone(this.customCores()),
      onChipMemory: [
        { id: 'code-nvm', name: 'Code NVM (MRAM / Flash)', baseHex: '0x02000000', sizeKb: 2048, modeLabel: 'R/X + Prog' },
        { id: 'sys-sram', name: 'System SRAM', baseHex: '0x22000000', sizeKb: 4096, modeLabel: 'R/W/X · Shared' },
      ],
      peripherals: [...this.selectedBlocks()],
    };
    if (this.saveToLibrary()) {
      const nextLib = [socket, ...this.savedPresets()];
      this.savedPresets.set(nextLib);
      saveCustomSiliconPresets(nextLib);
    }
    this.mcuAdded.emit(socket);
  }
}
