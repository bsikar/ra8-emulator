import { TestBed } from '@angular/core/testing';
import { LaunchConnectBarComponent } from '../../../src/app/features/launch/launch-connect-bar.component';
import { LaunchIconComponent } from '../../../src/app/features/launch/launch-icons.component';
import { LaunchNewWorkspaceDialogComponent } from '../../../src/app/features/launch/launch-new-workspace-dialog.component';

describe('Launch auxiliary components', () => {
  it('renders LaunchIconComponent SVG glyphs', async () => {
    const fixture = TestBed.createComponent(LaunchIconComponent);
    fixture.componentRef.setInput('name', 'pin');
    fixture.componentRef.setInput('filled', true);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();
    expect(fixture.nativeElement.querySelector('svg')).toBeTruthy();
  });

  it('emits url updates and connect trigger from LaunchConnectBarComponent', async () => {
    const fixture = TestBed.createComponent(LaunchConnectBarComponent);
    fixture.componentRef.setInput('wsUrl', 'ws://127.0.0.1:4567');
    fixture.componentRef.setInput('savedHosts', ['ws://127.0.0.1:4567']);
    let latestUrl = '';
    let connectedClicks = 0;
    fixture.componentInstance.wsUrlChange.subscribe((val) => {
      latestUrl = val;
    });
    fixture.componentInstance.connectPressed.subscribe(() => {
      connectedClicks += 1;
    });
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const input = fixture.nativeElement.querySelector('[data-testid="launch-ws-input"]') as HTMLInputElement;
    input.value = 'ws://127.0.0.1:9999';
    input.dispatchEvent(new Event('input'));
    (fixture.nativeElement.querySelector('[data-testid="launch-connect-btn"]') as HTMLButtonElement).click();

    expect(latestUrl).toBe('ws://127.0.0.1:9999');
    expect(connectedClicks).toBe(1);
  });

  it('creates a workspace payload from LaunchNewWorkspaceDialogComponent', async () => {
    const fixture = TestBed.createComponent(LaunchNewWorkspaceDialogComponent);
    fixture.componentRef.setInput('open', true);
    let createdModel = '';
    fixture.componentInstance.created.subscribe((payload) => {
      createdModel = payload.preset.targetId;
    });
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    (fixture.nativeElement.querySelector('[data-testid="preset-fpb-ra8e1"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    (fixture.nativeElement.querySelector('[data-testid="new-ws-create-btn"]') as HTMLButtonElement).click();
    expect(createdModel).toBe('fpb-ra8e1');
  });
});
