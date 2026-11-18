import { TestBed } from '@angular/core/testing';
import { ForkReason } from 'ra8-rpc-client';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindDagCanvasComponent } from '../../../src/app/features/rewind/rewind-dag-canvas.component';

describe('RewindDagCanvasComponent', () => {
  it('switches Spine vs Waterfall modes and seeks when clicking a node chip', async () => {
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
        flags: 0,
        isLive: true,
        isKept: false,
        isPinned: false,
      },
    ]);

    let seekCall: string | null = null;
    rewind.seekPoint = async (branch: number, r: bigint | number) => {
      seekCall = `${branch}:${r.toString()}`;
      return true;
    };

    const fixture = TestBed.createComponent(RewindDagCanvasComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    (el.querySelector('[data-testid="rewind-layout-waterfall"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-layout-waterfall"]')?.classList.contains('is-active')).toBe(true);

    (el.querySelector('[data-testid="rewind-node-0"]') as HTMLButtonElement).click();
    expect(seekCall).toBe('0:0');
  });
});
