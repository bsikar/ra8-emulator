import { TestBed } from '@angular/core/testing';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ProfileStore } from '../../../src/app/core/stores/profile.store';
import { ProfileMetricsSidebarComponent } from '../../../src/app/features/profile/profile-metrics-sidebar.component';

describe('ProfileMetricsSidebarComponent', () => {
  it('renders METRICS & STACKS, host RSS sparkline, and PSP limit warnings', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const profile = TestBed.inject(ProfileStore);
    rpc.connectionState.set('connected');

    profile.metrics.set({
      hostCpuPercent: 28,
      hostRssMb: 142,
      hostThreads: 4,
      cpu0LoadPercent: 64,
      cpu0Pinned: 1,
      cpu0RamUsedBytes: 16_384,
      cpu0RamTotalBytes: 65_536,
      cpu1LoadPercent: 0,
      cpu1Pinned: 0,
      cpu1RamUsedBytes: 0,
      cpu1RamTotalBytes: 0,
    });
    profile.hostCpuHistory.set([18, 28]);
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

    const fixture = TestBed.createComponent(ProfileMetricsSidebarComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('METRICS & STACKS');
    expect(el.textContent).toContain('142 MiB');
    expect(el.textContent).toContain('Near PSPLIM');
    expect(el.querySelector('svg.spark-svg polyline')).not.toBeNull();
  });
});
