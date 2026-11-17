import { ChangeDetectionStrategy, Component, signal } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';
import type { LiveSessionItem } from '../../../src/app/core/stores/remote-hosts.types';
import { ConnectLiveSessionsComponent } from '../../../src/app/features/connect/connect-live-sessions.component';

@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ConnectLiveSessionsComponent],
  template: `
    <app-connect-live-sessions
      [sessions]="sessions()"
      [rescanning]="false"
      (rescan)="rescanCount = rescanCount + 1"
      (attach)="lastAttach = $event"
      (togglePin)="lastPinned = $event"
    />
  `,
})
class LiveSessionsHostComponent {
  public sessions = signal<LiveSessionItem[]>([]);
  public rescanCount = 0;
  public lastAttach: { session: LiveSessionItem; observe: boolean } | null = null;
  public lastPinned = '';
}

describe('ConnectLiveSessionsComponent', () => {
  it('renders empty state cleanly, emits rescan, and attaches normal vs observe mode', async () => {
    TestBed.configureTestingModule({});
    const fixture = TestBed.createComponent(LiveSessionsHostComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="connect-live-empty"]')).toBeTruthy();

    (el.querySelector('[data-testid="connect-rescan-btn"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.rescanCount).toBe(1);

    fixture.componentInstance.sessions.set([
      {
        id: 'sess-1',
        title: 'EK-RA8D2 (Local)',
        archSummary: 'Cortex-M85 + State',
        wsUrl: 'ws://127.0.0.1:4567',
        elfName: 'blink.elf',
        latencyMs: 0.4,
        status: 'loopback',
        pinned: false,
        caps: 0,
      },
    ]);
    fixture.detectChanges();
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="live-session-row-0"]')).toBeTruthy();
    expect(el.textContent).toContain('Loopback · 0.4 ms');

    (el.querySelector('[data-testid="live-session-observe-0"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.lastAttach?.observe).toBe(true);

    (el.querySelector('[data-testid="live-session-pin-0"]') as HTMLButtonElement).click();
    expect(fixture.componentInstance.lastPinned).toBe('sess-1');
  });
});
