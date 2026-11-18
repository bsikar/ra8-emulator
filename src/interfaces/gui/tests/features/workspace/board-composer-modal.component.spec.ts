import { TestBed } from '@angular/core/testing';
import type { StoredCustomBoardPreset } from '../../../src/app/core/stores/board-composer.types';
import { BoardComposerModalComponent } from '../../../src/app/features/workspace/board-composer-modal.component';

describe('BoardComposerModalComponent', () => {
  beforeEach(() => {
    localStorage.clear();
    HTMLAnchorElement.prototype.click = () => {};
    TestBed.configureTestingModule({});
  });

  it('walks sub-modals and emits compiled custom board preset', async () => {
    const fixture = TestBed.createComponent(BoardComposerModalComponent);
    let savedBoard: StoredCustomBoardPreset | null = null;
    fixture.componentInstance.saved.subscribe((b) => {
      savedBoard = b;
    });
    fixture.componentRef.setInput('open', true);
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="board-composer-modal"]')).toBeTruthy();

    // Edit MCU cores
    (el.querySelector('[data-testid="composer-edit-mcu-U1"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="composer-cores-modal"]')).toBeTruthy();
    (el.querySelector('[data-testid="cores-apply-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    // Add Preset MCU
    (el.querySelector('[data-testid="composer-open-preset-mcu"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="composer-preset-mcu-modal"]')).toBeTruthy();
    (el.querySelector('[data-testid="preset-mcu-row-ra4t1"]') as HTMLElement).click();
    fixture.detectChanges();
    (el.querySelector('[data-testid="preset-mcu-submit"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="composer-mcu-row-U2"]')).toBeTruthy();

    // Add Memory Region
    (el.querySelector('[data-testid="composer-open-add-memory"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="composer-memory-modal"]')).toBeTruthy();
    (el.querySelector('[data-testid="memory-submit-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    // Custom Component
    (el.querySelector('[data-testid="composer-open-custom-component"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="composer-custom-component-modal"]')).toBeTruthy();
    (el.querySelector('[data-testid="custom-comp-submit"]') as HTMLButtonElement).click();
    fixture.detectChanges();

    // Save custom board
    (el.querySelector('[data-testid="composer-save-btn"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(savedBoard).not.toBeNull();
    expect(savedBoard!.composer?.mcus.length).toBe(2);
  });
});
