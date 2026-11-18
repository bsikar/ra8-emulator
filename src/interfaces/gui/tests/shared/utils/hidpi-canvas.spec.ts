import {
  computeAspectLockedRect,
  get2dContext,
  mapClientPointToPanel,
  observeHiDpiCanvas,
  resolveDevicePixelRatio,
  syncHiDpiCanvas,
} from '../../../src/app/shared/utils/hidpi-canvas';

describe('hidpi-canvas utilities', () => {
  it('resolves devicePixelRatio safely and resizes canvas backing store', () => {
    expect(resolveDevicePixelRatio(2)).toBe(2);
    expect(resolveDevicePixelRatio(-1)).toBe(1);
    expect(resolveDevicePixelRatio(8)).toBe(4);

    const canvas = document.createElement('canvas');
    const metrics = syncHiDpiCanvas(canvas, 512, 300, 2);
    expect(metrics.widthPx).toBe(1024);
    expect(metrics.heightPx).toBe(600);
    expect(canvas.width).toBe(1024);
    expect(canvas.height).toBe(600);
  });

  it('computes aspect-locked rectangles and maps client touch coordinates back to panel pixels', () => {
    const box = computeAspectLockedRect(1024, 800, 1024, 600);
    expect(box.width).toBe(1024);
    expect(box.height).toBe(600);
    expect(box.y).toBe(100);

    const center = mapClientPointToPanel(
      512 + 20,
      400 + 30,
      { left: 20, top: 30, width: 1024, height: 800 },
      1024,
      600,
      true
    );
    expect(center.inside).toBe(true);
    expect(center.x).toBe(512);
    expect(center.y).toBe(300);

    const letterbox = mapClientPointToPanel(
      100,
      35,
      { left: 20, top: 30, width: 1024, height: 800 },
      1024,
      600,
      true
    );
    expect(letterbox.inside).toBe(false);
    expect(letterbox.y).toBe(0);
  });

  it('observes canvas resize and cleans up cleanly without ResizeObserver', () => {
    const canvas = document.createElement('canvas');
    expect(get2dContext(canvas)).toBeNull();
    let seenWidth = 0;
    const stop = observeHiDpiCanvas(canvas, (m) => {
      seenWidth = m.widthPx;
    }, 1.5);
    expect(seenWidth).toBeGreaterThan(0);
    stop();
  });
});
