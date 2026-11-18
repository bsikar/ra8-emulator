import { Core, type ElfSymbol } from 'ra8-rpc-client';
import { formatHex32 } from '../../shared/utils/hex';
import type { FlamegraphNode, FlamegraphView } from '../../shared/utils/flamegraph';

export type HotspotSortKey = 'symbol' | 'selfPct' | 'totalPct' | 'samples';
export type HotspotSortDir = 'asc' | 'desc';

export interface HotspotRow {
  symbol: string;
  selfSamples: number;
  selfPct: number;
  totalSamples: number;
  totalPct: number;
  sourceLocation: string;
  address: number | null;
  core: Core;
}

function collectSymbolAncestors(view: FlamegraphView): Map<string, FlamegraphNode> {
  const byId = new Map<string, FlamegraphNode>();
  for (const node of view.nodes) {
    byId.set(node.id, node);
  }
  return byId;
}

function hasAncestorWithName(
  node: FlamegraphNode,
  byId: ReadonlyMap<string, FlamegraphNode>
): boolean {
  let pid = node.parentId;
  while (pid) {
    const parent = byId.get(pid);
    if (!parent) break;
    if (parent.depth > 0 && parent.name === node.name) return true;
    pid = parent.parentId;
  }
  return false;
}

export function nodeMatchesFilter(name: string, query: string): boolean {
  const clean = query.trim().toLowerCase();
  if (!clean) return true;
  return name.toLowerCase().includes(clean);
}

export function resolveSymbolAddress(symbol: string, symbols: readonly ElfSymbol[]): number | null {
  const clean = symbol.trim();
  if (!clean) return null;
  const exact = symbols.find((s) => s.name === clean);
  if (exact) return exact.address >>> 0;
  const stripped = clean.replace(/\s+\[[^\]]+\]$/, '');
  const fallback = symbols.find((s) => s.name === stripped);
  return fallback ? fallback.address >>> 0 : null;
}

export function aggregateHotspots(
  view: FlamegraphView,
  symbols: readonly ElfSymbol[],
  core: Core,
  filterQuery = ''
): HotspotRow[] {
  if (view.totalSamples <= 0) return [];
  const byId = collectSymbolAncestors(view);
  const buckets = new Map<string, { selfSamples: number; totalSamples: number }>();

  for (const node of view.nodes) {
    if (node.depth === 0) continue;
    const prev = buckets.get(node.name) ?? { selfSamples: 0, totalSamples: 0 };
    prev.selfSamples += node.selfSamples;
    if (!hasAncestorWithName(node, byId)) {
      prev.totalSamples += node.samples;
    }
    buckets.set(node.name, prev);
  }

  const out: HotspotRow[] = [];
  for (const [symbol, stats] of buckets.entries()) {
    if (stats.selfSamples <= 0 || !nodeMatchesFilter(symbol, filterQuery)) continue;
    const address = resolveSymbolAddress(symbol, symbols);
    out.push({
      symbol,
      selfSamples: stats.selfSamples,
      selfPct: Math.round((stats.selfSamples / view.totalSamples) * 1000) / 10,
      totalSamples: stats.totalSamples,
      totalPct: Math.round((stats.totalSamples / view.totalSamples) * 1000) / 10,
      sourceLocation: address !== null ? formatHex32(address) : `${symbol} -> /debug`,
      address,
      core,
    });
  }
  return out;
}

export function sortHotspots(
  rows: readonly HotspotRow[],
  key: HotspotSortKey,
  dir: HotspotSortDir
): HotspotRow[] {
  const sign = dir === 'asc' ? 1 : -1;
  return [...rows].sort((a, b) => {
    if (key === 'symbol') return a.symbol.localeCompare(b.symbol) * sign;
    if (key === 'totalPct') {
      return (a.totalPct - b.totalPct || a.selfPct - b.selfPct) * sign;
    }
    if (key === 'samples') {
      return (a.selfSamples - b.selfSamples || a.totalSamples - b.totalSamples) * sign;
    }
    return (a.selfPct - b.selfPct || a.totalPct - b.totalPct) * sign;
  });
}

export function mergeFoldedTexts(cpu0Folded: string, cpu1Folded: string): string {
  const parts: string[] = [];
  for (const [tag, raw] of [
    ['CPU0', cpu0Folded],
    ['CPU1', cpu1Folded],
  ] as const) {
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      parts.push(`${tag};${trimmed}`);
    }
  }
  return parts.join('\n');
}
