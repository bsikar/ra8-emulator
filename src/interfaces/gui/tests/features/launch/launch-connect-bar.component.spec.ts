import { TestBed } from '@angular/core/testing';
import { LaunchConnectBarComponent } from '../../../src/app/features/launch/launch-connect-bar.component';

describe('LaunchConnectBarComponent', () => {
  it('emits url updates, saved host clicks, and connect trigger', async () => {
    const fixture = TestBed.createComponent(LaunchConnectBarComponent);
    fixture.componentRef.setInput('wsUrl', 'ws://127.0.0.1:4567');
    fixture.componentRef.setInput('savedHosts', ['ws://127.0.0.1:4567', 'ws://127.0.0.1:5000']);
    let latestUrl = '';
    let selectedHost = '';
    let connectedClicks = 0;
    fixture.componentInstance.wsUrlChange.subscribe((val) => {
      latestUrl = val;
    });
    fixture.componentInstance.connectHost.subscribe((host) => {
      selectedHost = host;
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

    const hostBtn = fixture.nativeElement.querySelectorAll('.host-chip')[1] as HTMLButtonElement;
    hostBtn.click();

    expect(latestUrl).toBe('ws://127.0.0.1:9999');
    expect(connectedClicks).toBe(1);
    expect(selectedHost).toBe('ws://127.0.0.1:5000');
  });
});
