import { TestBed } from '@angular/core/testing';
import { ForkReason } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindBranchSidebarComponent } from '../../../src/app/features/rewind/rewind-branch-sidebar.component';

describe('RewindBranchSidebarComponent', () => {
  it('renders EXECUTION BRANCHES, scrub cache telemetry, bookmarks, and prune/switch actions', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const rewind = TestBed.inject(RewindStore);
    rpc.connectionState.set('connected');

    let sought = '';
    rewind.seekTo = async (target: string) => {
      sought = target;
      return true;
    };

    const fixture = TestBed.createComponent(RewindBranchSidebarComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('EXECUTION BRANCHES');
    expect(el.textContent).toContain('--history');

    rewind.historySupported.set(true);
    rewind.branches.set([
      {
        id: 0,
        parent: 0,
        forkR: 0n,
        recordedEndR: 12n,
        childCount: 1,
        reason: ForkReason.Base,
        flags: 4,
        isLive: false,
        isKept: true,
        isPinned: true,
      },
      {
        id: 1,
        parent: 0,
        forkR: 8n,
        recordedEndR: 20n,
        childCount: 0,
        reason: ForkReason.Writes,
        flags: 1,
        isLive: true,
        isKept: false,
        isPinned: false,
      },
    ]);
    rewind.frameStatus.set({
      ramBytes: 65536n,
      diskBytes: 2_097_152n,
      queueBytes: 0n,
      frames: 14n,
      decodedSegments: 3n,
    });
    fixture.componentRef.setInput('bookmarks', [
      { name: 'boot_ok', place: '0x02000010', branch: 0, r: 4n, virtualNs: 100n },
    ]);
    fixture.detectChanges();

    expect(el.querySelector('[data-testid="rewind-branch-count"]')?.textContent).toContain('2 ACTIVE');
    expect(el.querySelector('[data-testid="rewind-switch-0"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="rewind-delete-1"]')?.textContent?.trim()).toBe('Prune');
    expect(el.querySelector('[data-testid="rewind-frame-status"]')?.textContent).toContain('14 hot');
    expect(el.querySelector('[data-testid="rewind-frame-status"]')?.textContent).toContain('2.0 MiB');

    (el.querySelector('[data-testid="rewind-bm-boot_ok"]') as HTMLButtonElement).click();
    expect(sought).toBe('bm boot_ok');
  });
});
