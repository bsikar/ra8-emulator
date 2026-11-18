import type { ElfSymbol } from 'ra8-rpc-client';
import type { ConsoleEntry } from '../../core/stores/console.store';
import { formatHexByte, formatVirtualTime } from '../../shared/utils/hex';

export type ConsoleDisplayMode = 'ascii' | 'hex';
export type ConsoleTimestampMode = 'elapsed' | 'virtual';
export type ConsoleKindFilter = 'all' | 'rx' | 'tx';

export interface WatchTriggerRule {
  id: string;
  pattern: string;
  pauseOnMatch: boolean;
  hits: number;
}

export interface SymbolTokenSegment {
  text: string;
  symbol: string | null;
  address: number | null;
}

export interface ConsoleByteStats {
  rxCount: number;
  txCount: number;
  rxBytes: number;
  txBytes: number;
}

const HEX_TOKEN_RE = /\b0x[0-9a-fA-F]{6,8}\b/g;

export function applyLineEnding(rawText: string, ending: 'lf' | 'crlf' | 'none'): string {
  if (ending === 'none') return rawText;
  if (ending === 'crlf') {
    const stripped = rawText.replace(/\r?\n$/, '');
    return `${stripped}\r\n`;
  }
  return rawText.endsWith('\n') ? rawText : `${rawText}\n`;
}

export function formatBytesAsHex(bytes: Uint8Array): string {
  if (bytes.length === 0) return '00';
  const hexCols: string[] = [];
  let asciiCol = '';
  for (const b of bytes) {
    hexCols.push(formatHexByte(b));
    asciiCol += b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : '.';
  }
  return `${hexCols.join(' ')}  |${asciiCol}|`;
}

export function formatEntryTimestamp(
  virtualNs: bigint,
  firstNs: bigint,
  mode: ConsoleTimestampMode
): string {
  if (mode === 'virtual') return `${virtualNs.toString()} ns`;
  const delta = virtualNs >= firstNs ? virtualNs - firstNs : 0n;
  return `+${formatVirtualTime(delta)}`;
}

export type ElfSymbolSource = readonly ElfSymbol[] | ReadonlyMap<number, string>;

export function resolveNearestElfSymbol(
  addr: number,
  symbols: ElfSymbolSource
): string | null {
  const target = addr >>> 0;
  let bestAddr = -1;
  let bestName: string | null = null;
  if ('size' in symbols) {
    const exact = symbols.get(target);
    if (exact) return exact;
    for (const [symAddr, symName] of symbols.entries()) {
      const unsignedAddr = symAddr >>> 0;
      if (unsignedAddr <= target && target - unsignedAddr <= 0x0fff && unsignedAddr > bestAddr) {
        bestAddr = unsignedAddr;
        bestName = symName;
      }
    }
  } else {
    for (const sym of symbols) {
      const unsignedAddr = sym.address >>> 0;
      if (unsignedAddr === target) return sym.name;
      if (unsignedAddr <= target && target - unsignedAddr <= 0x0fff && unsignedAddr > bestAddr) {
        bestAddr = unsignedAddr;
        bestName = sym.name;
      }
    }
  }
  if (!bestName || bestAddr < 0) return null;
  const offset = target - bestAddr;
  return offset === 0 ? bestName : `${bestName}+0x${offset.toString(16)}`;
}

export function decodeHexSymbolsInText(
  text: string,
  symbols: ElfSymbolSource
): SymbolTokenSegment[] {
  if (!text) return [];
  const empty = 'size' in symbols ? symbols.size === 0 : symbols.length === 0;
  if (empty) return [{ text, symbol: null, address: null }];
  const segments: SymbolTokenSegment[] = [];
  HEX_TOKEN_RE.lastIndex = 0;
  let cursor = 0;
  let match = HEX_TOKEN_RE.exec(text);
  while (match !== null) {
    const idx = match.index;
    if (idx > cursor) {
      segments.push({ text: text.slice(cursor, idx), symbol: null, address: null });
    }
    const token = match[0];
    const parsed = Number.parseInt(token.slice(2), 16) >>> 0;
    const symbol = resolveNearestElfSymbol(parsed, symbols);
    segments.push({ text: token, symbol, address: symbol ? parsed : null });
    cursor = idx + token.length;
    match = HEX_TOKEN_RE.exec(text);
  }
  if (cursor < text.length) {
    segments.push({ text: text.slice(cursor), symbol: null, address: null });
  }
  return segments;
}

export function evaluateWatchTriggers(
  text: string,
  rules: readonly WatchTriggerRule[]
): { updated: WatchTriggerRule[]; shouldPause: boolean; matchedIds: string[] } {
  if (!text || rules.length === 0) {
    return { updated: [...rules], shouldPause: false, matchedIds: [] };
  }
  let shouldPause = false;
  const matchedIds: string[] = [];
  const lower = text.toLowerCase();
  const updated = rules.map((rule) => {
    const needle = rule.pattern.trim().toLowerCase();
    if (!needle || !lower.includes(needle)) return rule;
    matchedIds.push(rule.id);
    if (rule.pauseOnMatch) shouldPause = true;
    return { ...rule, hits: rule.hits + 1 };
  });
  return { updated, shouldPause, matchedIds };
}

export function filterConsoleEntries(
  entries: readonly ConsoleEntry[],
  query: string,
  kind: ConsoleKindFilter
): ConsoleEntry[] {
  const needle = query.trim().toLowerCase();
  return entries.filter((entry) => {
    if (kind === 'rx' && entry.isInput) return false;
    if (kind === 'tx' && !entry.isInput) return false;
    if (!needle) return true;
    return entry.text.toLowerCase().includes(needle);
  });
}

export function computeConsoleByteStats(entries: readonly ConsoleEntry[]): ConsoleByteStats {
  let rxCount = 0;
  let txCount = 0;
  let rxBytes = 0;
  let txBytes = 0;
  for (const entry of entries) {
    if (entry.isInput) {
      txCount += 1;
      txBytes += entry.bytes.length;
    } else {
      rxCount += 1;
      rxBytes += entry.bytes.length;
    }
  }
  return { rxCount, txCount, rxBytes, txBytes };
}
