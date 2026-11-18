import { TestBed } from '@angular/core/testing';
import { CAP_ARTIFACTS, Core, Direction } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { RewindStore } from '../../../src/app/core/stores/rewind.store';
import { RewindTransportBarComponent } from '../../../src/app/features/rewind/rewind-transport-bar.component';

function configureTransportStubs() {
  TestBed.configureTestingModule({});
  const rpc = TestBed.inject(RpcConnectionStore);
  const execution = TestBed.inject(ExecutionStore);
  const rewind = TestBed.inject(RewindStore);
  rpc.connectionState.set('connected');
  rpc.observeOnly.set(false);
  rpc.serverCaps.set(CAP_ARTIFACTS);
  rewind.historySupported.set(true);

  const calls: string[] = [];
  Object.defineProperty(rpc, 'activeClient', {
    get: () => ({
      pause: async () => { calls.push('clientPause'); return true; },
      advance: async (_core: Core, ns: bigint) => { calls.push(`advance:${ns.toString()}`); return true; },
    }),
    configurable: true,
  });
  execution.reverseContinue = async () => { calls.push('rcont'); };
  execution.pause = async () => { calls.push('pause'); };
  execution.step = async () => { calls.push('step'); };
  execution.refreshClock = async () => { calls.push('clock'); };
  rewind.refreshBranches = async () => { calls.push('refresh'); };
  rewind.play = async (dir) => { calls.push(`play:${dir === Direction.Back ? 'back' : 'fwd'}`); return true; };
  rewind.seekTo = async (target: string) => { calls.push(`seek:${target}`); return true; };
  rewind.setMarker = async (name: string, place: string) => {
    calls.push(`marker:${name}@${place}`);
    return { found: true, branch: 0, r: 8n, phase: 0, o: 0, gap: 0, count: 2n, slots: 0n, virtualNs: 4000n };
  };
  rewind.confirmFork = async () => { calls.push('confirmFork'); rewind.pendingForkPrompt.set(false); return true; };
  return { rewind, calls };
}

describe('RewindTransportBarComponent', () => {
  it('invokes stepBack, pause, stepForward, advance, play, ISR/RTOS seek, and shows --history notice when off', async () => {
    const { rewind, calls } = configureTransportStubs();
    rewind.historySupported.set(false);
    const fixture = TestBed.createComponent(RewindTransportBarComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    expect(el.querySelector('[data-testid="rewind-no-history-banner"]')).not.toBeNull();
    rewind.historySupported.set(true);
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-no-history-banner"]')).toBeNull();

    (el.querySelector('[data-testid="rewind-step-back-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-pause-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-step-fwd-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-advance-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-play-back-btn"]') as HTMLButtonElement).click();
    (el.querySelector('[data-testid="rewind-rtos-next-btn"]') as HTMLButtonElement).click();
    await Promise.resolve();

    expect(calls).toEqual(
      expect.arrayContaining(['rcont', 'clientPause', 'pause', 'step', 'advance:8000000', 'play:back', 'seek:rtos next'])
    );
  });

  it('normalizes seek targets, opens bookmark drawer for setMarker, and confirms fork', async () => {
    const { rewind, calls } = configureTransportStubs();
    const fixture = TestBed.createComponent(RewindTransportBarComponent);
    const created: string[] = [];
    fixture.componentInstance.bookmarkCreated.subscribe((bm) => created.push(bm.name));
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    const input = el.querySelector('[data-testid="rewind-seek-input"]') as HTMLInputElement;
    input.value = '@250us';
    input.dispatchEvent(new Event('input'));
    input.closest('form')!.dispatchEvent(new Event('submit'));
    expect(calls).toContain('seek:250us');

    (el.querySelector('[data-testid="rewind-bookmark-toggle"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const bmName = el.querySelector('[data-testid="rewind-marker-name"]') as HTMLInputElement;
    const bmPlace = el.querySelector('[data-testid="rewind-marker-place"]') as HTMLInputElement;
    bmName.value = 'loop_entry';
    bmName.dispatchEvent(new Event('input'));
    bmPlace.value = '0x02000010';
    bmPlace.dispatchEvent(new Event('input'));
    bmName.closest('form')!.dispatchEvent(new Event('submit'));
    await Promise.resolve();
    expect(calls).toContain('marker:loop_entry@0x02000010');
    expect(created).toEqual(['loop_entry']);

    rewind.pendingForkPrompt.set(true);
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="rewind-fork-banner"]')).not.toBeNull();
    (el.querySelector('[data-testid="rewind-confirm-fork"]') as HTMLButtonElement).click();
    expect(calls).toContain('confirmFork');
  });
});
