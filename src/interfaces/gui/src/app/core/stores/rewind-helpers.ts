import { type DecodedDiff, ErrorCode } from 'ra8-rpc-client';
import { formatHex32 } from '../../shared/utils/hex';

export interface DiffStateRow {
  entity: string;
  beforeVal: string;
  afterVal: string;
  delta: string;
  scope: string;
}

export function formatSeekPoint(
  branch: number,
  r: bigint | number,
  phase = 'cpu0',
  offset = 0,
  gap = 'retired'
): string {
  return `${branch}:${r.toString()}:${phase}:${offset}:${gap}`;
}

export function isPendingForkError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  const code = String(ErrorCode.AppRefused);
  const hex = `0x${ErrorCode.AppRefused.toString(16)}`;
  return msg.includes(code) || msg.toLowerCase().includes(hex);
}

export function mapDiffRows(diff: DecodedDiff): DiffStateRow[] {
  const rows: DiffStateRow[] = [];
  for (const reg of diff.regs) {
    rows.push({
      entity: reg.name,
      beforeVal: formatHex32(reg.valA),
      afterVal: formatHex32(reg.valB),
      delta: `^0x${((reg.valA ^ reg.valB) >>> 0).toString(16)}`,
      scope: `CPU${reg.core}`,
    });
  }
  for (const page of diff.pages) {
    rows.push({
      entity: `Page ${formatHex32(page.address)}`,
      beforeVal: page.hasA ? `${page.objA.length}B` : 'absent',
      afterVal: page.hasB ? `${page.objB.length}B` : 'absent',
      delta: `space ${page.space} #${page.pageIndex}`,
      scope: 'Memory',
    });
  }
  for (const periph of diff.periphs) {
    rows.push({
      entity: `${periph.unit}+0x${periph.offset.toString(16)}`,
      beforeVal: formatHex32(periph.oldVal),
      afterVal: formatHex32(periph.newVal),
      delta: `mask 0x${(periph.changedBytes >>> 0).toString(16)}`,
      scope: 'Peripheral',
    });
  }
  return rows;
}

const SINGLE_WORDS = new Set(['prev', 'next', 'start', 'end']);
const TIME_RE = /^\d+(ns|us|ms|s)$/i;
const POINT_TUPLE_RE = /^\d+:\d+:(cpu0|cpu1):\d+:(retired|irq)$/i;
const SPACE_KW_RE = /^(frame|iter|bm)\s+\S+$/i;
const DIR_KW_RE = /^(isr|rtos)\s+(prev|next)$/i;
const MARKER_RE = /^marker\s+\S+\s+\d+$/i;

/** Normalizes user seek input to match `src/session/history/seek_target.zig`. */
export function normalizeSeekTarget(raw: string): string | null {
  const clean = raw.trim().replace(/^@/, '');
  if (!clean) return null;
  if (SINGLE_WORDS.has(clean.toLowerCase())) return clean.toLowerCase();
  if (TIME_RE.test(clean) || POINT_TUPLE_RE.test(clean)) return clean.toLowerCase();
  if (SPACE_KW_RE.test(clean) || DIR_KW_RE.test(clean) || MARKER_RE.test(clean)) return clean;
  const colonMatch = /^(frame|iter|bm):(\S+)$/i.exec(clean);
  if (colonMatch?.[1] && colonMatch[2]) return `${colonMatch[1].toLowerCase()} ${colonMatch[2]}`;
  if (/^\d+$/.test(clean)) return `iter ${clean}`;
  return null;
}
