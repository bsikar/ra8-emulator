import {
  COMMON_REGISTERS,
  type DisasmRow,
  type ElfSymbol,
  FPU_MVE_REGISTERS,
  type Register,
  type RegisterEntry,
  SYS_REGISTERS,
  type SourceLineResult,
} from 'ra8-rpc-client';
import { type BoardPreset } from 'ra8-rpc-client';
import { type SyntaxToken, decompileThumbRows, tokenizeCodeLine } from '../../shared/utils/decompiler';
import { type EvaluatedLocal } from '../../shared/utils/dwarf-eval';
import { formatHex32, formatHexByte, parseHexAddress } from '../../shared/utils/hex';

export type DebugCodeMode = 'source' | 'disasm' | 'mixed' | 'decomp';
export type RegisterGroupTab = 'gpr' | 'mve' | 'sys';
export type InspectorTab = 'registers' | 'memory' | 'peripherals';

export interface DebugBufferLine {
  key: string;
  kind: 'source' | 'disasm' | 'header' | 'decomp';
  lineNumber: number;
  address: number | null;
  symbol: string;
  rawHex: string;
  text: string;
  tokens: SyntaxToken[];
  isActive: boolean;
  hasBreakpoint: boolean;
}

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

function formatRawBytes(raw: Uint8Array | undefined): string {
  if (!raw || raw.length === 0) return '';
  return Array.from(raw.slice(0, 4))
    .map((b) => formatHexByte(b))
    .join(' ');
}

function buildDisasmLines(
  rows: readonly DisasmRow[],
  pc: number,
  breakpoints: ReadonlyMap<number, number>,
  interleaveHeaders: boolean
): DebugBufferLine[] {
  const lines: DebugBufferLine[] = [];
  let lastSym = '';
  let lineNo = 1;
  for (const row of rows) {
    const addr = row.address >>> 0;
    const sym = row.symbol.trim();
    if (interleaveHeaders && sym && sym !== lastSym) {
      lastSym = sym;
      const hdr = `${sym}:`;
      lines.push({
        key: `hdr_${addr}_${lineNo}`,
        kind: 'header',
        lineNumber: lineNo++,
        address: addr,
        symbol: sym,
        rawHex: '',
        text: hdr,
        tokens: tokenizeCodeLine(hdr),
        isActive: false,
        hasBreakpoint: false,
      });
    }
    lines.push({
      key: `asm_${addr}_${lineNo}`,
      kind: 'disasm',
      lineNumber: lineNo++,
      address: addr,
      symbol: sym,
      rawHex: formatRawBytes(row.raw),
      text: row.text,
      tokens: tokenizeCodeLine(row.text),
      isActive: addr === (pc >>> 0),
      hasBreakpoint: breakpoints.has((addr & ~1) >>> 0),
    });
  }
  return lines;
}

function buildSourceLines(
  sourceLines: readonly string[],
  sourceLine: SourceLineResult | null,
  breakpoints: ReadonlyMap<number, number>
): DebugBufferLine[] {
  const activeLine = sourceLine?.found ? sourceLine.line : -1;
  const activePc = sourceLine?.found ? sourceLine.pc >>> 0 : null;
  return sourceLines.map((text, idx) => {
    const lineNumber = idx + 1;
    const isActive = lineNumber === activeLine;
    const bpSet = isActive && activePc !== null ? breakpoints.has((activePc & ~1) >>> 0) : false;
    return {
      key: `src_${lineNumber}`,
      kind: 'source',
      lineNumber,
      address: isActive ? activePc : null,
      symbol: '',
      rawHex: '',
      text,
      tokens: tokenizeCodeLine(text),
      isActive,
      hasBreakpoint: bpSet,
    };
  });
}

function buildMixedLines(opts: {
  disasmRows: readonly DisasmRow[];
  sourceLines: readonly string[];
  sourceLine: SourceLineResult | null;
  pc: number;
  breakpoints: ReadonlyMap<number, number>;
}): DebugBufferLine[] {
  const { sourceLines, sourceLine, disasmRows, pc, breakpoints } = opts;
  if (!sourceLine?.found || sourceLines.length === 0) {
    return buildDisasmLines(disasmRows, pc, breakpoints, true);
  }
  const out: DebugBufferLine[] = [];
  const start = Math.max(0, sourceLine.line - 3);
  const end = Math.min(sourceLines.length, sourceLine.line + 2);
  let insertedAsm = false;
  for (let i = start; i < end; i++) {
    const ln = i + 1;
    const text = sourceLines[i] ?? '';
    out.push({
      key: `mix_src_${ln}`,
      kind: 'header',
      lineNumber: ln,
      address: ln === sourceLine.line ? sourceLine.pc >>> 0 : null,
      symbol: '',
      rawHex: '',
      text: `${ln}: ${text}`,
      tokens: tokenizeCodeLine(text),
      isActive: ln === sourceLine.line,
      hasBreakpoint: false,
    });
    if (ln === sourceLine.line && !insertedAsm) {
      insertedAsm = true;
      out.push(...buildDisasmLines(disasmRows, pc, breakpoints, false));
    }
  }
  if (!insertedAsm) out.push(...buildDisasmLines(disasmRows, pc, breakpoints, false));
  return out;
}

export function buildCodeBufferLines(opts: {
  mode: DebugCodeMode;
  disasmRows: readonly DisasmRow[];
  sourceLines: readonly string[];
  sourceLine: SourceLineResult | null;
  pc: number;
  breakpoints: ReadonlyMap<number, number>;
  fnName?: string;
}): DebugBufferLine[] {
  if (opts.mode === 'source') {
    return buildSourceLines(opts.sourceLines, opts.sourceLine, opts.breakpoints);
  }
  if (opts.mode === 'disasm') {
    return buildDisasmLines(opts.disasmRows, opts.pc, opts.breakpoints, false);
  }
  if (opts.mode === 'mixed') {
    return buildMixedLines(opts);
  }
  const lifted = decompileThumbRows(opts.disasmRows, opts.pc, opts.fnName);
  return lifted.lines.map((line) => ({
    key: `dec_${line.lineNumber}_${line.address}`,
    kind: 'decomp',
    lineNumber: line.lineNumber,
    address: line.address >>> 0,
    symbol: '',
    rawHex: '',
    text: line.code,
    tokens: line.tokens,
    isActive: lifted.activeLineNumber === line.lineNumber,
    hasBreakpoint: opts.breakpoints.has((line.address & ~1) >>> 0),
  }));
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
