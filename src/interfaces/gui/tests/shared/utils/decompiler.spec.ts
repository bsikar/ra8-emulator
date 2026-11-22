import { decompileThumbRows, tokenizeCodeLine } from '../../../src/app/shared/utils/decompiler';

describe('decompiler', () => {
  it('lifts Thumb-2 rows into structured C lines and emits syntax.css token metadata', () => {
    const fn = decompileThumbRows(
      [
        { address: 0x0200_4a10, size: 2, decoded: true, text: 'push {r4, lr}', symbol: 'sensor_poll' },
        { address: 0x0200_4a12, size: 4, decoded: true, text: 'bl riic1_read_reg' },
        { address: 0x0200_4a16, size: 2, decoded: true, text: 'cmp r0, #0x6c' },
        { address: 0x0200_4a18, size: 2, decoded: true, text: 'bne 0x02004a24' },
        { address: 0x0200_4a1a, size: 4, decoded: true, text: 'ldr r3, [r1, #0x2c]' },
        { address: 0x0200_4a1e, size: 2, decoded: true, text: 'pop {r4, pc}' },
      ],
      0x0200_4a16
    );

    expect(fn.functionName).toBe('sensor_poll');
    expect(fn.activeLineNumber).toBe(4);
    expect(fn.lines.some((l) => l.code.includes('riic1_read_reg('))).toBe(true);
    expect(fn.lines.some((l) => l.code.includes('return (int32_t)r0;'))).toBe(true);

    const branchLine = fn.lines.find((l) => l.code.includes('if ('));
    expect(branchLine?.tokens.some((t) => t.kind === 'kw' && t.text === 'if')).toBe(true);
    expect(branchLine?.tokens.some((t) => t.kind === 'num' && t.text === '0x6c')).toBe(true);
  });

  it('prefers structured pseudocode attached to rows when present', () => {
    const fn = decompileThumbRows(
      [
        {
          address: 0x0200_03fc,
          size: 4,
          decoded: true,
          text: 'bl #0x20029c8 ; ra8_pfs_route_peripheral',
          symbol: 'uart_irq_pins_init',
          pseudo: 'r0 = ra8_pfs_route_peripheral(0xd02, 4, 0x2002b6c /* g_uart_pins_try */)',
        },
        {
          address: 0x0200_0408,
          size: 2,
          decoded: true,
          text: 'beq #0x200040e',
          pseudo: 'if (r3 == 0) goto uart_irq_pins_init+0x22',
        },
      ],
      0x0200_03fc
    );

    expect(fn.functionName).toBe('uart_irq_pins_init');
    expect(fn.lines[1]?.code).toBe('  r0 = ra8_pfs_route_peripheral(0xd02, 4, 0x2002b6c /* g_uart_pins_try */);');
    expect(fn.lines[1]?.tokens.some((t) => t.kind === 'fn' && t.text === 'ra8_pfs_route_peripheral')).toBe(true);
    expect(fn.lines[2]?.code).toBe('  if (r3 == 0) goto uart_irq_pins_init+0x22;');
    expect(fn.lines[2]?.tokens.some((t) => t.kind === 'kw' && t.text === 'if')).toBe(true);
  });

  it('tokenizes keywords, types, functions, numbers, and comments cleanly', () => {
    const tokens = tokenizeCodeLine('const uint32_t ok = run_step(0x10); // done');
    expect(tokens.some((t) => t.kind === 'kw' && t.text === 'const')).toBe(true);
    expect(tokens.some((t) => t.kind === 'type' && t.text === 'uint32_t')).toBe(true);
    expect(tokens.some((t) => t.kind === 'fn' && t.text === 'run_step')).toBe(true);
    expect(tokens.some((t) => t.kind === 'num' && t.text === '0x10')).toBe(true);
    expect(tokens.some((t) => t.kind === 'cmt' && t.text === '// done')).toBe(true);
  });
});
