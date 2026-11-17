import { TestBed } from '@angular/core/testing';
import { LaunchNewWorkspaceDialogComponent } from '../../../src/app/features/launch/launch-new-workspace-dialog.component';

describe('LaunchNewWorkspaceDialogComponent', () => {
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
});
