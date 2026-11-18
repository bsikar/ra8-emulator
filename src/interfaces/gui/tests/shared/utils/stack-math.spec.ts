import { Core, type StackReport } from 'ra8-rpc-client';
import {
  computePspWatermark,
  computeStackMetrics,
  formatStackSummary,
  NEVER_LOW_SP,
} from '../../../src/app/shared/utils/stack-math';

function makeReport(overrides: Partial<StackReport> = {}): StackReport {
  return {
    core: Core.Cpu0,
    msp: 0x220f_ff00,
    psp: 0,
    lowMsp: NEVER_LOW_SP,
    lowPsp: NEVER_LOW_SP,
    hasStack: true,
    base: 0x220f_df00,
    size: 0x2000,
    overflow: 0,
    ...overrides,
  };
}

describe('stack-math', () => {
  it('computes stack usage downward from (base + size) rather than base - sp', () => {
    const metrics = computeStackMetrics(makeReport({ lowMsp: 0x220f_f700 }));
    expect(metrics.hasReservation).toBe(true);
    expect(metrics.touched).toBe(true);
    expect(metrics.top).toBe(0x220f_ff00);
    expect(metrics.usedBytes).toBe(0x0800);
    expect(metrics.overflowBytes).toBe(0);
    expect(metrics.percentUsed).toBe(25);
    expect(formatStackSummary(makeReport({ lowMsp: 0x220f_f700 }))).toBe('25% (2048/8192B)');
  });

  it('treats NEVER_LOW_SP (0xFFFFFFFF) as untouched instead of overflow', () => {
    const metrics = computeStackMetrics(makeReport({ msp: 0, lowMsp: NEVER_LOW_SP }));
    expect(metrics.touched).toBe(false);
    expect(metrics.usedBytes).toBe(0);
    expect(metrics.overflowBytes).toBe(0);
    expect(formatStackSummary(makeReport({ msp: 0, lowMsp: NEVER_LOW_SP }))).toBe('0% (0/8192B)');
  });

  it('falls back to live msp when lowMsp is NEVER_LOW_SP', () => {
    const metrics = computeStackMetrics(makeReport({ msp: 0x220f_ef00, lowMsp: NEVER_LOW_SP }));
    expect(metrics.touched).toBe(true);
    expect(metrics.usedBytes).toBe(0x1000);
    expect(metrics.percentUsed).toBe(50);
  });

  it('detects overflow below base and reports overflow bytes', () => {
    const report = makeReport({ lowMsp: 0x220f_de00, overflow: 0x100 });
    const metrics = computeStackMetrics(report);
    expect(metrics.usedBytes).toBe(0x2000);
    expect(metrics.overflowBytes).toBe(0x100);
    expect(metrics.percentUsed).toBe(100);
    expect(formatStackSummary(report)).toContain('OVERFLOW +256B');
  });

  it('returns empty metrics when stack reservation is absent', () => {
    const metrics = computeStackMetrics(makeReport({ hasStack: false, base: 0, size: 0 }));
    expect(metrics.hasReservation).toBe(false);
    expect(formatStackSummary(null)).toBe('No stack reservation');
  });

  it('computes PSP watermark headroom and overflow against PSPLIM', () => {
    const untouched = computePspWatermark(makeReport({ psp: 0, lowPsp: NEVER_LOW_SP }), 0x2201_9000);
    expect(untouched.touched).toBe(false);
    expect(untouched.nearLimit).toBe(false);

    const near = computePspWatermark(makeReport({ psp: 0x2201_9400, lowPsp: 0x2201_9180 }), 0x2201_9000);
    expect(near.touched).toBe(true);
    expect(near.headroomBytes).toBe(0x180);
    expect(near.nearLimit).toBe(true);

    const over = computePspWatermark(makeReport({ psp: 0x2201_9100, lowPsp: 0x2201_8fc0 }), 0x2201_9000);
    expect(over.overflowBytes).toBe(0x40);
    expect(over.nearLimit).toBe(true);
    expect(over.summary).toContain('OVERFLOW');
  });
});
