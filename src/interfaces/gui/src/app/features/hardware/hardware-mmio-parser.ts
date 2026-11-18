import { formatHexByte, formatHexUpper32 } from '../../shared/utils/hex';

export const MMIO_QUICK_BLOCKS = ['NPU', 'GLCDC', 'CEU', 'RIIC0', 'SCI8', 'IPC', 'SCB', 'SAU'] as const;

export function formatMmioHexDump(base: number, bytes: Uint8Array): string {
  const lines: string[] = [];
  for (let off = 0; off < bytes.length; off += 16) {
    const addr = formatHexUpper32((base + off) >>> 0);
    const cols: string[] = [];
    for (let i = off; i < Math.min(off + 16, bytes.length); i++) {
      cols.push(formatHexByte(bytes[i] ?? 0));
    }
    lines.push(`${addr}: ${cols.join(' ')}`);
  }
  return lines.join('\n');
}

export interface PeriphBitSlice {
  label: string;
  valueHex: string;
}

export interface ParsedPeriphRegister {
  name: string;
  offset: number;
  offsetHex: string;
  widthBits: number | null;
  value: number | null;
  valueHex: string | null;
  slices: PeriphBitSlice[];
}

export interface ParsedPeriphDump {
  kind: 'registers' | 'text';
  blockName: string;
  baseAddress: number | null;
  sizeBytes: number | null;
  registers: ParsedPeriphRegister[];
  rawText: string;
}

interface RawPeriphJson {
  block?: string;
  registers?: Array<{ name?: string; offset?: number; width?: number | null }>;
}

function readLittleEndianValue(bytes: Uint8Array, offset: number, widthBits: number | null): number | null {
  const byteCount = widthBits === 8 ? 1 : widthBits === 16 ? 2 : 4;
  if (offset < 0 || offset + byteCount > bytes.length) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (byteCount === 1) return view.getUint8(offset);
  if (byteCount === 2) return view.getUint16(offset, true);
  return view.getUint32(offset, true);
}

function buildBitSlices(value: number, widthBits: number | null): PeriphBitSlice[] {
  const bits = widthBits ?? 32;
  const out: PeriphBitSlice[] = [];
  for (let bit = 0; bit < bits; bit += 8) {
    const hi = Math.min(bits - 1, bit + 7);
    const mask = hi - bit === 7 ? 0xff : (1 << (hi - bit + 1)) - 1;
    const part = (value >>> bit) & mask;
    out.push({
      label: `[${hi}:${bit}]`,
      valueHex: `0x${part.toString(16).toUpperCase().padStart(2, '0')}`,
    });
  }
  return out;
}

function parseHeaderLine(firstLine: string): { blockName: string; baseAddress: number | null; sizeBytes: number | null } | null {
  const match = /^(\S+)\s+·\s+0x([0-9a-fA-F]+)\s+·\s+0x([0-9a-fA-F]+)$/.exec(firstLine.trim());
  if (!match) return null;
  return {
    blockName: match[1] ?? '',
    baseAddress: Number.parseInt(match[2] ?? '0', 16) >>> 0,
    sizeBytes: Number.parseInt(match[3] ?? '0', 16) >>> 0,
  };
}

export function parsePeriphDump(rawText: string, liveBytes?: Uint8Array | null): ParsedPeriphDump {
  const trimmed = rawText.trim();
  if (!trimmed) {
    return { kind: 'text', blockName: '', baseAddress: null, sizeBytes: null, registers: [], rawText: '' };
  }
  const lines = trimmed.split(/\r?\n/);
  const header = parseHeaderLine(lines[0] ?? '');
  const body = header ? lines.slice(1).join('\n').trim() : trimmed;

  if (body.startsWith('{')) {
    try {
      const parsed = JSON.parse(body) as RawPeriphJson;
      if (Array.isArray(parsed.registers)) {
        const registers: ParsedPeriphRegister[] = [];
        for (const reg of parsed.registers) {
          if (!reg.name || typeof reg.offset !== 'number') continue;
          const widthBits = typeof reg.width === 'number' ? reg.width : null;
          const value = liveBytes ? readLittleEndianValue(liveBytes, reg.offset, widthBits) : null;
          const valueHex =
            value === null
              ? null
              : widthBits === 8
                ? `0x${value.toString(16).toUpperCase().padStart(2, '0')}`
                : widthBits === 16
                  ? `0x${value.toString(16).toUpperCase().padStart(4, '0')}`
                  : formatHexUpper32(value);
          registers.push({
            name: reg.name,
            offset: reg.offset,
            offsetHex: `0x${reg.offset.toString(16).toUpperCase().padStart(2, '0')}`,
            widthBits,
            value,
            valueHex,
            slices: value !== null ? buildBitSlices(value, widthBits) : [],
          });
        }
        return {
          kind: 'registers',
          blockName: parsed.block ?? header?.blockName ?? '',
          baseAddress: header?.baseAddress ?? null,
          sizeBytes: header?.sizeBytes ?? null,
          registers,
          rawText: trimmed,
        };
      }
    } catch (err) {
      void err;
    }
  }

  return {
    kind: 'text',
    blockName: header?.blockName ?? '',
    baseAddress: header?.baseAddress ?? null,
    sizeBytes: header?.sizeBytes ?? null,
    registers: [],
    rawText: trimmed,
  };
}

export function filterPeriphBlocks(blocks: readonly string[], query: string): string[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [...blocks];
  return blocks.filter((b) => b.toLowerCase().includes(needle));
}

export function findQuickBlockMatch(blocks: readonly string[], chip: string): string {
  const upper = chip.toUpperCase();
  const exact = blocks.find((b) => b.toUpperCase() === upper);
  if (exact) return exact;
  const aliases: Record<string, string[]> = {
    RIIC0: ['RIIC', 'I3C'],
    SCI8: ['SCI_B UART', 'SCI_B', 'SCI'],
  };
  for (const alias of aliases[upper] ?? []) {
    const match = blocks.find((b) => b.toUpperCase().includes(alias));
    if (match) return match;
  }
  const prefix = blocks.find((b) => b.toUpperCase().startsWith(upper));
  return prefix ?? chip;
}

export const CORE_SYSTEM_MMIO_ADDRESSES: Readonly<Record<string, number>> = {
  SCB: 0xe000_ed00,
  SAU: 0xe000_edd0,
};
