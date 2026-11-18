import { TestBed } from '@angular/core/testing';
import { ForkReason } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindBranchSidebarComponent } from '../../../src/app/features/rewind/rewind-branch-sidebar.component';

describe('RewindBranchSidebarComponent', () => {
  it('renders EXECUTION BRANCHES, branch switch controls, and empty-history hint', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const rewind = TestBed.inject(RewindStore);
    rpc.connectionState.set('connected');

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
        childCount: 0,
        reason: ForkReason.Base,
        flags: 0,
        isLive: false,
        isKept: true,
        isPinned: false,
      },
    ]);
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-switch-0"]')).not.toBeNull();
  });
});
