import { Core } from 'ra8-rpc-client';
import {
  MAX_LCD_SCRUB_FRAMES,
  computeAdaptiveLcdPolicy,
  computeLcdSubscribeRateHz,
  createLcdScrubberState,
  pushDirtyRectAdaptive,
  pushDirtyRectFrame,
  selectAdaptiveModeForSpeed,
} from '../../../src/app/features/hardware/lcd-scrubber-model';

describe('lcd-scrubber-model', () => {
  it('captures up to 120 dirty rect snapshots in ring buffer and maps legacy subscribe rates', () => {
    let state = createLcdScrubberState(4, 4);
    const pixels = new Uint8Array(4 * 4 * 4).fill(200);
    for (let i = 0; i < MAX_LCD_SCRUB_FRAMES + 5; i++) {
      state = pushDirtyRectFrame(
        state,
        { core: Core.Cpu0, virtualNs: BigInt(i * 1000), x: 0, y: 0, width: 2, height: 2, pixels: pixels.slice(0, 16) },
        BigInt(i * 1000)
      );
    }

    expect(state.frames.length).toBe(MAX_LCD_SCRUB_FRAMES);
    expect(state.frames[0]?.seq).toBe(6);
    expect(state.frames[0]?.rgba[0]).toBe(200);
    expect(state.capturedCount).toBe(MAX_LCD_SCRUB_FRAMES + 5);
    expect(state.skippedCount).toBe(0);

    expect(computeLcdSubscribeRateHz('unthrottled')).toBe(0);
    expect(computeLcdSubscribeRateHz('hz60')).toBe(60);
    expect(computeLcdSubscribeRateHz('hz15')).toBe(15);
    expect(computeLcdSubscribeRateHz('scrubbing')).toBeNull();
  });

  it('adapts 0x010D subscribe rates and tracks captured vs skipped frames across pacing modes', () => {
    const slowPolicy = computeAdaptiveLcdPolicy('slow_0_1x');
    const oneXPolicy = computeAdaptiveLcdPolicy('rate_1x');
    const hundredXPolicy = computeAdaptiveLcdPolicy('rate_100x');
    const maxPolicy = computeAdaptiveLcdPolicy('rate_max');

    expect(slowPolicy.subscribeRateHz).toBe(0);
    expect(slowPolicy.captureEveryFrame).toBe(true);
    expect(oneXPolicy.subscribeRateHz).toBe(60);
    expect(hundredXPolicy.subscribeRateHz).toBe(15);
    expect(maxPolicy.subscribeRateHz).toBe(5);

    expect(selectAdaptiveModeForSpeed(100)).toBe('slow_0_1x');
    expect(selectAdaptiveModeForSpeed(1000)).toBe('rate_1x');
    expect(selectAdaptiveModeForSpeed(100_000)).toBe('rate_100x');
    expect(selectAdaptiveModeForSpeed(0)).toBe('rate_max');

    const pixels = new Uint8Array(16).fill(180);
    const rect = { core: Core.Cpu0, virtualNs: 10n, x: 0, y: 0, width: 2, height: 2, pixels };

    let slowState = createLcdScrubberState(4, 4);
    for (let i = 0; i < 4; i++) {
      slowState = pushDirtyRectAdaptive(slowState, rect, BigInt(i * 10), slowPolicy, 1000 + i);
    }
    expect(slowState.capturedCount).toBe(4);
    expect(slowState.skippedCount).toBe(0);
    expect(slowState.frames.length).toBe(4);

    let maxState = createLcdScrubberState(4, 4);
    maxState = pushDirtyRectAdaptive(maxState, rect, 10n, maxPolicy, 1000);
    maxState = pushDirtyRectAdaptive(maxState, rect, 20n, maxPolicy, 1050);
    maxState = pushDirtyRectAdaptive(maxState, rect, 30n, maxPolicy, 1100);
    maxState = pushDirtyRectAdaptive(maxState, rect, 40n, maxPolicy, 1250);
    expect(maxState.capturedCount).toBe(2);
    expect(maxState.skippedCount).toBe(2);
    expect(maxState.frames.length).toBe(2);
  });
});
