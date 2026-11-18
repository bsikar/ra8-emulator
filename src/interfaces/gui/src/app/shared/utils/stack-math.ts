import type { StackReport } from 'ra8-rpc-client';

export const NEVER_LOW_SP = 0xffff_ffff;

export interface StackMetrics {
  hasReservation: boolean;
  touched: boolean;
  effectiveSp: number;
  base: number;
  top: number;
  size: number;
  usedBytes: number;
  overflowBytes: number;
  percentUsed: number;
}

export function computeStackMetrics(report: StackReport | null): StackMetrics {
  if (!report || !report.hasStack || report.size <= 0) {
    return {
      hasReservation: false,
      touched: false,
      effectiveSp: 0,
      base: report?.base ?? 0,
      top: 0,
      size: report?.size ?? 0,
      usedBytes: 0,
      overflowBytes: 0,
      percentUsed: 0,
    };
  }

  const base = report.base >>> 0;
  const size = report.size >>> 0;
  const top = (base + size) >>> 0;
  const lowMsp = report.lowMsp >>> 0;
  const msp = report.msp >>> 0;
  const lowTouched = lowMsp !== NEVER_LOW_SP;
  const effectiveSp = lowTouched ? lowMsp : msp;
  const touched = lowTouched || msp !== 0;

  if (!touched) {
    return {
      hasReservation: true,
      touched: false,
      effectiveSp: 0,
      base,
      top,
      size,
      usedBytes: 0,
      overflowBytes: 0,
      percentUsed: 0,
    };
  }

  const rawUsed = top >= effectiveSp ? top - effectiveSp : 0;
  const usedBytes = Math.max(0, Math.min(size, rawUsed));
  const computedOverflow = effectiveSp < base ? base - effectiveSp : 0;
  const overflowBytes = Math.max(report.overflow >>> 0, computedOverflow);
  const percentUsed = Math.min(100, Math.round((usedBytes / size) * 100));

  return {
    hasReservation: true,
    touched: true,
    effectiveSp,
    base,
    top,
    size,
    usedBytes,
    overflowBytes,
    percentUsed,
  };
}

export interface PspWatermark {
  touched: boolean;
  psp: number;
  lowPsp: number;
  effectivePsp: number;
  headroomBytes: number | null;
  overflowBytes: number;
  nearLimit: boolean;
  summary: string;
}

export function computePspWatermark(report: StackReport | null, psplim = 0): PspWatermark {
  if (!report) {
    return {
      touched: false,
      psp: 0,
      lowPsp: NEVER_LOW_SP,
      effectivePsp: 0,
      headroomBytes: null,
      overflowBytes: 0,
      nearLimit: false,
      summary: 'No PSP sample',
    };
  }
  const psp = report.psp >>> 0;
  const lowPsp = report.lowPsp >>> 0;
  const lowTouched = lowPsp !== NEVER_LOW_SP;
  const effectivePsp = lowTouched ? lowPsp : psp;
  const touched = lowTouched || psp !== 0;
  if (!touched) {
    return {
      touched: false,
      psp,
      lowPsp,
      effectivePsp: 0,
      headroomBytes: null,
      overflowBytes: 0,
      nearLimit: false,
      summary: 'PSP untouched',
    };
  }
  const lim = psplim >>> 0;
  if (lim > 0) {
    const overflowBytes = effectivePsp < lim ? lim - effectivePsp : 0;
    const headroomBytes = effectivePsp >= lim ? effectivePsp - lim : 0;
    const nearLimit = overflowBytes > 0 || headroomBytes <= 512;
    const hex = `0x${effectivePsp.toString(16).padStart(8, '0')}`;
    const note = overflowBytes > 0 ? `OVERFLOW +${overflowBytes}B` : `${headroomBytes}B free`;
    return { touched, psp, lowPsp, effectivePsp, headroomBytes, overflowBytes, nearLimit, summary: `${hex} · ${note}` };
  }
  const hex = `0x${effectivePsp.toString(16).padStart(8, '0')}`;
  return {
    touched,
    psp,
    lowPsp,
    effectivePsp,
    headroomBytes: null,
    overflowBytes: 0,
    nearLimit: false,
    summary: lowTouched ? `${hex} (low)` : hex,
  };
}

export function formatStackSummary(report: StackReport | null): string {
  const m = computeStackMetrics(report);
  if (!m.hasReservation) return 'No stack reservation';
  if (!m.touched) return `0% (0/${m.size}B)`;
  const overflowTag = m.overflowBytes > 0 ? ` · OVERFLOW +${m.overflowBytes}B` : '';
  return `${m.percentUsed}% (${m.usedBytes}/${m.size}B${overflowTag})`;
}
