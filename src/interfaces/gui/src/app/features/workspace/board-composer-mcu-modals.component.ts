import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import type { ComposerMcuSocket } from '../../core/stores/board-composer.types';
import { BoardComposerCustomSiliconModalComponent } from './board-composer-custom-silicon-modal.component';
import { BoardComposerPresetMcuModalComponent } from './board-composer-preset-mcu-modal.component';

export type McuSubModalKind = 'preset-mcu' | 'custom-silicon';

@Component({
  selector: 'app-board-composer-mcu-modals',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [BoardComposerPresetMcuModalComponent, BoardComposerCustomSiliconModalComponent],
  template: `
    @if (mode() === 'preset-mcu') {
      <app-board-composer-preset-mcu-modal
        [existingCount]="existingCount()"
        (cancelled)="onCancel()"
        (switchToCustom)="openNewCustom()"
        (editSaved)="openEditSaved($event)"
        (mcuAdded)="mcuAdded.emit($event)"
      />
    } @else {
      <app-board-composer-custom-silicon-modal
        [existingCount]="existingCount()"
        [editingPreset]="editingPreset()"
        (cancelled)="onCustomCancel()"
        (presetSaved)="onPresetSaved()"
        (mcuAdded)="onCustomAdded($event)"
      />
    }
  `,
})
export class BoardComposerMcuModalsComponent {
  public readonly mode = input.required<McuSubModalKind>();
  public readonly existingCount = input<number>(1);
  public readonly cancelled = output<void>();
  public readonly switchMode = output<McuSubModalKind>();
  public readonly mcuAdded = output<ComposerMcuSocket>();

  protected readonly editingPreset = signal<ComposerMcuSocket | null>(null);

  protected openNewCustom(): void {
    this.editingPreset.set(null);
    this.switchMode.emit('custom-silicon');
  }

  protected openEditSaved(preset: ComposerMcuSocket): void {
    this.editingPreset.set(preset);
    this.switchMode.emit('custom-silicon');
  }

  protected onCancel(): void {
    this.editingPreset.set(null);
    this.cancelled.emit();
  }

  protected onCustomCancel(): void {
    if (this.editingPreset()) {
      this.editingPreset.set(null);
      this.switchMode.emit('preset-mcu');
      return;
    }
    this.cancelled.emit();
  }

  protected onPresetSaved(): void {
    this.editingPreset.set(null);
    this.switchMode.emit('preset-mcu');
  }

  protected onCustomAdded(socket: ComposerMcuSocket): void {
    this.editingPreset.set(null);
    this.mcuAdded.emit(socket);
  }
}
