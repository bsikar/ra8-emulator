import { formatHex32, formatHexByte, formatHexUpper32, formatVirtualTime, parseHexAddress } from '../../../src/app/shared/utils/hex';
import { decodeLedColorList, rgb565ToCssHex } from '../../../src/app/shared/utils/rgb565';

describe('hex and rgb565 utils', () => {
  it('formats and parses 32-bit hex addresses and virtual time', () => {
    expect(formatHex32(0x2000_0040)).toBe('0x20000040');
    expect(formatHexUpper32(0x2000_00ab)).toBe('0x200000AB');
    expect(formatHexByte(0x0a)).toBe('0a');
    expect(parseHexAddress('0x02004a10')).toBe(0x0200_4a10);
    expect(parseHexAddress('invalid')).toBeNull();
    expect(formatVirtualTime(500n)).toBe('500ns');
    expect(formatVirtualTime(12_400_000n)).toBe('12.40ms');
    expect(formatVirtualTime(1_250_000_000n)).toBe('1.250s');
  });

  it('converts RGB565 LED colors to CSS hex', () => {
    expect(rgb565ToCssHex(0xf800)).toBe('#ff0000');
    expect(rgb565ToCssHex(0x07e0)).toBe('#00ff00');
    expect(rgb565ToCssHex(0x001f)).toBe('#0000ff');
    expect(decodeLedColorList([0xf800, 0x001f])).toEqual(['#ff0000', '#0000ff']);
  });
});
