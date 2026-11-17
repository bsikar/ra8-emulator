import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';
import type { RemoteAuthMode } from '../../../src/app/core/stores/remote-hosts.types';
import { ConnectDrawersComponent } from '../../../src/app/features/connect/connect-drawers.component';

@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ConnectDrawersComponent],
  template: `
    <app-connect-drawers
      [authOpen]="authOpen()"
      [sshOpen]="sshOpen()"
      [authMode]="authMode()"
      [sshHost]="sshHost()"
      [sshRemotePort]="remotePort()"
      [sshLocalPort]="localPort()"
      (authModeChange)="authMode.set($event)"
      (observeOnlyChange)="observed = $event"
      (saveProfile)="savedCount = savedCount + 1"
      (copySshCommand)="copiedCmd = $event"
    />
  `,
})
class DrawersHostComponent {
  public authOpen = signal(true);
  public sshOpen = signal(true);
  public authMode = signal<RemoteAuthMode>('token');
  public sshHost = signal('build@10.0.4.18');
  public remotePort = signal(4568);
  public localPort = signal(4900);
  public observed = false;
  public savedCount = 0;
  public copiedCmd = '';
}

describe('ConnectDrawersComponent', () => {
  it('renders Auth and SSH Tunnel drawers with synthesized OpenSSH command', async () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(DrawersHostComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="connect-auth-drawer"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="connect-ssh-drawer"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="connect-ssh-command"]')?.textContent).toContain(
      'ssh -N -L 4900:127.0.0.1:4568 build@10.0.4.18'
    );

    const observeBox = el.querySelector('[data-testid="connect-observe-checkbox"]') as HTMLInputElement;
    observeBox.checked = true;
    observeBox.dispatchEvent(new Event('change'));

    (el.querySelector('[data-testid="connect-copy-ssh-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="connect-save-profile-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    expect(fixture.componentInstance.observed).toBe(true);
    expect(fixture.componentInstance.copiedCmd).toContain('4900:127.0.0.1:4568');
    expect(fixture.componentInstance.savedCount).toBe(1);
  });
});
