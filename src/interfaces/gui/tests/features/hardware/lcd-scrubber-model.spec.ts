import { Core } from 'ra8-rpc-client';
import {
  MAX_LCD_SCRUB_FRAMES,
  computeLcdSubscribeRateHz,
  createLcdScrubberState,
  pushDirtyRectFrame,
} from '../../../src/app/features/hardware/lcd-scrubber-model';

describe('lcd-scrubber-model', () => {
  it('captures up to 120 dirty rect snapshots and maps adaptive subscribe rates', () => {
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

    expect(computeLcdSubscribeRateHz('unthrottled')).toBe(0);
    expect(computeLcdSubscribeRateHz('hz60')).toBe(60);
    expect(computeLcdSubscribeRateHz('hz15')).toBe(15);
    expect(computeLcdSubscribeRateHz('scrubbing')).toBeNull();
  });
});
