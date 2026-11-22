import { type DisasmRow, type SourceLineResult } from 'ra8-rpc-client';
import { type SyntaxToken, decompileThumbRows } from '../../shared/utils/decompiler';
import { formatHex32, formatHexByte } from '../../shared/utils/hex';

export type DebugCodeMode = 'source' | 'disasm' | 'mixed' | 'decomp';

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

const C_KEYWORDS = new Set([
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
  'continue', 'return', 'goto', 'volatile', 'const', 'static', 'inline',
  'extern', 'struct', 'union', 'enum', 'typedef', 'sizeof', 'void', 'true',
  'false', 'NULL', '__asm__',
]);

const C_TYPES = new Set([
  'int8_t', 'uint8_t', 'int16_t', 'uint16_t', 'int32_t', 'uint32_t',
  'int64_t', 'uint64_t', 'size_t', 'ssize_t', 'uintptr_t', 'bool', 'int',
  'unsigned', 'signed', 'char', 'short', 'long', 'float', 'double',
]);

function pushCodePartTokens(codePart: string, tokens: SyntaxToken[]): void {
  const pattern = /(\/\*.*?\*\/|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\b0x[0-9a-fA-F]+[UuLl]*\b|\b\d+[UuLl]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b|[^\w\s]+|\s+)/g;
  for (const match of codePart.matchAll(pattern)) {
    const text = match[0];
    if (text.startsWith('/*')) {
      tokens.push({ kind: 'cmt', text });
    } else if (/^(?:0x[0-9a-fA-F]+[UuLl]*|\d+[UuLl]*|".*"|'.*')$/.test(text)) {
      tokens.push({ kind: 'num', text });
    } else if (C_KEYWORDS.has(text)) {
      tokens.push({ kind: 'kw', text });
    } else if (C_TYPES.has(text) || /_t$/.test(text)) {
      tokens.push({ kind: 'type', text });
    } else if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(text)) {
      const nextChar = codePart[match.index + text.length];
      tokens.push({ kind: nextChar === '(' ? 'fn' : 'id', text });
    } else if (/^\s+$/.test(text)) {
      tokens.push({ kind: 'id', text });
    } else {
      tokens.push({ kind: 'punct', text });
    }
  }
}

/** Tokenizes C, pseudo-C, or assembly text using Editorial Slate syntax categories. */
export function tokenizeDebugCodeLine(line: string): SyntaxToken[] {
  const cmtIdx = line.indexOf('//');
  const codePart = cmtIdx >= 0 ? line.slice(0, cmtIdx) : line;
  const cmtPart = cmtIdx >= 0 ? line.slice(cmtIdx) : '';
  const tokens: SyntaxToken[] = [];
  pushCodePartTokens(codePart, tokens);
  if (cmtPart) tokens.push({ kind: 'cmt', text: cmtPart });
  return tokens;
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
        tokens: tokenizeDebugCodeLine(hdr),
        isActive: false,
        hasBreakpoint: false,
      });
    }
    const pseudo = row.pseudo?.trim() ?? '';
    const displayText = pseudo ? `${row.text}  // ${pseudo}` : row.text;
    lines.push({
      key: `asm_${addr}_${lineNo}`,
      kind: 'disasm',
      lineNumber: lineNo++,
      address: addr,
      symbol: sym,
      rawHex: formatRawBytes(row.raw),
      text: displayText,
      tokens: tokenizeDebugCodeLine(displayText),
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
      tokens: tokenizeDebugCodeLine(text),
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
  const start = sourceLines.length <= 160 ? 0 : Math.max(0, sourceLine.line - 30);
  const end = sourceLines.length <= 160 ? sourceLines.length : Math.min(sourceLines.length, sourceLine.line + 30);
  const activePc = sourceLine.pc >>> 0;
  let insertedAsm = false;
  for (let i = start; i < end; i++) {
    const ln = i + 1;
    const text = sourceLines[i] ?? '';
    const isActive = ln === sourceLine.line;
    out.push({
      key: `mix_src_${ln}`,
      kind: 'header',
      lineNumber: ln,
      address: isActive ? activePc : null,
      symbol: '',
      rawHex: '',
      text,
      tokens: tokenizeDebugCodeLine(text),
      isActive,
      hasBreakpoint: isActive && breakpoints.has((activePc & ~1) >>> 0),
    });
    if (isActive && !insertedAsm) {
      insertedAsm = true;
      out.push(...buildDisasmLines(disasmRows, pc, breakpoints, false));
    }
  }
  if (!insertedAsm) out.push(...buildDisasmLines(disasmRows, pc, breakpoints, false));
  return out;
}

/** Builds display rows for Source, Disasm, Mixed, or Decomp code buffer views. */
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
  return lifted.lines.map((line) => {
    const comment = line.comment ? `  // ${line.comment}` : '';
    const fullText = `${line.code}${comment}`;
    return {
      key: `dec_${line.lineNumber}_${line.address}`,
      kind: 'decomp',
      lineNumber: line.lineNumber,
      address: line.address >>> 0,
      symbol: '',
      rawHex: formatHex32(line.address),
      text: fullText,
      tokens: tokenizeDebugCodeLine(fullText),
      isActive: lifted.activeLineNumber === line.lineNumber,
      hasBreakpoint: opts.breakpoints.has((line.address & ~1) >>> 0),
    };
  });
}
