import { ChangeDetectionStrategy, Component, OnInit, input, output, signal } from '@angular/core';
import type { ComposerCoreEntry, ComposerMcuSocket } from '../../core/stores/board-composer.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { BUILTIN_SILICON_CATALOG, buildSocketFromCatalog } from './board-composer-catalog';

@Component({
  selector: 'app-board-composer-cores-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  styleUrl: './board-composer.css',
  template: `
    <div
      class="composer-card"
      role="dialog"
      aria-modal="true"
      aria-label="Configure Cores & On-Chip Memory"
      data-testid="composer-cores-modal"
      (click)="$event.stopPropagation()"
    >
      <div class="composer-head">
        <div>
          <app-section-kicker [label]="'MCU & CORE CONFIGURATION · ' + draft().designator" />
          <h2 class="composer-title">Configure Cores &amp; On-Chip Memory</h2>
        </div>
        <div class="row-inline">
          <span class="es-meta mono">{{ draft().partLabel }}</span>
          <button type="button" class="icon-btn" aria-label="Close core configuration" (click)="cancelled.emit()">x</button>
        </div>
      </div>

      <div class="field-grid-2">
        <label class="field-stack">
          <app-section-kicker label="SOCKET DESIGNATOR &amp; ROLE" />
          <select class="box-input" data-testid="cores-role-select" [value]="draft().role" (change)="onRoleChange($event)">
            <option value="Primary">{{ draft().designator }} · Primary Boot MCU</option>
            <option value="Companion">{{ draft().designator }} · Companion MCU</option>
          </select>
        </label>

        <label class="field-stack">
          <app-section-kicker label="INTER-MCU INTERCONNECT" />
          <select class="box-input mono" data-testid="cores-interconnect-select" [value]="draft().interconnect" (change)="onInterconnectChange($event)">
            <option value="None">Standalone (No Inter-MCU Link)</option>
            <option value="U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)">U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)</option>
            <option value="U1.SCI2 (UART) <-> U2.SCI0">U1.SCI2 (UART) <-> U2.SCI0</option>
          </select>
        </label>
      </div>

      <div class="sec-block">
        <div class="sec-head">
          <app-section-kicker label="EXECUTION CORES &amp; ACCELERATORS" />
          <button type="button" class="es-ghost-link" data-testid="cores-add-btn" (click)="addAccelerator()">
            + Add Core / Accelerator
          </button>
        </div>

        <div class="item-table">
          @for (core of draft().cores; track core.id; let idx = $index) {
            <div class="item-row">
              <div class="row-inline">
                <span class="es-meta mono">{{ core.slotLabel }}</span>
                <select class="box-input" [value]="core.arch" aria-label="Core architecture" (change)="onCoreArchChange(idx, $event)">
                  <option value="Cortex-M85">Cortex-M85</option>
                  <option value="Cortex-M33">Cortex-M33</option>
                  <option value="Ethos-U55">Ethos-U55</option>
                </select>
                <span class="es-meta">Clock</span>
                <input
                  type="number"
                  class="box-input mono"
                  style="width: 86px"
                  aria-label="Core clock MHz"
                  [value]="core.clockMhz"
                  (input)="onCoreClockInput(idx, $event)"
                />
                <span class="es-meta">MHz · {{ core.features }}</span>
                @if (core.tcmKb > 0) {
                  <span class="chip-pill mono">TCM {{ core.tcmKb }} KB</span>
                }
              </div>

              <div class="row-inline">
                <input
                  type="checkbox"
                  aria-label="Enable core"
                  [checked]="core.enabled"
                  (change)="onCoreToggle(idx, $event)"
                />
                @if (draft().cores.length > 1) {
                  <button type="button" class="icon-btn" aria-label="Remove core" (click)="removeCore(idx)">x</button>
                }
              </div>
            </div>
          }
        </div>
      </div>

      <div class="sec-block">
        <app-section-kicker label="ON-CHIP MEMORY &amp; FLASH BANKING" />
        <div class="item-table">
          @for (mem of draft().onChipMemory; track mem.id; let idx = $index) {
            <div class="item-row">
              <div class="row-inline">
                <span class="row-title">{{ mem.name }}</span>
                <span class="es-meta mono">{{ mem.baseHex }}</span>
              </div>
              <div class="row-inline">
                <select class="box-input mono" aria-label="On-chip region size KB" [value]="mem.sizeKb" (change)="onMemSizeChange(idx, $event)">
                  <option [value]="40">Size: 40 KB</option>
                  <option [value]="64">Size: 64 KB</option>
                  <option [value]="128">Size: 128 KB</option>
                  <option [value]="544">Size: 544 KB</option>
                  <option [value]="1024">Size: 1024 KB</option>
                  <option [value]="1664">Size: 1664 KB</option>
                  <option [value]="2048">Size: 2048 KB</option>
                </select>
                <span class="es-meta">{{ mem.modeLabel }}</span>
              </div>
            </div>
          }
        </div>
      </div>

      <div class="composer-foot">
        <button type="button" class="es-ghost-link" (click)="resetDefaults()">Reset to Datasheet Defaults</button>
        <div class="sec-actions">
          <app-tonal-button variant="ghost" (pressed)="cancelled.emit()">Cancel</app-tonal-button>
          <app-tonal-button testId="cores-apply-btn" (pressed)="applied.emit(draft())">Apply Core Config</app-tonal-button>
        </div>
      </div>
    </div>
  `,
})
export class BoardComposerCoresModalComponent implements OnInit {
  public readonly socket = input.required<ComposerMcuSocket>();
  public readonly cancelled = output<void>();
  public readonly applied = output<ComposerMcuSocket>();

  protected readonly draft = signal<ComposerMcuSocket>(
    buildSocketFromCatalog(BUILTIN_SILICON_CATALOG[0]!, 'U1', 'Primary')
  );

  public ngOnInit(): void {
    this.draft.set(structuredClone(this.socket()));
  }

  protected onRoleChange(event: Event): void {
    if (event.target instanceof HTMLSelectElement) {
      const role = event.target.value === 'Companion' ? 'Companion' : 'Primary';
      this.draft.update((d) => ({ ...d, role }));
    }
  }

  protected onInterconnectChange(event: Event): void {
    if (event.target instanceof HTMLSelectElement) {
      const interconnect = event.target.value;
      this.draft.update((d) => ({ ...d, interconnect }));
    }
  }

  protected addAccelerator(): void {
    const next: ComposerCoreEntry = {
      id: `core-${Date.now().toString(36)}`,
      slotLabel: `NPU ${this.draft().cores.length}`,
      arch: 'Ethos-U55',
      clockMhz: 500,
      features: '256 MACs · 256 GOPS',
      tcmKb: 0,
      cacheLabel: 'AXI Initiator',
      bootMode: 'AXI Initiator',
      enabled: true,
    };
    this.draft.update((d) => ({ ...d, cores: [...d.cores, next] }));
  }

  protected onCoreArchChange(idx: number, event: Event): void {
    if (!(event.target instanceof HTMLSelectElement)) return;
    const arch = event.target.value as ComposerCoreEntry['arch'];
    this.draft.update((d) => ({
      ...d,
      cores: d.cores.map((c, i) => (i === idx ? { ...c, arch } : c)),
    }));
  }

  protected onCoreClockInput(idx: number, event: Event): void {
    if (!(event.target instanceof HTMLInputElement)) return;
    const clockMhz = Math.max(10, Number.parseInt(event.target.value, 10) || 100);
    this.draft.update((d) => ({
      ...d,
      cores: d.cores.map((c, i) => (i === idx ? { ...c, clockMhz } : c)),
    }));
  }

  protected onCoreToggle(idx: number, event: Event): void {
    if (!(event.target instanceof HTMLInputElement)) return;
    const enabled = event.target.checked;
    this.draft.update((d) => ({
      ...d,
      cores: d.cores.map((c, i) => (i === idx ? { ...c, enabled } : c)),
    }));
  }

  protected removeCore(idx: number): void {
    this.draft.update((d) => ({ ...d, cores: d.cores.filter((_, i) => i !== idx) }));
  }

  protected onMemSizeChange(idx: number, event: Event): void {
    if (!(event.target instanceof HTMLSelectElement)) return;
    const sizeKb = Number.parseInt(event.target.value, 10) || 64;
    this.draft.update((d) => ({
      ...d,
      onChipMemory: d.onChipMemory.map((m, i) => (i === idx ? { ...m, sizeKb } : m)),
    }));
  }

  protected resetDefaults(): void {
    const cur = this.draft();
    const cat = BUILTIN_SILICON_CATALOG.find((s) => s.silicon === cur.silicon) ?? BUILTIN_SILICON_CATALOG[0]!;
    this.draft.set(buildSocketFromCatalog(cat, cur.designator, cur.role));
  }
}
