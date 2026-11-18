import { ChangeDetectionStrategy, Component, OnInit, computed, input, output, signal } from '@angular/core';
import type { ComposerMcuSocket } from '../../core/stores/board-composer.types';
import { loadCustomSiliconPresets, saveCustomSiliconPresets } from '../../core/stores/board-storage';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import {
  BUILTIN_SILICON_CATALOG,
  type SiliconCatalogItem,
  buildSocketFromCatalog,
} from './board-composer-catalog';

type SiliconFilterTab = 'All' | 'RA8' | 'RA4 / RA6' | 'Saved Presets';

function defaultDesignatorForCount(count: number): string {
  if (count <= 0) return 'U1';
  if (count === 1) return 'U2';
  if (count === 2) return 'U3';
  return 'U4';
}

@Component({
  selector: 'app-board-composer-preset-mcu-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  styleUrl: './board-composer.css',
  template: `
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
        @if (filter() === 'All' || filter() === 'Saved Presets') {
          @for (saved of filteredSaved(); track saved.id) {
            <div
              class="item-row is-selectable"
              [class.is-active]="selectedId() === saved.id"
              [attr.data-testid]="'preset-mcu-saved-' + saved.id"
              (click)="selectedId.set(saved.id)"
            >
              <div>
                <div class="row-inline">
                  <span class="row-title">{{ saved.partLabel }}</span>
                  <span class="es-meta mono">{{ saved.cores.length }} core(s)</span>
                </div>
                <div class="es-subline">{{ saved.packageLabel }}</div>
              </div>
              <div class="row-inline">
                <span class="es-meta">Saved Preset</span>
                <button
                  type="button"
                  class="icon-btn"
                  aria-label="Edit saved silicon preset"
                  [attr.data-testid]="'preset-mcu-edit-' + saved.id"
                  (click)="$event.stopPropagation(); editSaved.emit(saved)"
                >
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                    <path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25Zm17.71-10.21a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83Z" fill="currentColor" />
                  </svg>
                </button>
                <button
                  type="button"
                  class="icon-btn"
                  aria-label="Delete saved silicon preset"
                  [attr.data-testid]="'preset-mcu-delete-' + saved.id"
                  (click)="$event.stopPropagation(); deleteSavedPreset(saved.id)"
                >
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                    <path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12ZM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4Z" fill="currentColor" />
                  </svg>
                </button>
              </div>
            </div>
          }
        }
        @if (filter() === 'Saved Presets' && filteredSaved().length === 0) {
          <div class="item-row">
            <span class="es-meta">No saved silicon presets yet — click + Create New MCU Preset... to define one.</span>
          </div>
        }
      </div>

      <div class="field-grid-2">
        <label class="field-stack">
          <app-section-kicker label="DESIGNATOR &amp; ROLE" />
          <select class="box-input" data-testid="preset-mcu-designator" [value]="nextDesignator()" (change)="onDesignatorChange($event)">
            <option value="U1">U1 · Primary MCU</option>
            <option value="U2">U2 · Companion MCU</option>
            <option value="U3">U3 · Companion MCU</option>
            <option value="U4">U4 · Companion MCU</option>
          </select>
        </label>
        <label class="field-stack">
          <app-section-kicker label="INTER-MCU LINK" />
          <select class="box-input mono" [value]="interconnect()" (change)="onLinkChange($event)">
            <option value="U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)">U1.SPI0 (Controller) &lt;-&gt; U2.SPI0 (Peripheral)</option>
            <option value="U1.SCI2 (UART) <-> U2.SCI0">U1.SCI2 (UART) &lt;-&gt; U2.SCI0</option>
            <option value="None">Independent Bus</option>
          </select>
        </label>
      </div>

      <div class="composer-foot">
        <button type="button" class="es-ghost-link" data-testid="switch-to-custom-silicon" (click)="switchToCustom.emit()">
          + Create New MCU Preset...
        </button>
        <div class="sec-actions">
          <app-tonal-button variant="ghost" (pressed)="cancelled.emit()">Cancel</app-tonal-button>
          <app-tonal-button testId="preset-mcu-submit" (pressed)="submitPresetMcu()">Add MCU to Board</app-tonal-button>
        </div>
      </div>
    </div>
  `,
})
export class BoardComposerPresetMcuModalComponent implements OnInit {
  public readonly existingCount = input<number>(1);
  public readonly cancelled = output<void>();
  public readonly switchToCustom = output<void>();
  public readonly editSaved = output<ComposerMcuSocket>();
  public readonly mcuAdded = output<ComposerMcuSocket>();

  protected readonly filterTabs: readonly SiliconFilterTab[] = ['All', 'RA8', 'RA4 / RA6', 'Saved Presets'];
  protected readonly search = signal<string>('');
  protected readonly filter = signal<SiliconFilterTab>('All');
  protected readonly selectedId = signal<string>(BUILTIN_SILICON_CATALOG[0]!.id);
  protected readonly nextDesignator = signal<string>('U2');
  protected readonly interconnect = signal<string>('U1.SPI0 (Controller) <-> U2.SPI0 (Peripheral)');
  protected readonly savedPresets = signal<ComposerMcuSocket[]>(loadCustomSiliconPresets());

  protected readonly filteredBuiltins = computed<SiliconCatalogItem[]>(() => {
    const q = this.search().trim().toLowerCase();
    const tab = this.filter();
    return BUILTIN_SILICON_CATALOG.filter((item) => {
      if (tab !== 'All' && tab !== 'Saved Presets' && item.family !== tab) return false;
      if (!q) return true;
      return item.title.toLowerCase().includes(q) || item.partLabel.toLowerCase().includes(q) || item.summary.toLowerCase().includes(q);
    });
  });

  protected readonly filteredSaved = computed<ComposerMcuSocket[]>(() => {
    const q = this.search().trim().toLowerCase();
    return this.savedPresets().filter((s) => {
      if (!q) return true;
      return s.partLabel.toLowerCase().includes(q) || s.packageLabel.toLowerCase().includes(q);
    });
  });

  public ngOnInit(): void {
    this.nextDesignator.set(defaultDesignatorForCount(this.existingCount()));
  }

  protected onSearchInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.search.set(e.target.value);
  }

  protected onDesignatorChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.nextDesignator.set(e.target.value);
  }

  protected onLinkChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.interconnect.set(e.target.value);
  }

  protected deleteSavedPreset(id: string): void {
    const next = this.savedPresets().filter((s) => s.id !== id);
    this.savedPresets.set(next);
    saveCustomSiliconPresets(next);
    if (this.selectedId() === id) this.selectedId.set(BUILTIN_SILICON_CATALOG[0]!.id);
  }

  protected submitPresetMcu(): void {
    const des = this.nextDesignator();
    const role = des === 'U1' ? 'Primary' : 'Companion';
    const saved = this.savedPresets().find((s) => s.id === this.selectedId());
    if (saved) {
      this.mcuAdded.emit({
        ...structuredClone(saved),
        id: `mcu-${Date.now().toString(36)}`,
        designator: des,
        role,
        interconnect: des === 'U1' ? 'None' : this.interconnect(),
      });
      return;
    }
    const item = BUILTIN_SILICON_CATALOG.find((s) => s.id === this.selectedId()) ?? BUILTIN_SILICON_CATALOG[3]!;
    this.mcuAdded.emit(buildSocketFromCatalog(item, des, role, des === 'U1' ? 'None' : this.interconnect()));
  }
}
