import { describe, expect, it } from 'vitest';
import {
  buildCodeBufferLines,
  tokenizeDebugCodeLine,
} from '../../../src/app/features/debug/debug-code-format';

describe('debug-code-format', () => {
  it('tokenizes C keywords, types, U-suffixed hex literals, and preserves Decomp comments & Mixed interleaving', () => {
    const tokens = tokenizeDebugCodeLine('volatile uint32_t x = 0x01U; // comment');
    expect(tokens.some((t) => t.kind === 'kw' && t.text === 'volatile')).toBe(true);
    expect(tokens.some((t) => t.kind === 'type' && t.text === 'uint32_t')).toBe(true);
    expect(tokens.some((t) => t.kind === 'num' && t.text === '0x01U')).toBe(true);
    expect(tokens.some((t) => t.kind === 'cmt' && t.text.includes('// comment'))).toBe(true);

    const disasmRows = [
      { address: 0x0200_0100, size: 2, decoded: true, raw: new Uint8Array([0x01, 0x20]), text: 'movs r0, #1', symbol: 'main' },
    ];
    const decomp = buildCodeBufferLines({
      mode: 'decomp',
      disasmRows,
      sourceLines: [],
      sourceLine: null,
      pc: 0x0200_0100,
      breakpoints: new Map<number, number>(),
      fnName: 'main',
    });
    expect(decomp.some((l) => l.text.includes('0x02000100: movs r0, #1'))).toBe(true);

    const annotatedRows = [
      {
        address: 0x0200_0100,
        size: 2,
        decoded: true,
        raw: new Uint8Array([0x01, 0x20]),
        text: 'movs r0, #1',
        symbol: 'main',
        pseudo: 'r0 = 1',
      },
    ];
    const asmWithPseudo = buildCodeBufferLines({
      mode: 'disasm',
      disasmRows: annotatedRows,
      sourceLines: [],
      sourceLine: null,
      pc: 0x0200_0100,
      breakpoints: new Map<number, number>(),
    });
    expect(asmWithPseudo[0]?.text).toBe('movs r0, #1  // r0 = 1');
    expect(asmWithPseudo[0]?.tokens.some((t) => t.kind === 'cmt' && t.text === '// r0 = 1')).toBe(true);

    const mixed = buildCodeBufferLines({
      mode: 'mixed',
      disasmRows,
      sourceLines: ['void main(void) {', '  return;', '}'],
      sourceLine: { found: true, pc: 0x0200_0100, line: 2, path: 'main.c' },
      pc: 0x0200_0100,
      breakpoints: new Map<number, number>([[0x0200_0100, 1]]),
    });
    expect(mixed.filter((l) => l.kind === 'header').length).toBe(3);
    expect(mixed[1]?.hasBreakpoint).toBe(true);
    expect(mixed.some((l) => l.kind === 'disasm' && l.address === 0x0200_0100)).toBe(true);
  });
});
