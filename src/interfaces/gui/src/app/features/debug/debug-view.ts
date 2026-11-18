import {
  COMMON_REGISTERS,
  type BoardPreset,
  type ElfSymbol,
  FPU_MVE_REGISTERS,
  type Register,
  type RegisterEntry,
  SYS_REGISTERS,
  type StackFrame,
} from 'ra8-rpc-client';
import { type EvaluatedLocal } from '../../shared/utils/dwarf-eval';
import { formatHex32, formatHexByte, parseHexAddress } from '../../shared/utils/hex';
import {
  type DebugBufferLine,
  type DebugCodeMode,
  buildCodeBufferLines,
} from './debug-code-format';

export type { DebugBufferLine, DebugCodeMode };
export { buildCodeBufferLines };

export type RegisterGroupTab = 'gpr' | 'mve' | 'sys';
export type InspectorTab = 'registers' | 'memory' | 'peripherals';

export interface WatchEvalItem {
  expr: string;
  valueHex: string;
  detail: string;
}

export interface MemoryHexCell {
  offset: number;
  address: number;
  hex: string;
  changed: boolean;
}

export interface MemoryHexRow {
  addrHex: string;
  baseAddr: number;
  cells: MemoryHexCell[];
  ascii: string;
}

export interface RegisterDisplayRow {
  name: string;
  reg: Register;
  label: string;
  value: number;
  hex: string;
  changed: boolean;
  dimmed: boolean;
}

export type CallStackEntry =
  | { kind: 'exception'; key: string; label: string; excTag: string }
  | { kind: 'frame'; key: string; frameIndex: number; frame: StackFrame };

/** Inserts exception-entry separator rows before interrupted stack frames. */
export function buildCallStackEntries(frames: readonly StackFrame[]): CallStackEntry[] {
  const out: CallStackEntry[] = [];
  for (let i = 0; i < frames.length; i++) {
    const frame = frames[i]!;
    if (frame.interrupted !== 0) {
      const prev = i > 0 ? frames[i - 1] : null;
      const irqLabel = prev?.name ? `Exception · ${prev.name}` : 'Exception · Trap Entry';
      out.push({
        kind: 'exception',
        key: `exc_${i}_${frame.pc >>> 0}`,
        label: irqLabel,
        excTag: frame.interrupted > 1 ? `IRQ ${frame.interrupted}` : 'EXC_RETURN',
      });
    }
    out.push({
      kind: 'frame',
      key: `frame_${i}_${frame.pc >>> 0}`,
      frameIndex: i,
      frame,
    });
  }
  return out;
}

export function evaluateWatchExpressions(
  watches: readonly string[],
  locals: readonly EvaluatedLocal[],
  regs: Readonly<Record<string, number>>,
  symbols: readonly ElfSymbol[]
): WatchEvalItem[] {
  return watches.map((expr) => {
    const clean = expr.trim();
    const localMatch = locals.find((l) => l.name === clean);
    if (localMatch) {
      return {
        expr: clean,
        valueHex: localMatch.valueHex,
        detail: `${localMatch.typeName} · ${localMatch.locationLabel}`,
      };
    }
    const regKey = clean.toLowerCase();
    const regVal = regs[regKey];
    if (regVal !== undefined) {
      return { expr: clean, valueHex: formatHex32(regVal), detail: `REG ${regKey.toUpperCase()}` };
    }
    const symMatch = symbols.find((s) => s.name === clean);
    if (symMatch) {
      return {
        expr: clean,
        valueHex: formatHex32(symMatch.address),
        detail: `${symMatch.kind} · ${symMatch.size}B`,
      };
    }
    const hexAddr = parseHexAddress(clean);
    if (hexAddr !== null) {
      return { expr: clean, valueHex: formatHex32(hexAddr), detail: 'Address watch' };
    }
    return { expr: clean, valueHex: '—', detail: 'Out of scope' };
  });
}

export function buildMemoryHexRows(
  baseAddr: number,
  bytes: Uint8Array,
  prevBytes: Uint8Array
): MemoryHexRow[] {
  const rows: MemoryHexRow[] = [];
  for (let rowOff = 0; rowOff < bytes.length; rowOff += 16) {
    const rowBase = (baseAddr + rowOff) >>> 0;
    const cells: MemoryHexCell[] = [];
    let ascii = '';
    const sliceLen = Math.min(16, bytes.length - rowOff);
    for (let i = 0; i < sliceLen; i++) {
      const offset = rowOff + i;
      const b = bytes[offset] ?? 0;
      const changed = prevBytes.length === bytes.length && (prevBytes[offset] ?? b) !== b;
      cells.push({
        offset,
        address: (baseAddr + offset) >>> 0,
        hex: formatHexByte(b),
        changed,
      });
      ascii += b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : '.';
    }
    rows.push({
      addrHex: formatHex32(rowBase),
      baseAddr: rowBase,
      cells,
      ascii,
    });
  }
  return rows;
}

export function filterRegisterEntries(
  tab: RegisterGroupTab,
  regs: Readonly<Record<string, number>>,
  prevRegs: Readonly<Record<string, number>>,
  dimZero: boolean
): RegisterDisplayRow[] {
  const list: readonly RegisterEntry[] =
    tab === 'mve' ? FPU_MVE_REGISTERS : tab === 'sys' ? SYS_REGISTERS : COMMON_REGISTERS;
  return list.map((entry) => {
    const val = (regs[entry.name] ?? 0) >>> 0;
    const prev = prevRegs[entry.name];
    const changed = prev !== undefined && (prev >>> 0) !== val;
    return {
      name: entry.name,
      reg: entry.reg,
      label: entry.name.toUpperCase(),
      value: val,
      hex: formatHex32(val),
      changed,
      dimmed: dimZero && val === 0,
    };
  });
}

export function parseRegisterOrMemoryValue(raw: string): number | null {
  const clean = raw.trim();
  if (!clean) return null;
  if (/^0x[0-9a-fA-F]+$/i.test(clean)) {
    return parseHexAddress(clean);
  }
  if (/^\d+$/.test(clean)) {
    const val = Number.parseInt(clean, 10);
    return Number.isFinite(val) && val >= 0 ? val >>> 0 : null;
  }
  return null;
}

export function boardHasNpu(preset: BoardPreset | null, profileRaw: string): boolean {
  if (preset?.hasNpu) return true;
  return /npu|ethos/i.test(profileRaw);
}
