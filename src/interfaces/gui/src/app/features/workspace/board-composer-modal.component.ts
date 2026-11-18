import { ChangeDetectionStrategy, Component, effect, input, output, signal } from '@angular/core';
import { type BoardPreset, type BoardSiliconPart, serializeBoardProfile } from 'ra8-rpc-client';
import type {
  ComposerComponentAttachment,
  ComposerMcuSocket,
  ComposerMemoryRegion,
  StoredCustomBoardPreset,
} from '../../core/stores/board-composer.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { BUILTIN_SILICON_CATALOG, buildSocketFromCatalog } from './board-composer-catalog';
import {
  BoardComposerComponentModalsComponent,
  type ComponentSubModalKind,
} from './board-composer-component-modals.component';
import { BoardComposerCoresModalComponent } from './board-composer-cores-modal.component';
import {
  BoardComposerMcuModalsComponent,
  type McuSubModalKind,
} from './board-composer-mcu-modals.component';
import { BoardComposerMemoryModalComponent } from './board-composer-memory-modal.component';
import {
  type ComposerDraft,
  compileDraftToBoardPreset,
  createComposerDraft,
} from './board-composer-model';

export type ComposerSubModal =
  | 'none'
  | 'cores'
  | 'preset-mcu'
  | 'custom-silicon'
  | 'memory'
  | 'catalog-component'
  | 'custom-component';

@Component({
  selector: 'app-board-composer-modal',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    SectionKickerComponent,
    TonalButtonComponent,
    BoardComposerCoresModalComponent,
    BoardComposerMcuModalsComponent,
    BoardComposerMemoryModalComponent,
    BoardComposerComponentModalsComponent,
  ],
  templateUrl: './board-composer-modal.component.html',
  styleUrl: './board-composer.css',
})
export class BoardComposerModalComponent {
  public readonly open = input<boolean>(false);
  public readonly seedPreset = input<BoardPreset | StoredCustomBoardPreset | null>(null);
  public readonly closed = output<void>();
  public readonly saved = output<StoredCustomBoardPreset>();
  public readonly removed = output<string>();

  protected readonly siliconOptions = BUILTIN_SILICON_CATALOG;
  protected readonly draft = signal<ComposerDraft>(createComposerDraft(null));
  protected readonly subModal = signal<ComposerSubModal>('none');
  protected readonly editingMcuIndex = signal<number>(0);
  protected readonly editingMemoryIndex = signal<number | null>(null);
  protected readonly editingComponentIndex = signal<number | null>(null);
  private wasOpen = false;

  constructor() {
    effect(() => {
      const isOpen = this.open();
      const seed = this.seedPreset();
      if (isOpen && !this.wasOpen) {
        this.draft.set(createComposerDraft(seed));
        this.subModal.set('none');
        this.editingMcuIndex.set(0);
        this.editingMemoryIndex.set(null);
        this.editingComponentIndex.set(null);
      }
      this.wasOpen = isOpen;
    });
  }

  protected mcuSummary(mcu: ComposerMcuSocket): string {
    const cores = mcu.cores.map((c) => `${c.arch} @ ${c.clockMhz} MHz`).join(' · ');
    return mcu.interconnect !== 'None' ? `${cores} · Interconnect: ${mcu.interconnect}` : cores;
  }

  protected editingSocket(): ComposerMcuSocket {
    return this.draft().mcus[this.editingMcuIndex()] ?? this.draft().mcus[0]!;
  }

  protected editingMemoryRegion(): ComposerMemoryRegion | null {
    const idx = this.editingMemoryIndex();
    return idx === null ? null : (this.draft().memoryRegions[idx] ?? null);
  }

  protected editingComponent(): ComposerComponentAttachment | null {
    const idx = this.editingComponentIndex();
    return idx === null ? null : (this.draft().components[idx] ?? null);
  }

  protected onBackdropClick(): void {
    if (this.subModal() !== 'none') {
      this.subModal.set('none');
    } else {
      this.closed.emit();
    }
  }

  protected onEscape(event: Event): void {
    event.stopPropagation();
    this.onBackdropClick();
  }

  protected onBoardNameInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) {
      const boardName = e.target.value;
      this.draft.update((d) => ({ ...d, boardName }));
    }
  }

  protected onProfileFileInput(e: Event): void {
    if (e.target instanceof HTMLInputElement) {
      const profileFile = e.target.value;
      this.draft.update((d) => ({ ...d, profileFile }));
    }
  }

  protected onMcuSiliconChange(idx: number, e: Event): void {
    if (!(e.target instanceof HTMLSelectElement)) return;
    const silicon = e.target.value as BoardSiliconPart;
    const cat = BUILTIN_SILICON_CATALOG.find((s) => s.silicon === silicon);
    if (!cat) return;
    this.draft.update((d) => ({
      ...d,
      mcus: d.mcus.map((m, i) =>
        i === idx ? buildSocketFromCatalog(cat, m.designator, m.role, m.interconnect) : m
      ),
    }));
  }

  protected openCoresModal(idx: number): void {
    this.editingMcuIndex.set(idx);
    this.subModal.set('cores');
  }

  protected applyCoresConfig(updated: ComposerMcuSocket): void {
    const idx = this.editingMcuIndex();
    this.draft.update((d) => ({
      ...d,
      mcus: d.mcus.map((m, i) => (i === idx ? updated : m)),
    }));
    this.subModal.set('none');
  }

  protected addMcuSocket(socket: ComposerMcuSocket): void {
    this.draft.update((d) => ({ ...d, mcus: [...d.mcus, socket] }));
    this.subModal.set('none');
  }

  protected switchMcuSubModal(kind: McuSubModalKind): void {
    this.subModal.set(kind);
  }

  protected removeMcu(idx: number): void {
    if (this.draft().mcus.length <= 1) return;
    this.draft.update((d) => ({ ...d, mcus: d.mcus.filter((_, i) => i !== idx) }));
  }

  protected openMemoryModal(idx: number | null): void {
    this.editingMemoryIndex.set(idx);
    this.subModal.set('memory');
  }

  protected saveMemoryRegion(region: ComposerMemoryRegion): void {
    const idx = this.editingMemoryIndex();
    this.draft.update((d) => ({
      ...d,
      memoryRegions:
        idx === null
          ? [...d.memoryRegions, region]
          : d.memoryRegions.map((r, i) => (i === idx ? region : r)),
    }));
    this.editingMemoryIndex.set(null);
    this.subModal.set('none');
  }

  protected removeMemoryRegion(idx: number): void {
    if (this.draft().memoryRegions.length <= 1) return;
    this.draft.update((d) => ({
      ...d,
      memoryRegions: d.memoryRegions.filter((_, i) => i !== idx),
    }));
  }

  protected openComponentModal(mode: ComponentSubModalKind, idx: number | null = null): void {
    this.editingComponentIndex.set(idx);
    this.subModal.set(mode);
  }

  protected saveComponent(comp: ComposerComponentAttachment): void {
    const idx = this.editingComponentIndex();
    this.draft.update((d) => ({
      ...d,
      components:
        idx === null
          ? [...d.components, comp]
          : d.components.map((c, i) => (i === idx ? comp : c)),
    }));
    this.editingComponentIndex.set(null);
    this.subModal.set('none');
  }

  protected switchComponentSubModal(kind: ComponentSubModalKind): void {
    this.subModal.set(kind);
  }

  protected removeComponent(idx: number): void {
    this.draft.update((d) => ({
      ...d,
      components: d.components.filter((_, i) => i !== idx),
    }));
  }

  protected exportBoardFile(): void {
    const compiled = compileDraftToBoardPreset(this.draft());
    const text = serializeBoardProfile(compiled.profile);
    if (typeof document === 'undefined' || typeof URL === 'undefined') return;
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const href = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = href;
    a.download = compiled.composer?.profileFile ?? `${compiled.targetId}.board`;
    a.click();
    URL.revokeObjectURL(href);
  }

  protected saveBoard(): void {
    this.saved.emit(compileDraftToBoardPreset(this.draft()));
  }

  protected removeCurrentBoard(): void {
    if (this.draft().isExistingCustom) {
      this.removed.emit(this.draft().id);
    }
  }
}
