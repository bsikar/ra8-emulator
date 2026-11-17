import { formatHex32 } from './hex';

export type SyntaxTokenKind = 'kw' | 'type' | 'fn' | 'num' | 'id' | 'cmt' | 'punct';

export interface SyntaxToken {
  kind: SyntaxTokenKind;
  text: string;
}

export interface DisasmRowInput {
  address: number;
  size?: number;
  decoded?: boolean;
  raw?: Uint8Array;
  text: string;
  symbol?: string;
}

export interface DecompiledLine {
  lineNumber: number;
  address: number;
  code: string;
  tokens: SyntaxToken[];
  comment?: string;
  isBranchTarget?: boolean;
}

export interface DecompiledFunction {
  functionName: string;
  signature: string;
  baseAddress: number;
  lines: DecompiledLine[];
  activeLineNumber: number | null;
  note: string;
}

const KEYWORDS = new Set(['if', 'goto', 'return', 'volatile', 'const', 'static', 'void', '__asm__']);
const TYPES = new Set(['int32_t', 'uint32_t', 'uint16_t', 'uint8_t']);

export function tokenizeCodeLine(line: string): SyntaxToken[] {
  const cmtIdx = line.indexOf('//');
  const codePart = cmtIdx >= 0 ? line.slice(0, cmtIdx) : line;
  const cmtPart = cmtIdx >= 0 ? line.slice(cmtIdx) : '';
  const tokens: SyntaxToken[] = [];
  const pattern = /(\/\*.*?\*\/|"(?:[^"\\]|\\.)*"|\b0x[0-9a-fA-F]+\b|\b\d+[UuLl]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b|[^\w\s]+|\s+)/g;
  for (const match of codePart.matchAll(pattern)) {
    const text = match[0];
    if (text.startsWith('/*')) {
      tokens.push({ kind: 'cmt', text });
    } else if (/^(0x[0-9a-fA-F]+|\d+[UuLl]*|".*")$/.test(text)) {
      tokens.push({ kind: 'num', text });
    } else if (KEYWORDS.has(text)) {
      tokens.push({ kind: 'kw', text });
    } else if (TYPES.has(text)) {
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
  if (cmtPart) tokens.push({ kind: 'cmt', text: cmtPart });
  return tokens;
}

function parseMemOperand(op: string): string {
  const parts = op.replace(/[\[\]]/g, '').trim().split(',').map((s) => s.trim());
  const base = parts[0] ?? 'sp';
  if (parts.length <= 1) return base;
  return `${base} + ${(parts[1] ?? '0').replace(/^#/, '')}`;
}

function liftInstruction(
  mnemonic: string,
  argsStr: string,
  ops: readonly string[],
  cmpState: { lhs: string; rhs: string }
): string {
  if (mnemonic.startsWith('push')) return `  // prologue: save ${argsStr || 'frame'}`;
  if (mnemonic === 'bl' || mnemonic === 'blx') {
    const target = ops[0]?.replace(/[<>]/g, '') || 'sub_unknown';
    return `  r0 = ${/^0x/i.test(target) ? `fn_${target.replace(/^0x/i, '')}` : target}(r0, r1, r2);`;
  }
  if (mnemonic === 'cmp' || mnemonic === 'cmn') {
    cmpState.lhs = ops[0] ?? 'r0';
    cmpState.rhs = (ops[1] ?? '#0').replace(/^#/, '');
    return `  int32_t cond_lhs = ${cmpState.lhs}; // compare with ${cmpState.rhs}`;
  }
  const branchOps: Record<string, string> = { bne: '!=', beq: '==', blt: '<', bge: '>=', bhi: '>', bls: '<=' };
  const branchOp = branchOps[mnemonic];
  if (branchOp) {
    return `  if (${cmpState.lhs} ${branchOp} ${cmpState.rhs}) goto loc_${(ops[0] ?? '0x0').replace(/^#?0x/i, '')};`;
  }
  if (mnemonic === 'cbz' || mnemonic === 'cbnz') {
    return `  if (${ops[0] ?? 'r0'} ${mnemonic === 'cbz' ? '==' : '!='} 0) goto loc_${(ops[1] ?? '0x0').replace(/^0x/i, '')};`;
  }
  if (mnemonic.startsWith('ldr')) return `  ${ops[0] ?? 'r0'} = *(volatile uint32_t *)(${parseMemOperand(ops.slice(1).join(', '))});`;
  if (mnemonic.startsWith('str')) return `  *(volatile uint32_t *)(${parseMemOperand(ops.slice(1).join(', '))}) = ${ops[0] ?? 'r0'};`;
  if (mnemonic === 'mov' || mnemonic === 'movs' || mnemonic === 'movw') {
    return `  ${ops[0] ?? 'r0'} = ${(ops[1] ?? '0').replace(/^#/, '')};`;
  }
  if (mnemonic === 'add' || mnemonic === 'adds' || mnemonic === 'sub' || mnemonic === 'subs') {
    const sign = mnemonic.startsWith('add') ? '+' : '-';
    const dst = ops[0] ?? 'r0';
    const b = (ops[2] ?? ops[1] ?? '0').replace(/^#/, '');
    return ops.length >= 3 ? `  ${dst} = ${ops[1] ?? dst} ${sign} ${b};` : `  ${dst} ${sign}= ${b};`;
  }
  if ((mnemonic === 'pop' && argsStr.toLowerCase().includes('pc')) || (mnemonic === 'bx' && argsStr.toLowerCase().includes('lr'))) {
    return '  return (int32_t)r0;';
  }
  if (mnemonic === 'nop' || mnemonic === 'wfi') return `  __asm__("${mnemonic}");`;
  return `  /* ${mnemonic} ${argsStr} */`;
}

export function decompileThumbRows(
  rows: readonly DisasmRowInput[],
  activePc: number,
  fallbackFnName?: string
): DecompiledFunction {
  const firstAddr = rows.length > 0 ? (rows[0]?.address ?? activePc) >>> 0 : activePc >>> 0;
  const namedRow = rows.find((r) => Boolean(r.symbol && r.symbol.trim().length > 0));
  const functionName = namedRow?.symbol?.trim() || fallbackFnName?.trim() || `fn_${firstAddr.toString(16).padStart(8, '0')}`;
  const signature = `int32_t ${functionName}(uint32_t r0, uint32_t r1)`;
  const lines: DecompiledLine[] = [];
  const cmpState = { lhs: 'r0', rhs: '0' };
  let lineNum = 1;

  const headerCode = `${signature} {`;
  lines.push({ lineNumber: lineNum++, address: firstAddr, code: headerCode, tokens: tokenizeCodeLine(headerCode) });

  for (const row of rows) {
    const addr = row.address >>> 0;
    const rawText = row.text.trim();
    const parts = rawText.split(/\s+/);
    const mnemonic = (parts[0] ?? '').toLowerCase().replace(/\.w$|\.n$/, '');
    const argsStr = rawText.slice(parts[0]?.length ?? 0).trim();
    const ops = argsStr.split(',').map((s) => s.trim()).filter(Boolean);
    const code = liftInstruction(mnemonic, argsStr, ops, cmpState);
    lines.push({
      lineNumber: lineNum++,
      address: addr,
      code,
      tokens: tokenizeCodeLine(code),
      comment: `${formatHex32(addr)}: ${rawText}`,
      isBranchTarget: addr === (activePc >>> 0),
    });
  }

  const endAddr = rows.length > 0 ? (rows[rows.length - 1]?.address ?? firstAddr) >>> 0 : firstAddr;
  lines.push({ lineNumber: lineNum++, address: endAddr, code: '}', tokens: tokenizeCodeLine('}') });
  const targetPc = activePc >>> 0;
  const active = lines.find((l, idx) => idx > 0 && l.address === targetPc) ?? lines.find((l) => l.address === targetPc) ?? null;

  return {
    functionName,
    signature,
    baseAddress: firstAddr,
    lines,
    activeLineNumber: active?.lineNumber ?? null,
    note: 'Deterministic Thumb-2 control-flow lift',
  };
}
