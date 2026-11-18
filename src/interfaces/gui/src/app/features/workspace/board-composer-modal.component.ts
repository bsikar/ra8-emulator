import { ChangeDetectionStrategy, Component, effect, input, output, signal } from '@angular/core';
import { type BoardPreset, serializeBoardProfile } from 'ra8-rpc-client';
import type {
  ComposerComponentAttachment,
  ComposerMcuSocket,
  ComposerMemoryRegion,
  StoredCustomBoardPreset,
} from '../../core/stores/board-composer.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
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

  protected readonly draft = signal<ComposerDraft>(createComposerDraft(null));
  protected readonly subModal = signal<ComposerSubModal>('none');
  protected readonly editingMcuIndex = signal<number>(0);
  private wasOpen = false;

  constructor() {
    effect(() => {
      const isOpen = this.open();
      const seed = this.seedPreset();
      if (isOpen && !this.wasOpen) {
        this.draft.set(createComposerDraft(seed));
        this.subModal.set('none');
        this.editingMcuIndex.set(0);
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

  protected addMemoryRegion(region: ComposerMemoryRegion): void {
    this.draft.update((d) => ({ ...d, memoryRegions: [...d.memoryRegions, region] }));
    this.subModal.set('none');
  }

  protected removeMemoryRegion(idx: number): void {
    this.draft.update((d) => ({
      ...d,
      memoryRegions: d.memoryRegions.filter((_, i) => i !== idx),
    }));
  }

  protected addComponent(comp: ComposerComponentAttachment): void {
    this.draft.update((d) => ({ ...d, components: [...d.components, comp] }));
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
