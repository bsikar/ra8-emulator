import {
  CORE_SYSTEM_MMIO_ADDRESSES,
  filterPeriphBlocks,
  findQuickBlockMatch,
  formatMmioHexDump,
  parsePeriphDump,
} from '../../../src/app/features/hardware/hardware-mmio-parser';

describe('hardware-mmio-parser', () => {
  it('parses peripheral register JSON descriptors with live memory byte slices', () => {
    const raw =
      'RTC · 0x40200000 · 0x40\n' +
      JSON.stringify({
        block: 'RTC',
        registers: [
          { name: 'R64CNT', offset: 0, width: 8 },
          { name: 'RCR1', offset: 4, width: 16 },
        ],
      });
    const bytes = new Uint8Array([0x2b, 0, 0, 0, 0x12, 0xab]);
    const parsed = parsePeriphDump(raw, bytes);
    expect(parsed.kind).toBe('registers');
    expect(parsed.blockName).toBe('RTC');
    expect(parsed.baseAddress).toBe(0x4020_0000);
    expect(parsed.registers.length).toBe(2);
    expect(parsed.registers[0]?.valueHex).toBe('0x2B');
    expect(parsed.registers[1]?.valueHex).toBe('0xAB12');
    expect(parsed.registers[1]?.slices).toEqual([
      { label: '[7:0]', valueHex: '0x12' },
      { label: '[15:8]', valueHex: '0xAB' },
    ]);
  });

  it('falls back to text mode and filters/matches quick peripheral blocks', () => {
    expect(formatMmioHexDump(0x4000_0000, new Uint8Array([0xab, 0xcd]))).toBe('0x40000000: ab cd');
    const textDump = parsePeriphDump('SCI8 · SSR = 0x84');
    expect(textDump.kind).toBe('text');
    expect(textDump.rawText).toBe('SCI8 · SSR = 0x84');

    const blocks = ['NPU0', 'GLCDC', 'RIIC', 'SCI_B UART'];
    expect(filterPeriphBlocks(blocks, 'sci')).toEqual(['SCI_B UART']);
    expect(findQuickBlockMatch(blocks, 'NPU')).toBe('NPU0');
    expect(findQuickBlockMatch(blocks, 'RIIC0')).toBe('RIIC');
    expect(findQuickBlockMatch(blocks, 'SCI8')).toBe('SCI_B UART');
    expect(CORE_SYSTEM_MMIO_ADDRESSES['SCB']).toBe(0xe000_ed00);
    expect(CORE_SYSTEM_MMIO_ADDRESSES['SAU']).toBe(0xe000_edd0);
  });
});
