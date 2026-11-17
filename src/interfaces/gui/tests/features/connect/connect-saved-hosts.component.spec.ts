import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';
import type { SavedHostProfile } from '../../../src/app/core/stores/remote-hosts.types';
import { ConnectSavedHostsComponent } from '../../../src/app/features/connect/connect-saved-hosts.component';

@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ConnectSavedHostsComponent],
  template: `
    <app-connect-saved-hosts
      [profiles]="profiles()"
      (connectProfile)="lastConnect = $event"
      (togglePin)="lastPinned = $event"
      (remove)="lastRemoved = $event"
    />
  `,
})
class SavedHostsHostComponent {
  public profiles = signal<SavedHostProfile[]>([]);
  public lastConnect: { profile: SavedHostProfile; observe: boolean } | null = null;
  public lastPinned = '';
  public lastRemoved = '';
}

describe('ConnectSavedHostsComponent', () => {
  it('renders empty state and handles connect, pin, and kebab remove', async () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(SavedHostsHostComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="connect-saved-empty"]')).toBeTruthy();

    fixture.componentInstance.profiles.set([
      {
        id: 'h1',
        name: 'hil-bench-04.local',
        endpointUrl: 'wss://hil-bench-04.local:8443/rpc',
        wsUrl: 'wss://hil-bench-04.local:8443/rpc',
        transportLabel: 'Token Auth · TLS',
        pinned: false,
        authMode: 'token',
        lastStatus: 'offline',
        lastConnectedIso: new Date(Date.now() - 3 * 86400_000).toISOString(),
      },
    ]);
    fixture.detectChanges();
    await fixture.whenStable();

    expect(el.textContent).toContain('hil-bench-04.local');
    expect(el.textContent).toContain('Token Auth · TLS');
    expect(el.textContent).toContain('Offline · 3d ago');

    (el.querySelector('[data-testid="saved-host-connect-h1"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.lastConnect?.observe).toBe(false);

    (el.querySelector('[data-testid="saved-host-pin-h1"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.lastPinned).toBe('h1');

    (el.querySelector('[data-testid="saved-host-menu-h1"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    (el.querySelector('[data-testid="saved-host-remove-h1"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.lastRemoved).toBe('h1');
  });
});
