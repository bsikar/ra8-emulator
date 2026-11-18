import { Core, Register } from 'ra8-rpc-client';
import { describe, expect, it } from 'vitest';
import {
  boardHasNpu,
  buildCodeBufferLines,
  buildMemoryHexRows,
  evaluateWatchExpressions,
  filterRegisterEntries,
  parseRegisterOrMemoryValue,
} from '../../../src/app/features/debug/debug-view';

describe('debug-view helpers', () => {
  const disasmRows = [
    { address: 0x0200_0100, size: 2, decoded: true, raw: new Uint8Array([0x00, 0xbf]), text: 'nop', symbol: 'main' },
    { address: 0x0200_0102, size: 2, decoded: true, raw: new Uint8Array([0x01, 0x20]), text: 'movs r0, #1', symbol: 'main' },
  ];

  it('builds code buffer lines across disasm, source, mixed, and decomp modes', () => {
    const bps = new Map<number, number>([[0x0200_0102, 1]]);
    const asm = buildCodeBufferLines({
      mode: 'disasm',
      disasmRows,
      sourceLines: [],
      sourceLine: null,
      pc: 0x0200_0100,
      breakpoints: bps,
    });
    expect(asm.length).toBe(2);
    expect(asm[0]?.isActive).toBe(true);
    expect(asm[1]?.hasBreakpoint).toBe(true);

    const src = buildCodeBufferLines({
      mode: 'source',
      disasmRows,
      sourceLines: ['int main(void) {', '  return 1;', '}'],
      sourceLine: { found: true, pc: 0x0200_0102, line: 2, path: 'main.c' },
      pc: 0x0200_0102,
      breakpoints: bps,
    });
    expect(src[1]?.isActive).toBe(true);
    expect(src[1]?.hasBreakpoint).toBe(true);

    const mixed = buildCodeBufferLines({
      mode: 'mixed',
      disasmRows,
      sourceLines: ['int main(void) {', '  return 1;'],
      sourceLine: { found: true, pc: 0x0200_0102, line: 2, path: 'main.c' },
      pc: 0x0200_0102,
      breakpoints: bps,
    });
    expect(mixed.some((l) => l.kind === 'header')).toBe(true);
    expect(mixed.some((l) => l.kind === 'disasm')).toBe(true);

    const decomp = buildCodeBufferLines({
      mode: 'decomp',
      disasmRows,
      sourceLines: [],
      sourceLine: null,
      pc: 0x0200_0102,
      breakpoints: bps,
    });
    expect(decomp.some((l) => l.text.includes('r0 = 1'))).toBe(true);
  });

  it('evaluates watch expressions against locals, registers, ELF symbols, and hex addresses', () => {
    const watches = evaluateWatchExpressions(
      ['count', 'pc', 'sensor_buf', '0x22000100', 'missing'],
      [{ name: 'count', typeName: 'uint32_t', size: 4, locationLabel: 'frame-4', valueHex: '0x00000007', valueDec: '7', address: 0x2000_0100 }],
      { pc: 0x0200_0104 },
      [{ name: 'sensor_buf', address: 0x2200_0000, size: 16, kind: 'object' }]
    );
    expect(watches.map((w) => w.valueHex)).toEqual([
      '0x00000007',
      '0x02000104',
      '0x22000000',
      '0x22000100',
      '—',
    ]);
  });

  it('formats 16-byte memory hex rows, filters register groups, and detects NPU capability', () => {
    const bytes = new Uint8Array([0x41, 0x42, 0x00, 0x7e]);
    const prev = new Uint8Array([0x41, 0xff, 0x00, 0x7e]);
    const memRows = buildMemoryHexRows(0x2200_0000, bytes, prev);
    expect(memRows[0]?.addrHex).toBe('0x22000000');
    expect(memRows[0]?.cells[1]?.changed).toBe(true);
    expect(memRows[0]?.ascii).toBe('AB.~');

    const gpr = filterRegisterEntries('gpr', { pc: 0x0200_0100, r0: 0 }, { pc: 0x0200_00fe, r0: 0 }, true);
    const pcRow = gpr.find((r) => r.reg === Register.Pc);
    const r0Row = gpr.find((r) => r.reg === Register.R0);
    expect(pcRow?.changed).toBe(true);
    expect(r0Row?.dimmed).toBe(true);

    const sys = filterRegisterEntries('sys', { primask: 1 }, {}, false);
    expect(sys.some((r) => r.name === 'psplim')).toBe(true);
    expect(parseRegisterOrMemoryValue('0x1234')).toBe(0x1234);
    expect(parseRegisterOrMemoryValue('42')).toBe(42);
    expect(parseRegisterOrMemoryValue('bad')).toBeNull();
    expect(boardHasNpu(null, 'npu=ethos_u55')).toBe(true);
    expect(Core.Cpu0).toBe(0);
  });
});
