import { TestBed } from '@angular/core/testing';
import { Core, HistoryGap, HistoryPhase, LineOrder } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindDiffPaneComponent } from '../../../src/app/features/rewind/rewind-diff-pane.component';

describe('RewindDiffPaneComponent', () => {
  it('renders 3-column STATE DIFF rows and dispatches compareDiff', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const rewind = TestBed.inject(RewindStore);
    rpc.connectionState.set('connected');

    rewind.activeDiff.set({
      frames: 1,
      a: { branch: 0, r: 0n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      b: { branch: 0, r: 8n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      order: LineOrder.Lt,
      regs: [{ core: Core.Cpu0, name: 'pc', valA: 0x0200_0008, valB: 0x0200_0020 }],
      pages: [],
      periphs: [],
    });

    let compared = '';
    rewind.compareDiff = async (a: string, b: string) => {
      compared = `${a}->${b}`;
      return rewind.activeDiff();
    };

    const fixture = TestBed.createComponent(RewindDiffPaneComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('STATE DIFF');
    expect(el.textContent).toContain('0x02000008');
    expect(el.textContent).toContain('0x02000020');

    (el.querySelector('[data-testid="rewind-diff-btn"]') as HTMLButtonElement).closest('form')!.dispatchEvent(new Event('submit'));
    expect(compared).toBe('0->latest');
  });
});
