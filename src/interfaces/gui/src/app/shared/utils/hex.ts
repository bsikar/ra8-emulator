export function formatHex32(value: number): string {
  return `0x${(value >>> 0).toString(16).padStart(8, '0')}`;
}

export function formatHexUpper32(value: number): string {
  return `0x${(value >>> 0).toString(16).toUpperCase().padStart(8, '0')}`;
}

export function formatHexByte(value: number): string {
  return (value & 0xff).toString(16).padStart(2, '0');
}

export function parseHexAddress(raw: string): number | null {
  const clean = raw.trim();
  if (!clean) return null;
  const stripped = clean.startsWith('0x') || clean.startsWith('0X') ? clean.slice(2) : clean;
  if (!/^[0-9a-fA-F]+$/.test(stripped)) return null;
  const parsed = Number.parseInt(stripped, 16);
  return Number.isFinite(parsed) ? parsed >>> 0 : null;
}

export function formatVirtualTime(ns: bigint): string {
  if (ns < 0n) return '0ns';
  if (ns >= 1_000_000_000n) {
    const whole = ns / 1_000_000_000n;
    const milli = (ns % 1_000_000_000n) / 1_000_000n;
    return `${whole}.${milli.toString().padStart(3, '0')}s`;
  }
  if (ns >= 1_000_000n) {
    const whole = ns / 1_000_000n;
    const frac = (ns % 1_000_000n) / 10_000n;
    return `${whole}.${frac.toString().padStart(2, '0')}ms`;
  }
  if (ns >= 1_000n) {
    const whole = ns / 1_000n;
    const frac = (ns % 1_000n) / 100n;
    return `${whole}.${frac}us`;
  }
  return `${ns.toString()}ns`;
}
