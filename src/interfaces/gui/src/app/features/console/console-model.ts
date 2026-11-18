import type { ElfSymbol, SourceLineResult, StackFrame } from 'ra8-rpc-client';
import type { ConsoleEntry } from '../../core/stores/console.store';
import { formatHexByte, formatHexUpper32, formatVirtualTime } from '../../shared/utils/hex';

export type ConsoleDisplayMode = 'ascii' | 'hex';
export type ConsoleTimestampMode = 'elapsed' | 'virtual';
export type ConsoleKindFilter = 'all' | 'rx' | 'tx';
export type ConsoleStreamTab = 'all' | 'uart' | 'swo' | 'rtt';
export type WatchTriggerAction = 'alert_halt' | 'marker';

export interface WatchTriggerRule {
  id: string;
  pattern: string;
  action?: WatchTriggerAction;
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

export interface ConsoleSearchCompileResult {
  matches: (text: string) => boolean;
  regexError: string | null;
}

export interface AddressLookupDetail {
  symbol: string | null;
  fileLine: string | null;
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

export function classifyConsoleStream(entry: ConsoleEntry): 'uart' | 'swo' | 'rtt' {
  if (entry.channel === 10 || /^\s*\[swo\]/i.test(entry.text)) return 'swo';
  if (entry.channel === 11 || /^\s*\[rtt\]/i.test(entry.text)) return 'rtt';
  return 'uart';
}

export function isHaltTriggerRule(rule: WatchTriggerRule): boolean {
  if (rule.action === 'marker') return false;
  if (rule.action === 'alert_halt') return true;
  return rule.pauseOnMatch;
}

export function formatTriggerActionLabel(rule: WatchTriggerRule): string {
  return isHaltTriggerRule(rule) ? 'Alert + Halt' : 'Marker';
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

export function resolveAddressDetail(
  addr: number,
  symbols: ElfSymbolSource,
  sourceLine: SourceLineResult | null,
  frames: readonly StackFrame[] = []
): AddressLookupDetail {
  const target = addr >>> 0;
  const symbol = resolveNearestElfSymbol(target, symbols);
  if (sourceLine && sourceLine.found && (sourceLine.pc >>> 0) === target && sourceLine.path) {
    return { symbol, fileLine: `${sourceLine.path}:${sourceLine.line}` };
  }
  const frame = frames.find((f) => (f.pc >>> 0) === target && f.file && f.line > 0);
  if (frame) {
    return { symbol: symbol ?? frame.name ?? null, fileLine: `${frame.file}:${frame.line}` };
  }
  return { symbol, fileLine: null };
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
): { updated: WatchTriggerRule[]; shouldPause: boolean; shouldMark: boolean; matchedIds: string[] } {
  if (!text || rules.length === 0) {
    return { updated: [...rules], shouldPause: false, shouldMark: false, matchedIds: [] };
  }
  let shouldPause = false;
  let shouldMark = false;
  const matchedIds: string[] = [];
  const lower = text.toLowerCase();
  const updated = rules.map((rule) => {
    const needle = rule.pattern.trim().toLowerCase();
    if (!needle || !lower.includes(needle)) return rule;
    matchedIds.push(rule.id);
    if (isHaltTriggerRule(rule)) shouldPause = true;
    else shouldMark = true;
    return { ...rule, hits: rule.hits + 1 };
  });
  return { updated, shouldPause, shouldMark, matchedIds };
}

export function compileConsoleSearch(query: string, useRegex = false): ConsoleSearchCompileResult {
  const trimmed = query.trim();
  if (!trimmed) return { matches: () => true, regexError: null };
  const slashMatch = !useRegex ? /^\/(.+)\/([a-z]*)$/i.exec(trimmed) : null;
  const pattern = slashMatch ? slashMatch[1] ?? '' : trimmed;
  const flags = slashMatch ? (slashMatch[2] || 'i') : 'i';
  if (useRegex || slashMatch) {
    try {
      const rx = new RegExp(pattern, flags.replace(/g/g, ''));
      return { matches: (text: string) => rx.test(text), regexError: null };
    } catch (err) {
      return {
        matches: () => false,
        regexError: err instanceof Error ? err.message : 'Invalid regular expression',
      };
    }
  }
  const needle = trimmed.toLowerCase();
  return { matches: (text: string) => text.toLowerCase().includes(needle), regexError: null };
}

export function filterConsoleEntries(
  entries: readonly ConsoleEntry[],
  query: string,
  kind: ConsoleKindFilter,
  streamTab: ConsoleStreamTab = 'all',
  useRegex = false
): ConsoleEntry[] {
  const compiled = compileConsoleSearch(query, useRegex);
  return entries.filter((entry) => {
    if (kind === 'rx' && entry.isInput) return false;
    if (kind === 'tx' && !entry.isInput) return false;
    if (streamTab !== 'all' && classifyConsoleStream(entry) !== streamTab) return false;
    return compiled.matches(entry.text);
  });
}

export function formatConsoleCopyText(
  entries: readonly ConsoleEntry[],
  displayMode: ConsoleDisplayMode,
  timestampMode: ConsoleTimestampMode
): string {
  const firstNs = entries[0]?.virtualNs ?? 0n;
  return entries
    .map((entry) => {
      const ts = formatEntryTimestamp(entry.virtualNs, firstNs, timestampMode);
      const stream = classifyConsoleStream(entry).toUpperCase();
      const dir = entry.isInput ? 'TX' : 'RX';
      const body = displayMode === 'hex' ? formatBytesAsHex(entry.bytes) : entry.text;
      return `${ts} [${stream} CH${entry.channel} ${dir}] ${body}`;
    })
    .join('\n');
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

export function formatSourceLineSummary(sl: SourceLineResult | null): string {
  if (!sl || !sl.found) return 'No source location at current PC.';
  const pcHex = formatHexUpper32(sl.pc);
  return sl.path ? `${pcHex} · ${sl.path}:${sl.line}` : `${pcHex} · line ${sl.line}`;
}
