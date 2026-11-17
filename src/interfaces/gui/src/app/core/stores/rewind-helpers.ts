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
