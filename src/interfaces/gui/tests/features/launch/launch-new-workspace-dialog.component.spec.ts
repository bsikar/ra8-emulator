import { TestBed } from '@angular/core/testing';
import { LaunchNewWorkspaceDialogComponent } from '../../../src/app/features/launch/launch-new-workspace-dialog.component';

describe('LaunchNewWorkspaceDialogComponent', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('selects board presets, switches execution mode, and emits NewWorkspacePayload', async () => {
    const fixture = TestBed.createComponent(LaunchNewWorkspaceDialogComponent);
    fixture.componentRef.setInput('open', true);
    let createdModel = '';
    let createdMode = '';
    fixture.componentInstance.created.subscribe((payload) => {
      createdModel = payload.preset.targetId;
      createdMode = payload.modeLabel;
    });
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    (fixture.nativeElement.querySelector('[data-testid="preset-fpb-ra8e1"]') as HTMLButtonElement).click();
    const modeBtns = fixture.nativeElement.querySelectorAll('.mode-tab') as NodeListOf<HTMLButtonElement>;
    modeBtns[2]!.click();
    await fixture.whenStable();

    (fixture.nativeElement.querySelector('[data-testid="new-ws-create-btn"]') as HTMLButtonElement).click();
    expect(createdModel).toBe('fpb-ra8e1');
    expect(createdMode).toBe('Prebuilt .elf');
  });

  it('filters boards, opens Board Details modal, and duplicates a custom profile', async () => {
    const fixture = TestBed.createComponent(LaunchNewWorkspaceDialogComponent);
    fixture.componentRef.setInput('open', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const search = el.querySelector('[data-testid="new-ws-board-search"]') as HTMLInputElement;
    search.value = 'ra8p1';
    search.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    expect(el.querySelectorAll('.preset-item').length).toBe(1);
    (el.querySelector('[data-testid="board-details-btn-ra8p1"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    const modal = el.querySelector('[data-testid="board-details-modal"]');
    expect(modal).toBeTruthy();
    expect(modal?.textContent).toContain('R7KA8P1KFLCAC');
    expect(modal?.textContent).toContain('Ethos-U55');

    (el.querySelector('[data-testid="board-details-close-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(el.querySelector('[data-testid="board-details-modal"]')).toBeNull();

    search.value = '';
    search.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    (el.querySelector('[data-testid="board-duplicate-btn-ra8d2"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(el.textContent).toContain('Custom');
  });
});
