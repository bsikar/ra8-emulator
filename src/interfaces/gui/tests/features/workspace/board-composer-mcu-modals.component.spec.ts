import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';
import type { ComposerMcuSocket } from '../../../src/app/core/stores/board-composer.types';
import { BoardComposerCustomSiliconModalComponent } from '../../../src/app/features/workspace/board-composer-custom-silicon-modal.component';
import { BoardComposerPresetMcuModalComponent } from '../../../src/app/features/workspace/board-composer-preset-mcu-modal.component';

describe('BoardComposerPresetMcuModalComponent & CustomSiliconModalComponent', () => {
  it('auto-selects next socket designator, adds/removes on-chip regions, and emits custom silicon', async () => {
    localStorage.clear();
    TestBed.configureTestingModule({});

    const presetFix = TestBed.createComponent(BoardComposerPresetMcuModalComponent);
    presetFix.componentRef.setInput('existingCount', 2);
    presetFix.detectChanges();
    await presetFix.whenStable();
    const select = presetFix.nativeElement.querySelector('[data-testid="preset-mcu-designator"]') as HTMLSelectElement;
    expect(select.value).toBe('U3');

    const siliconFix = TestBed.createComponent(BoardComposerCustomSiliconModalComponent);
    let emitted: ComposerMcuSocket | null = null;
    siliconFix.componentInstance.mcuAdded.subscribe((s) => {
      emitted = s;
    });
    siliconFix.componentRef.setInput('existingCount', 1);
    siliconFix.detectChanges();
    await siliconFix.whenStable();

    const el: HTMLElement = siliconFix.nativeElement;
    expect(el.textContent).toContain('ON-CHIP MEMORY MAP');
    (el.querySelector('[data-testid="custom-silicon-add-onchip-btn"]') as HTMLButtonElement).click();
    siliconFix.detectChanges();
    (el.querySelector('[data-testid="custom-silicon-submit"]') as HTMLButtonElement).click();
    siliconFix.detectChanges();

    expect(emitted).not.toBeNull();
    expect(emitted!.onChipMemory.length).toBe(3);
  });
});
