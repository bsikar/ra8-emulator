import { Core } from 'ra8-rpc-client';
import {
  aggregateHotspots,
  mergeFoldedTexts,
  nodeMatchesFilter,
  resolveSymbolAddress,
  sortHotspots,
} from '../../../src/app/features/profile/profile-hotspots';
import { parseFoldedStacks } from '../../../src/app/shared/utils/flamegraph';

describe('profile-hotspots', () => {
  it('aggregates self/total percentages across paths without double counting recursion and resolves ELF symbols', () => {
    const view = parseFoldedStacks(
      [
        'Reset_Handler;outer;heavy 60',
        'Reset_Handler;outer;light 20',
        'Reset_Handler;outer;outer;heavy 20',
      ].join('\n')
    );

    const symbols = [
      { name: 'heavy', address: 0x0200_0400, size: 64, kind: 'func' as const },
      { name: 'light', address: 0x0200_0500, size: 32, kind: 'func' as const },
    ];

    const rows = aggregateHotspots(view, symbols, Core.Cpu0);
    expect(rows.length).toBe(2);
    const sortedSelf = sortHotspots(rows, 'selfPct', 'desc');
    expect(sortedSelf[0]?.symbol).toBe('heavy');
    expect(sortedSelf[0]?.selfSamples).toBe(80);
    expect(sortedSelf[0]?.selfPct).toBe(80);
    expect(sortedSelf[0]?.sourceLocation).toBe('0x02000400');

    const sortedAlpha = sortHotspots(rows, 'symbol', 'asc');
    expect(sortedAlpha.map((r) => r.symbol)).toEqual(['heavy', 'light']);
    expect(resolveSymbolAddress('heavy', symbols)).toBe(0x0200_0400);
    expect(nodeMatchesFilter('heavy', 'hea')).toBe(true);
    expect(nodeMatchesFilter('heavy', 'light')).toBe(false);
    expect(aggregateHotspots(view, symbols, Core.Cpu0, 'lig').map((r) => r.symbol)).toEqual(['light']);
  });

  it('merges dual-core folded stacks with core prefix', () => {
    const merged = mergeFoldedTexts('main;work 10', 'main;ipc 5');
    expect(merged).toBe('CPU0;main;work 10\nCPU1;main;ipc 5');
  });
});
