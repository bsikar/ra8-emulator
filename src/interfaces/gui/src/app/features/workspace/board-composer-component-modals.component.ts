import { ChangeDetectionStrategy, Component, computed, input, output, signal } from '@angular/core';
import type {
  ComposerComponentAttachment,
  ComposerInterfaceKind,
  ComposerMcuSocket,
  ComposerPinSignal,
  ComposerSimModelKind,
} from '../../core/stores/board-composer.types';
import { loadCustomComponentLibrary, saveCustomComponentLibrary } from '../../core/stores/board-storage';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { BUILTIN_COMPONENT_CATALOG, type ComponentCatalogItem } from './board-composer-catalog';

export type ComponentSubModalKind = 'catalog-component' | 'custom-component';
type CatalogFilter = 'All' | 'Displays' | 'Sensors' | 'Comms' | 'GPIO' | 'Saved Custom';

const INTERFACE_TYPES: readonly ComposerInterfaceKind[] = [
  'GPIO / Timer',
  'I2C (Peripheral)',
  'SPI (COPI / CIPO / CS)',
  'UART (SCI)',
  'ADC / Analog',
];

const SIM_MODELS: readonly ComposerSimModelKind[] = [
  'Scripted / Register Map',
  'Stimulus CSV',
  'External Socket',
];

@Component({
  selector: 'app-board-composer-component-modals',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  templateUrl: './board-composer-component-modals.component.html',
  styleUrl: './board-composer.css',
})
export class BoardComposerComponentModalsComponent {
  public readonly mode = input.required<ComponentSubModalKind>();
  public readonly mcus = input<readonly ComposerMcuSocket[]>([]);
  public readonly cancelled = output<void>();
  public readonly switchMode = output<ComponentSubModalKind>();
  public readonly componentAdded = output<ComposerComponentAttachment>();

  protected readonly catalogFilters: readonly CatalogFilter[] = ['All', 'Displays', 'Sensors', 'Comms', 'GPIO', 'Saved Custom'];
  protected readonly interfaceTypes = INTERFACE_TYPES;
  protected readonly simModels = SIM_MODELS;

  protected readonly query = signal<string>('');
  protected readonly filter = signal<CatalogFilter>('All');
  protected readonly selectedCatalogId = signal<string>(BUILTIN_COMPONENT_CATALOG[0]!.id);
  protected readonly mountSocket = signal<string>('U1');
  protected readonly savedLibrary = signal<ComposerComponentAttachment[]>(loadCustomComponentLibrary());

  protected readonly customName = signal<string>('Hall Quadrature Encoder');
  protected readonly customIface = signal<ComposerInterfaceKind>('GPIO / Timer');
  protected readonly simModel = signal<ComposerSimModelKind>('Scripted / Register Map');
  protected readonly modelSource = signal<string>('models/hall_encoder.zig');
  protected readonly saveReusable = signal<boolean>(true);
  protected readonly customPins = signal<ComposerPinSignal[]>([
    { signal: 'PHA', pin: 'P408', electrical: 'Input · Pull-up' },
    { signal: 'PHB', pin: 'P409', electrical: 'Input · Pull-up' },
    { signal: 'INDEX', pin: 'P410', electrical: 'Rising Edge IRQ' },
  ]);

  protected readonly filteredCatalog = computed<ComponentCatalogItem[]>(() => {
    const q = this.query().trim().toLowerCase();
    const cat = this.filter();
    return BUILTIN_COMPONENT_CATALOG.filter((item) => {
      if (cat !== 'All' && cat !== 'Saved Custom' && item.category !== cat) return false;
      return !q || item.name.toLowerCase().includes(q) || item.summary.toLowerCase().includes(q);
    });
  });

  protected readonly activePreviewPins = computed<ComposerPinSignal[]>(() => {
    const saved = this.savedLibrary().find((s) => s.id === this.selectedCatalogId());
    if (saved) return saved.pins;
    const item = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === this.selectedCatalogId()) ?? BUILTIN_COMPONENT_CATALOG[0]!;
    return item.defaultAttachment.pins;
  });

  protected onQueryInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.query.set(e.target.value);
  }
  protected onMountChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.mountSocket.set(e.target.value);
  }
  protected onCustomName(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.customName.set(e.target.value);
  }
  protected onModelSource(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.modelSource.set(e.target.value);
  }
  protected onSaveToggle(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.saveReusable.set(e.target.checked);
  }

  protected selectInterface(iface: ComposerInterfaceKind): void {
    this.customIface.set(iface);
    if (iface === 'SPI (COPI / CIPO / CS)') {
      this.customPins.set([
        { signal: 'SCK', pin: 'P102', electrical: 'Push-Pull' },
        { signal: 'COPI', pin: 'P101', electrical: 'Push-Pull' },
        { signal: 'CIPO', pin: 'P100', electrical: 'Input · Pull-up' },
        { signal: 'CS', pin: 'P103', electrical: 'Active-Low CS' },
      ]);
    } else if (iface === 'I2C (Peripheral)') {
      this.customPins.set([
        { signal: 'SCL', pin: 'P512', electrical: 'Open-Drain' },
        { signal: 'SDA', pin: 'P511', electrical: 'Open-Drain' },
      ]);
    }
  }

  protected addSignalRow(): void {
    const idx = this.customPins().length;
    this.customPins.update((rows) => [...rows, { signal: `SIG${idx}`, pin: `P40${idx % 10}`, electrical: 'Input · Pull-up' }]);
  }
  protected removeSignalRow(idx: number): void {
    this.customPins.update((rows) => rows.filter((_, i) => i !== idx));
  }
  protected onSignalName(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLInputElement)) return;
    const signalName = e.target.value;
    this.customPins.update((rows) => rows.map((r, i) => (i === idx ? { ...r, signal: signalName } : r)));
  }
  protected onSignalPin(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLInputElement)) return;
    const pin = e.target.value;
    this.customPins.update((rows) => rows.map((r, i) => (i === idx ? { ...r, pin } : r)));
  }

  protected submitCatalogComponent(): void {
    const saved = this.savedLibrary().find((s) => s.id === this.selectedCatalogId());
    if (saved) {
      this.componentAdded.emit({ ...structuredClone(saved), id: `comp-${Date.now().toString(36)}`, mountSocket: this.mountSocket() });
      return;
    }
    const item = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === this.selectedCatalogId()) ?? BUILTIN_COMPONENT_CATALOG[0]!;
    this.componentAdded.emit({
      id: `comp-${Date.now().toString(36)}`,
      ...structuredClone(item.defaultAttachment),
      mountSocket: this.mountSocket(),
    });
  }

  protected submitCustomComponent(): void {
    const iface = this.customIface();
    const endpointLabel =
      iface === 'SPI (COPI / CIPO / CS)'
        ? 'SPI0 CS0'
        : iface === 'I2C (Peripheral)'
          ? 'RIIC0 (0x48)'
          : iface === 'UART (SCI)'
            ? 'SCI3 UART'
            : 'GPT0 / GPIO';
    const created: ComposerComponentAttachment = {
      id: `custom-comp-${Date.now().toString(36)}`,
      name: this.customName().trim() || 'Custom Peripheral',
      category: 'Custom',
      isCustom: true,
      mountSocket: this.mountSocket(),
      endpointLabel,
      fitSpec: null,
      interfaceKind: iface,
      pins: structuredClone(this.customPins()),
      simModelKind: this.simModel(),
      modelSource: this.modelSource().trim(),
    };
    if (this.saveReusable()) {
      const nextLib = [created, ...this.savedLibrary()];
      this.savedLibrary.set(nextLib);
      saveCustomComponentLibrary(nextLib);
    }
    this.componentAdded.emit(created);
  }
}
