import { TestBed } from '@angular/core/testing';
import { Core, type RA8RpcClient, Topic, findBoardPreset } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import { HardwarePanelIoComponent } from '../../../src/app/features/hardware/hardware-panel-io.component';

describe('HardwarePanelIoComponent', () => {
  it('captures dirty frames, adapts 0x010D subscribe rates, sends OV5640 webcam consent, and renders headless card', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);

    const subscribeCalls: Array<{ topic: number; rate: number }> = [];
    const cameraCalls: Array<{ spec: string; allowWebcam: boolean }> = [];
    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', {
      configurable: true,
      get: () =>
        ({
          subscribe: async (_core: Core, topic: Topic, rate: number) => {
            subscribeCalls.push({ topic, rate });
            return true;
          },
          getRtc: async () => ({
            running: true,
            valid: true,
            year: 2026,
            month: 11,
            day: 18,
            hour: 12,
            minute: 0,
            second: 0,
          }),
          setCameraSource: async (spec: string, allowWebcam: boolean) => {
            cameraCalls.push({ spec, allowWebcam });
            return true;
          },
        }) as unknown as RA8RpcClient,
    });

    const panelPreset = findBoardPreset('ra8d2')!;
    board.selectedPreset.set(panelPreset);
    board.boardProfile.set(panelPreset.profile);

    const fixture = TestBed.createComponent(HardwarePanelIoComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    rpc.lcdDirty$.next({ core: Core.Cpu0, virtualNs: 1000n, x: 0, y: 0, width: 2, height: 2, pixels: new Uint8Array(16).fill(255) });
    fixture.detectChanges();
    expect(el.textContent).toContain('#1/1');
    expect(el.textContent).toContain('Captured: 1');

    const rateSelect = el.querySelector('[data-testid="hardware-lcd-rate"]') as HTMLSelectElement;
    rateSelect.value = 'slow_0_1x';
    rateSelect.dispatchEvent(new Event('change'));
    await Promise.resolve();
    expect(subscribeCalls).toContainEqual({ topic: Topic.LcdDirty, rate: 0 });

    rateSelect.value = 'rate_100x';
    rateSelect.dispatchEvent(new Event('change'));
    await Promise.resolve();
    expect(subscribeCalls).toContainEqual({ topic: Topic.LcdDirty, rate: 15 });

    const camKind = el.querySelector('[data-testid="hardware-camera-select"]') as HTMLSelectElement;
    camKind.value = 'webcam';
    camKind.dispatchEvent(new Event('change'));
    const camPath = el.querySelector('[data-testid="hardware-camera-path"]') as HTMLInputElement;
    camPath.value = '0';
    camPath.dispatchEvent(new Event('input'));
    const camConsent = el.querySelector('[data-testid="hardware-camera-webcam"]') as HTMLInputElement;
    camConsent.click();
    camPath.closest('form')!.dispatchEvent(new Event('submit'));
    await Promise.resolve();
    expect(cameraCalls).toEqual([{ spec: 'webcam:0', allowWebcam: true }]);

    const headless = findBoardPreset('fpb-ra8e1')!;
    board.selectedPreset.set(headless);
    board.boardProfile.set(headless.profile);
    fixture.detectChanges();
    expect(el.textContent).toContain('Headless target profile');
  });

  it('preserves hardware virtualNs timestamps on scrubber snapshots and syncs speedMilli changes', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const execution = TestBed.inject(ExecutionStore);

    const subscribeRates: number[] = [];
    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', {
      configurable: true,
      get: () =>
        ({
          subscribe: async (_core: Core, topic: Topic, rate: number) => {
            if (topic === Topic.LcdDirty) subscribeRates.push(rate);
            return true;
          },
          getRtc: async () => ({
            running: false,
            valid: false,
            year: 0,
            month: 0,
            day: 0,
            hour: 0,
            minute: 0,
            second: 0,
          }),
          setSpeed: async () => true,
        }) as unknown as RA8RpcClient,
    });

    const panelPreset = findBoardPreset('ra8d2')!;
    board.selectedPreset.set(panelPreset);
    board.boardProfile.set(panelPreset.profile);
    execution.virtualTimeNs.set(0n);

    const fixture = TestBed.createComponent(HardwarePanelIoComponent);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    const rateSelect = el.querySelector('[data-testid="hardware-lcd-rate"]') as HTMLSelectElement;
    rateSelect.value = 'slow_0_1x';
    rateSelect.dispatchEvent(new Event('change'));
    await Promise.resolve();

    rpc.lcdDirty$.next({ core: Core.Cpu0, virtualNs: 12_345_000n, x: 0, y: 0, width: 2, height: 2, pixels: new Uint8Array(4).fill(64) });
    rpc.lcdDirty$.next({ core: Core.Cpu0, virtualNs: 29_012_000n, x: 0, y: 0, width: 2, height: 2, pixels: new Uint8Array(4).fill(200) });
    fixture.detectChanges();
    expect(el.textContent).toContain('#2/2 · 29.01ms');

    const scrubber = el.querySelector('[data-testid="hardware-frame-scrubber"]') as HTMLInputElement;
    scrubber.value = '0';
    scrubber.dispatchEvent(new Event('input'));
    fixture.detectChanges();
    expect(el.textContent).toContain('#1/2 · 12.34ms');

    for (const milli of [100, 100_000, 0, 1000]) {
      execution.speedMilli.set(milli);
      fixture.detectChanges();
      await Promise.resolve();
    }
    expect(rateSelect.value).toBe('rate_1x');
    expect(subscribeRates.slice(-4)).toEqual([0, 15, 5, 60]);
  });
});
