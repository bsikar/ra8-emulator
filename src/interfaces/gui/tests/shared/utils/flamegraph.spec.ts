import { getTopHotspots, parseFoldedStacks, toIcicleRows } from '../../../src/app/shared/utils/flamegraph';

describe('flamegraph', () => {
  const folded = [
    'Reset_Handler;main;tx_kernel_enter;vision_infer 390',
    'Reset_Handler;main;tx_kernel_enter;ethos_u55_wait 290',
    'Reset_Handler;main;tx_kernel_enter;imu_mve_norm 170',
    'Reset_Handler;main;drw_blend 44',
  ].join('\n');

  it('builds normalized monochromatic Editorial Slate flamegraph with parent >= children sum', () => {
    const view = parseFoldedStacks(folded);
    expect(view.totalSamples).toBe(894);
    expect(view.hotspot?.name).toBe('vision_infer');

    const allowed = new Set(['#1C2028', '#1E232C', '#222630', '#262B35', '#2A2F3A']);
    for (const node of view.nodes) {
      expect(allowed.has(node.color)).toBe(true);
    }

    const icicle = toIcicleRows(view);
    expect(icicle[0]?.[0]?.depth).toBe(view.maxDepth);
    expect(icicle[icicle.length - 1]?.[0]?.id).toBe('fg_root');

    const hotspots = getTopHotspots(view, 2);
    expect(hotspots.map((h) => h.name)).toEqual(['vision_infer', 'ethos_u55_wait']);
  });
});
