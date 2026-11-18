import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileMetricsSidebarComponent } from '../../../src/app/features/profile/profile-metrics-sidebar.component';

describe('ProfileMetricsSidebarComponent', () => {
  it('renders METRICS & STACKS, CPU0/CPU1 MSP+PSP watermarks, pacing/pinned alerts, and CPU/RSS sparklines', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const profile = TestBed.inject(ProfileStore);
    rpc.connectionState.set('connected');
    execution.cpu1Attached.set(true);

    profile.metrics.set({
      hostCpuPercent: 28,
      hostRssMb: 142,
      hostThreads: 4,
      cpu0LoadPercent: 64,
      cpu0Pinned: 1,
      cpu0RamUsedBytes: 16_384,
      cpu0RamTotalBytes: 65_536,
      cpu1LoadPercent: 18,
      cpu1Pinned: 0,
      cpu1RamUsedBytes: 8_192,
      cpu1RamTotalBytes: 32_768,
    });
    profile.hostCpuHistory.set([18, 28]);
    profile.hostRssHistory.set([136, 142]);
    profile.pacingRatio.set(0.24);
    profile.cpu0Stack.set({
      core: Core.Cpu0,
      msp: 0x2000_2000,
      psp: 0x2000_0400,
      lowMsp: 0x2000_1800,
      lowPsp: 0x2000_0080,
      hasStack: true,
      base: 0x2000_0000,
      size: 0x2000,
      overflow: 0,
    });
    profile.cpu1Stack.set({
      core: Core.Cpu1,
      msp: 0x2001_1000,
      psp: 0x2001_0100,
      lowMsp: 0x2001_0e00,
      lowPsp: 0x2001_0040,
      hasStack: true,
      base: 0x2001_0000,
      size: 0x1000,
      overflow: 0,
    });

    const fixture = TestBed.createComponent(ProfileMetricsSidebarComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('METRICS & STACKS');
    expect(el.textContent).toContain('142 MiB');
    expect(el.textContent).toContain('CPU1 PSP');
    expect(el.textContent).toContain('Near PSPLIM');
    expect(el.querySelector('[data-testid="profile-cpu0-psp-alert"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="profile-cpu1-psp-alert"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="profile-pacing-alert"]')?.textContent).toContain('<0.35x');
    expect(el.querySelector('[data-testid="profile-pinned-alert"]')?.textContent).toContain('CPU0 Pinned');
    expect(el.querySelector('[data-testid="profile-cpu-sparkline"] polyline')).not.toBeNull();
    expect(el.querySelector('[data-testid="profile-rss-sparkline"] polyline')).not.toBeNull();
  });
});
