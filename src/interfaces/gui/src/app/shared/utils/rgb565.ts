export function rgb565ToCssHex(rgb565: number): string {
  const r5 = (rgb565 >> 11) & 0x1f;
  const g6 = (rgb565 >> 5) & 0x3f;
  const b5 = rgb565 & 0x1f;
  const r = Math.round((r5 * 255) / 31);
  const g = Math.round((g6 * 255) / 63);
  const b = Math.round((b5 * 255) / 31);
  return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

export function decodeLedColorList(colors: readonly number[]): string[] {
  return colors.map((c) => rgb565ToCssHex(c));
}
