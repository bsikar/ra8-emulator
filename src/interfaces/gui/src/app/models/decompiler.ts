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

function containsAsciiNeedle(haystack: Uint8Array, needle: string): boolean {
  const nLen = needle.length;
  if (haystack.length < nLen || nLen === 0) return false;
  outer: for (let i = 0; i <= haystack.length - nLen; i++) {
    for (let j = 0; j < nLen; j++) {
      if (haystack[i + j] !== needle.charCodeAt(j)) continue outer;
    }
    return true;
  }
  return false;
}

export function detectElfDwarfSections(bytes: Uint8Array): boolean {
  if (bytes.length < 16) return false;
  const isElf = bytes[0] === 0x7f && bytes[1] === 0x45 && bytes[2] === 0x4c && bytes[3] === 0x46;
  if (!isElf) return false;
  return (
    containsAsciiNeedle(bytes, '.debug_info') ||
    containsAsciiNeedle(bytes, '.debug_line') ||
    containsAsciiNeedle(bytes, '.debug_abbrev')
  );
}

function formatHex(addr: number): string {
  return `0x${(addr >>> 0).toString(16).padStart(8, '0')}`;
}

function parseMemOperand(op: string): string {
  const cleaned = op.replace(/[\[\]]/g, '').trim();
  const parts = cleaned.split(',').map((s) => s.trim());
  if (parts.length === 1) return parts[0];
  const off = parts[1].replace(/^#/, '');
  return `${parts[0]} + ${off}`;
}

export function decompileThumbRows(
  rows: readonly DisasmRowInput[],
  activePc: number,
  fallbackFnName?: string
): DecompiledFunction {
  const firstAddr = rows.length > 0 ? rows[0].address >>> 0 : activePc >>> 0;
  const namedRow = rows.find((r) => Boolean(r.symbol && r.symbol.trim().length > 0));
  const functionName =
    namedRow?.symbol?.trim() ||
    fallbackFnName?.trim() ||
    `fn_${firstAddr.toString(16).padStart(8, '0')}`;
  const signature = `int32_t ${functionName}(uint32_t r0, uint32_t r1)`;

  const lines: DecompiledLine[] = [];
  let lineNum = 1;
  let lastCmpLhs = 'r0';
  let lastCmpRhs = '0';

  lines.push({
    lineNumber: lineNum++,
    address: firstAddr,
    code: `${signature} {`,
    comment: 'RA8EMU-1247 stripped ELF control-flow lift',
  });

  for (const row of rows) {
    const addr = row.address >>> 0;
    const rawText = row.text.trim();
    const parts = rawText.split(/\s+/);
    const mnemonic = (parts[0] ?? '').toLowerCase().replace(/\.w$|\.n$/, '');
    const argsStr = rawText.slice(parts[0]?.length ?? 0).trim();
    const ops = argsStr.split(',').map((s) => s.trim()).filter(Boolean);

    let code = `  /* ${rawText} */`;
    if (mnemonic.startsWith('push')) {
      code = `  // prologue: save ${argsStr || 'frame'}`;
    } else if (mnemonic === 'bl' || mnemonic === 'blx') {
      const target = ops[0]?.replace(/[<>]/g, '') || 'sub_unknown';
      const fnExpr = /^0x/i.test(target) ? `fn_${target.replace(/^0x/i, '')}` : target;
      code = `  r0 = ${fnExpr}(r0, r1, r2);`;
    } else if (mnemonic === 'cmp' || mnemonic === 'cmn') {
      lastCmpLhs = ops[0] ?? 'r0';
      lastCmpRhs = (ops[1] ?? '#0').replace(/^#/, '');
      code = `  int32_t cond_lhs = ${lastCmpLhs}; // compare with ${lastCmpRhs}`;
    } else if (mnemonic === 'bne' || mnemonic === 'beq' || mnemonic === 'blt' || mnemonic === 'bge' || mnemonic === 'bhi' || mnemonic === 'bls') {
      const op =
        mnemonic === 'bne' ? '!='
        : mnemonic === 'beq' ? '=='
        : mnemonic === 'blt' ? '<'
        : mnemonic === 'bge' ? '>='
        : mnemonic === 'bhi' ? '>'
        : '<=';
      const target = (ops[0] ?? '0x0').replace(/^#/, '');
      code = `  if (${lastCmpLhs} ${op} ${lastCmpRhs}) goto loc_${target.replace(/^0x/i, '')};`;
    } else if (mnemonic === 'cbz' || mnemonic === 'cbnz') {
      const op = mnemonic === 'cbz' ? '==' : '!=';
      code = `  if (${ops[0] ?? 'r0'} ${op} 0) goto loc_${(ops[1] ?? '0x0').replace(/^0x/i, '')};`;
    } else if (mnemonic.startsWith('ldr')) {
      const rd = ops[0] ?? 'r0';
      const expr = parseMemOperand(ops.slice(1).join(', '));
      code = `  ${rd} = *(volatile uint32_t *)(${expr});`;
    } else if (mnemonic.startsWith('str')) {
      const rd = ops[0] ?? 'r0';
      const expr = parseMemOperand(ops.slice(1).join(', '));
      code = `  *(volatile uint32_t *)(${expr}) = ${rd};`;
    } else if (mnemonic === 'mov' || mnemonic === 'movs' || mnemonic === 'movw') {
      code = `  ${ops[0] ?? 'r0'} = ${(ops[1] ?? '0').replace(/^#/, '')};`;
    } else if (mnemonic === 'add' || mnemonic === 'adds') {
      const dst = ops[0] ?? 'r0';
      const a = ops[1] ?? dst;
      const b = (ops[2] ?? ops[1] ?? '0').replace(/^#/, '');
      code = ops.length >= 3 ? `  ${dst} = ${a} + ${b};` : `  ${dst} += ${b};`;
    } else if (mnemonic === 'sub' || mnemonic === 'subs') {
      const dst = ops[0] ?? 'r0';
      const a = ops[1] ?? dst;
      const b = (ops[2] ?? ops[1] ?? '0').replace(/^#/, '');
      code = ops.length >= 3 ? `  ${dst} = ${a} - ${b};` : `  ${dst} -= ${b};`;
    } else if (mnemonic === 'pop' && argsStr.toLowerCase().includes('pc')) {
      code = `  return (int32_t)r0;`;
    } else if (mnemonic === 'bx' && argsStr.toLowerCase().includes('lr')) {
      code = `  return (int32_t)r0;`;
    } else if (mnemonic === 'nop' || mnemonic === 'wfi') {
      code = `  __asm__("${mnemonic}");`;
    }

    lines.push({
      lineNumber: lineNum++,
      address: addr,
      code,
      comment: `${formatHex(addr)}: ${rawText}`,
      isBranchTarget: addr === (activePc >>> 0),
    });
  }

  lines.push({
    lineNumber: lineNum++,
    address: rows.length > 0 ? rows[rows.length - 1].address >>> 0 : firstAddr,
    code: '}',
  });

  const targetPc = activePc >>> 0;
  const active =
    lines.find((l, idx) => idx > 0 && l.address === targetPc) ??
    lines.find((l) => l.address === targetPc) ??
    null;

  return {
    functionName,
    signature,
    baseAddress: firstAddr,
    lines,
    activeLineNumber: active?.lineNumber ?? null,
    note: 'Stripped binary detected: synthesized deterministic C control flow from Thumb-2 stream.',
  };
}
