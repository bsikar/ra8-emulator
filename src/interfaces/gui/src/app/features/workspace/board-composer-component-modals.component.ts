import { ChangeDetectionStrategy, Component, OnInit, computed, input, output, signal } from '@angular/core';
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

const PIN_CHOICES: readonly string[] = [
  'P004', 'P005', 'P008', 'P009', 'P100', 'P101', 'P102', 'P103',
  'P301', 'P302', 'P303', 'P400', 'P401', 'P408', 'P409', 'P410',
  'P511', 'P512', 'P600', 'PA07', 'CEU Port A',
];

const ELECTRICAL_MODES: readonly string[] = [
  'Input · Pull-up',
  'Push-Pull',
  'Open-Drain',
  'Rising Edge IRQ',
  'Falling Edge IRQ',
  'Active-Low CS',
  'Output',
  'Analog Input',
];

function defaultPinsForInterface(iface: ComposerInterfaceKind): ComposerPinSignal[] {
  if (iface === 'SPI (COPI / CIPO / CS)') {
    return [
      { signal: 'SCK', pin: 'P102', electrical: 'Push-Pull' },
      { signal: 'COPI', pin: 'P101', electrical: 'Push-Pull' },
      { signal: 'CIPO', pin: 'P100', electrical: 'Input · Pull-up' },
      { signal: 'CS', pin: 'P103', electrical: 'Active-Low CS' },
    ];
  }
  if (iface === 'I2C (Peripheral)') {
    return [
      { signal: 'SCL', pin: 'P512', electrical: 'Open-Drain' },
      { signal: 'SDA', pin: 'P511', electrical: 'Open-Drain' },
    ];
  }
  if (iface === 'UART (SCI)') {
    return [
      { signal: 'TXD', pin: 'P302', electrical: 'Push-Pull' },
      { signal: 'RXD', pin: 'P301', electrical: 'Input · Pull-up' },
    ];
  }
  if (iface === 'ADC / Analog') {
    return [{ signal: 'AIN0', pin: 'P004', electrical: 'Analog Input' }];
  }
  return [
    { signal: 'PHA', pin: 'P408', electrical: 'Input · Pull-up' },
    { signal: 'PHB', pin: 'P409', electrical: 'Input · Pull-up' },
    { signal: 'INDEX', pin: 'P410', electrical: 'Rising Edge IRQ' },
  ];
}

function pinOptionsFor(pin: string): readonly string[] {
  return PIN_CHOICES.includes(pin) ? PIN_CHOICES : [pin, ...PIN_CHOICES];
}

@Component({
  selector: 'app-board-composer-component-modals',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  templateUrl: './board-composer-component-modals.component.html',
  styleUrl: './board-composer.css',
})
export class BoardComposerComponentModalsComponent implements OnInit {
  public readonly mode = input.required<ComponentSubModalKind>();
  public readonly mcus = input<readonly ComposerMcuSocket[]>([]);
  public readonly initialComponent = input<ComposerComponentAttachment | null>(null);
  public readonly cancelled = output<void>();
  public readonly switchMode = output<ComponentSubModalKind>();
  public readonly componentAdded = output<ComposerComponentAttachment>();

  protected readonly catalogFilters: readonly CatalogFilter[] = ['All', 'Displays', 'Sensors', 'Comms', 'GPIO', 'Saved Custom'];
  protected readonly interfaceTypes = INTERFACE_TYPES;
  protected readonly simModels = SIM_MODELS;
  protected readonly electricalModes = ELECTRICAL_MODES;

  protected readonly query = signal<string>('');
  protected readonly filter = signal<CatalogFilter>('All');
  protected readonly selectedCatalogId = signal<string>(BUILTIN_COMPONENT_CATALOG[0]!.id);
  protected readonly mountSocket = signal<string>('U1');
  protected readonly hostFrameSource = signal<string>('Synthetic Pattern / Video / Webcam');
  protected readonly catalogPins = signal<ComposerPinSignal[]>(
    BUILTIN_COMPONENT_CATALOG[0]!.defaultAttachment.pins.map((p) => ({ ...p }))
  );
  protected readonly savedLibrary = signal<ComposerComponentAttachment[]>(loadCustomComponentLibrary());

  protected readonly customName = signal<string>('Hall Quadrature Encoder');
  protected readonly customIface = signal<ComposerInterfaceKind>('GPIO / Timer');
  protected readonly simModel = signal<ComposerSimModelKind>('Scripted / Register Map');
  protected readonly modelSource = signal<string>('models/hall_encoder.zig');
  protected readonly saveReusable = signal<boolean>(true);
  protected readonly customPins = signal<ComposerPinSignal[]>(defaultPinsForInterface('GPIO / Timer'));

  protected readonly filteredCatalog = computed<ComponentCatalogItem[]>(() => {
    const q = this.query().trim().toLowerCase();
    const cat = this.filter();
    return BUILTIN_COMPONENT_CATALOG.filter((item) => {
      if (cat !== 'All' && cat !== 'Saved Custom' && item.category !== cat) return false;
      return !q || item.name.toLowerCase().includes(q) || item.summary.toLowerCase().includes(q);
    });
  });

  protected readonly filteredSavedLibrary = computed<ComposerComponentAttachment[]>(() => {
    const q = this.query().trim().toLowerCase();
    return this.savedLibrary().filter((item) => {
      if (!q) return true;
      return item.name.toLowerCase().includes(q) || item.endpointLabel.toLowerCase().includes(q);
    });
  });

  public ngOnInit(): void {
    const initial = this.initialComponent();
    if (!initial) {
      const firstSocket = this.mcus()[0]?.designator;
      if (firstSocket) this.mountSocket.set(firstSocket);
      return;
    }
    this.mountSocket.set(initial.mountSocket);
    this.customName.set(initial.name);
    this.customIface.set(initial.interfaceKind);
    this.customPins.set(structuredClone(initial.pins));
    if (initial.simModelKind) this.simModel.set(initial.simModelKind);
    if (initial.modelSource) this.modelSource.set(initial.modelSource);
  }

  protected selectCatalogItem(id: string): void {
    this.selectedCatalogId.set(id);
    const saved = this.savedLibrary().find((s) => s.id === id);
    if (saved) {
      this.catalogPins.set(saved.pins.map((p) => ({ ...p })));
      return;
    }
    const item = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === id) ?? BUILTIN_COMPONENT_CATALOG[0]!;
    this.catalogPins.set(item.defaultAttachment.pins.map((p) => ({ ...p })));
  }

  protected pinOptions(pin: string): readonly string[] {
    return pinOptionsFor(pin);
  }

  protected onCatalogPinChange(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const pin = e.target.value;
    this.catalogPins.update((rows) => rows.map((r, i) => (i === idx ? { ...r, pin } : r)));
  }

  protected onQueryInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) this.query.set(e.target.value);
  }
  protected onMountChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.mountSocket.set(e.target.value);
  }
  protected onFrameSourceChange(e: Event): void {
    if (e.target instanceof HTMLSelectElement) this.hostFrameSource.set(e.target.value);
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
    this.customPins.set(defaultPinsForInterface(iface));
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
  protected onSignalElectrical(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const electrical = e.target.value;
    this.customPins.update((rows) => rows.map((r, i) => (i === idx ? { ...r, electrical } : r)));
  }

  protected submitCatalogComponent(): void {
    const pins = structuredClone(this.catalogPins());
    const saved = this.savedLibrary().find((s) => s.id === this.selectedCatalogId());
    if (saved) {
      this.componentAdded.emit({ ...structuredClone(saved), id: `comp-${Date.now().toString(36)}`, mountSocket: this.mountSocket(), pins });
      return;
    }
    const item = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === this.selectedCatalogId()) ?? BUILTIN_COMPONENT_CATALOG[0]!;
    this.componentAdded.emit({
      id: `comp-${Date.now().toString(36)}`,
      ...structuredClone(item.defaultAttachment),
      mountSocket: this.mountSocket(),
      pins,
      modelSource: item.id === 'ov5640' ? this.hostFrameSource() : undefined,
    });
  }

  protected submitCustomComponent(): void {
    const iface = this.customIface();
    const initial = this.initialComponent();
    const endpointLabel =
      iface === 'SPI (COPI / CIPO / CS)'
        ? 'SPI0 CS0'
        : iface === 'I2C (Peripheral)'
          ? 'RIIC0 (0x48)'
          : iface === 'UART (SCI)'
            ? 'SCI3 UART'
            : iface === 'ADC / Analog'
              ? 'ADC0 CH0'
              : 'GPT0 / GPIO';
    const created: ComposerComponentAttachment = {
      id: initial?.id ?? `custom-comp-${Date.now().toString(36)}`,
      name: this.customName().trim() || 'Custom Peripheral',
      category: initial?.category ?? 'Custom',
      isCustom: initial ? initial.isCustom : true,
      mountSocket: this.mountSocket(),
      endpointLabel: initial?.endpointLabel ?? endpointLabel,
      fitSpec: initial?.fitSpec ?? null,
      interfaceKind: iface,
      pins: structuredClone(this.customPins()),
      simModelKind: this.simModel(),
      modelSource: this.modelSource().trim(),
    };
    if (this.saveReusable() && !initial) {
      const nextLib = [created, ...this.savedLibrary()];
      this.savedLibrary.set(nextLib);
      saveCustomComponentLibrary(nextLib);
    }
    this.componentAdded.emit(created);
  }
}
