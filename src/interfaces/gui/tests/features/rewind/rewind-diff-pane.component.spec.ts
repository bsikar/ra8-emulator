import { TestBed } from '@angular/core/testing';
import { Core, HistoryGap, HistoryPhase, LineOrder } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindDiffPaneComponent } from '../../../src/app/features/rewind/rewind-diff-pane.component';

describe('RewindDiffPaneComponent', () => {
  it('renders 3-column STATE DIFF, filters by category tab, and swaps Point A and Point B', async () => {
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
      pages: [
        {
          space: 0,
          pageIndex: 4,
          address: 0x2000_4000,
          hasA: true,
          objA: new Uint8Array(16).fill(0x11),
          hasB: true,
          objB: new Uint8Array(16).fill(0x22),
        },
      ],
      periphs: [{ unit: 'SCI8', offset: 4, oldVal: 0x00, newVal: 0x0a, changedBytes: 1 }],
    });

    const compared: string[] = [];
    rewind.compareDiff = async (a: string, b: string) => {
      compared.push(`${a}->${b}`);
      return rewind.activeDiff();
    };

    const fixture = TestBed.createComponent(RewindDiffPaneComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    expect(el.textContent).toContain('STATE DIFF');
    expect(el.querySelector('[data-testid="rewind-diff-col-regs"]')?.textContent).toContain('0x02000008');
    expect(el.querySelector('[data-testid="rewind-diff-col-pages"]')?.textContent).toContain('0x20004000');
    expect(el.querySelector('[data-testid="rewind-diff-col-periphs"]')?.textContent).toContain('SCI8+0x04');

    (el.querySelector('[data-testid="rewind-diff-tab-pages"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-diff-col-regs"]')).toBeNull();
    expect(el.querySelector('[data-testid="rewind-diff-col-pages"]')).not.toBeNull();

    (el.querySelector('[data-testid="rewind-diff-tab-all"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-diff-col-regs"]')).not.toBeNull();

    (el.querySelector('[data-testid="rewind-diff-btn"]') as HTMLButtonElement).closest('form')!.dispatchEvent(new Event('submit'));
    expect(compared).toContain('0->latest');

    (el.querySelector('[data-testid="rewind-diff-swap-btn"]') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(compared).toContain('latest->0');
  });
});
