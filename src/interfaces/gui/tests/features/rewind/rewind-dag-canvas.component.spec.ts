import { TestBed } from '@angular/core/testing';
import { Core, ForkReason, HistoryGap, HistoryPhase, LineOrder } from 'ra8-rpc-client';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindDagCanvasComponent } from '../../../src/app/features/rewind/rewind-dag-canvas.component';

describe('RewindDagCanvasComponent', () => {
  it('switches Spine vs Waterfall modes, seeks on click, and emits diff pins in Pin A/Pin B mode', async () => {
    TestBed.configureTestingModule({});
    const rewind = TestBed.inject(RewindStore);
    rewind.branches.set([
      {
        id: 0,
        parent: 0,
        forkR: 0n,
        recordedEndR: 16n,
        childCount: 0,
        reason: ForkReason.Base,
        flags: 1,
        isLive: true,
        isKept: false,
        isPinned: false,
      },
    ]);
    rewind.activeDiff.set({
      frames: 2,
      a: { branch: 0, r: 0n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      b: { branch: 0, r: 16n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      order: LineOrder.Lt,
      regs: [{ core: Core.Cpu0, name: 'pc', valA: 0x0200_0008, valB: 0x0200_0020 }],
      pages: [],
      periphs: [],
    });

    let seekCall: string | null = null;
    rewind.seekPoint = async (branch: number, r: bigint | number) => {
      seekCall = `${branch}:${r.toString()}`;
      return true;
    };

    const fixture = TestBed.createComponent(RewindDagCanvasComponent);
    const emittedPairs: Array<{ pointA: string; pointB: string }> = [];
    fixture.componentInstance.diffPairRequested.subscribe((p) => emittedPairs.push(p));
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    (el.querySelector('[data-testid="rewind-layout-waterfall"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-layout-waterfall"]')?.classList.contains('is-active')).toBe(true);

    (el.querySelector('[data-testid="rewind-node-0"]') as HTMLButtonElement).click();
    expect(seekCall).toBe('0:0');

    (el.querySelector('[data-testid="rewind-click-pin-b"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-node-1"]') as HTMLButtonElement).click();
    expect(emittedPairs.length).toBe(1);
    expect(emittedPairs[0]?.pointA).toBe('0');
    expect(el.querySelector('[data-testid="rewind-dag-summary"]')?.textContent).toContain('+16 rounds');
  });
});
