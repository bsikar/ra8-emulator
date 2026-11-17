/**
 * Root Angular Signal store powering JetBrains-style Search Everywhere with fuzzy
 * match spans, `0x...` address and `:line` jump parsing, pluggable providers, and
 * persisted recent queries.
 */

import { Injectable, computed, inject, signal } from '@angular/core';
import { formatHex32 } from '../../shared/utils/hex';
import { type RecentWorkspaceEntry, WorkspaceStore } from '../stores/workspace.store';
import { DoubleShiftDetector, type DoubleShiftKeyInput } from './double-shift';

export type SearchCategory = 'files' | 'symbols' | 'text' | 'actions';
export type SearchEverywhereTab = 'all' | SearchCategory;

export interface SearchCandidate {
  id: string;
  category: SearchCategory;
  title: string;
  subtitle?: string;
  path?: string;
  address?: number;
  line?: number;
  shortcut?: string;
  baseScore?: number;
  onSelect?: () => void | Promise<void>;
}

export interface SearchResultItem extends SearchCandidate {
  score: number;
  matchIndices: number[];
}

export type SearchProviderFn = (query: string, tab: SearchEverywhereTab) => readonly SearchCandidate[];

export type SearchJumpTarget =
  | { kind: 'address'; address: number; normalized: string }
  | { kind: 'line'; line: number; fileFilter: string };

export interface SearchJumpHandlers {
  onAddress?: (address: number) => void | Promise<void>;
  onLine?: (line: number, filePath?: string) => void | Promise<void>;
  onWorkspace?: (ws: RecentWorkspaceEntry) => void | Promise<void>;
}

const RECENT_SEARCH_KEY = 'ra8.search.recent.v1';
const MAX_RECENT_QUERIES = 10;
const MAX_SEARCH_RESULTS = 50;

/** Scores `query` as a fuzzy subsequence against `candidate`, returning highlight spans. */
export function scoreFuzzyMatch(
  query: string,
  candidate: string
): { score: number; matchIndices: number[] } | null {
  const q = query.trim().toLowerCase();
  if (!q) return { score: 0, matchIndices: [] };
  const text = candidate.toLowerCase();
  const indices: number[] = [];
  let qi = 0;
  let score = 0;
  let prevMatch = -2;

  for (let i = 0; i < text.length && qi < q.length; i++) {
    if (text[i] !== q[qi]) continue;
    indices.push(i);
    score += 10;
    if (i === prevMatch + 1) score += 15;
    if (i === 0 || '/_.- '.includes(candidate[i - 1] ?? '')) score += 12;
    if (candidate[i] !== text[i] && i > 0 && candidate[i - 1] === text[i - 1]) score += 8;
    prevMatch = i;
    qi += 1;
  }

  if (qi !== q.length) return null;
  if (text.startsWith(q)) score += 30;
  if (text === q) score += 50;
  score -= Math.max(0, candidate.length - q.length) * 0.25;
  return { score, matchIndices: indices };
}

/** Parses `0x<addr>`, `:<line>`, or `<file>:<line>` quick-jump expressions. */
export function parseSearchJumpTarget(rawQuery: string): SearchJumpTarget | null {
  const clean = rawQuery.trim();
  if (!clean) return null;

  if (/^0x[0-9a-fA-F_]+$/i.test(clean)) {
    const parsed = Number.parseInt(clean.slice(2).replace(/_/g, ''), 16);
    if (Number.isFinite(parsed)) {
      const address = parsed >>> 0;
      return { kind: 'address', address, normalized: formatHex32(address) };
    }
  }

  const lineOnly = /^:(\d+)$/.exec(clean);
  if (lineOnly?.[1]) {
    const line = Math.max(1, Number.parseInt(lineOnly[1], 10));
    return { kind: 'line', line, fileFilter: '' };
  }

  const fileLine = /^(.+):(\d+)$/.exec(clean);
  if (fileLine?.[1] && fileLine[2]) {
    const line = Math.max(1, Number.parseInt(fileLine[2], 10));
    return { kind: 'line', line, fileFilter: fileLine[1].trim() };
  }

  return null;
}

@Injectable({ providedIn: 'root' })
export class SearchEverywhereStore {
  private readonly workspace = inject(WorkspaceStore);
  private readonly providers = signal<Array<{ id: string; fn: SearchProviderFn }>>([]);
  private readonly jumpHandlers = signal<SearchJumpHandlers>({});
  private readonly detector = new DoubleShiftDetector({
    onTrigger: () => this.openSearch(),
  });

  public readonly open = signal<boolean>(false);
  public readonly query = signal<string>('');
  public readonly activeTab = signal<SearchEverywhereTab>('all');
  public readonly selectedIndex = signal<number>(0);
  public readonly recentQueries = signal<string[]>(this.loadRecentQueries());
  public readonly lastError = signal<string | null>(null);

  public readonly results = computed<SearchResultItem[]>(() => {
    const rawQuery = this.query();
    const tab = this.activeTab();
    const jump = parseSearchJumpTarget(rawQuery);
    const effectiveQuery = jump?.kind === 'line' ? jump.fileFilter : rawQuery.trim();

    const candidates = this.collectCandidates(rawQuery, tab, jump);
    const scored: SearchResultItem[] = [];

    for (const item of candidates) {
      if (tab !== 'all' && item.category !== tab) continue;
      if (!effectiveQuery) {
        scored.push({ ...item, score: item.baseScore ?? 0, matchIndices: [] });
        continue;
      }
      const match = scoreFuzzyMatch(effectiveQuery, item.title);
      if (match) {
        scored.push({
          ...item,
          line: jump?.kind === 'line' && item.category === 'files' ? jump.line : item.line,
          score: match.score + (item.baseScore ?? 0),
          matchIndices: match.matchIndices,
        });
      } else if (item.subtitle && scoreFuzzyMatch(effectiveQuery, item.subtitle)) {
        scored.push({
          ...item,
          line: jump?.kind === 'line' && item.category === 'files' ? jump.line : item.line,
          score: 5 + (item.baseScore ?? 0),
          matchIndices: [],
        });
      }
    }

    scored.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));
    return scored.slice(0, MAX_SEARCH_RESULTS);
  });

  public readonly selectedResult = computed<SearchResultItem | null>(() => {
    const list = this.results();
    if (list.length === 0) return null;
    const idx = Math.max(0, Math.min(list.length - 1, this.selectedIndex()));
    return list[idx] ?? null;
  });

  /** Opens the Search Everywhere modal, optionally selecting a tab and prefilling a query. */
  public openSearch(tab: SearchEverywhereTab = 'all', initialQuery = ''): void {
    this.activeTab.set(tab);
    this.query.set(initialQuery);
    this.selectedIndex.set(0);
    this.open.set(true);
  }

  /** Closes the Search Everywhere modal and resets double-Shift tap state. */
  public closeSearch(): void {
    this.open.set(false);
    this.detector.reset();
  }

  /** Updates the search query and resets selection to the top match. */
  public setQuery(next: string): void {
    this.query.set(next);
    this.selectedIndex.set(0);
  }

  /** Switches the active Search Everywhere category tab. */
  public setTab(tab: SearchEverywhereTab): void {
    this.activeTab.set(tab);
    this.selectedIndex.set(0);
  }

  /** Moves the active result highlight index by `delta`, wrapping within bounds. */
  public moveSelection(delta: number): void {
    const len = this.results().length;
    if (len === 0) {
      this.selectedIndex.set(0);
      return;
    }
    this.selectedIndex.update((cur) => (((cur + delta) % len) + len) % len);
  }

  /** Registers a pluggable search result provider and returns an unregister callback. */
  public registerProvider(id: string, fn: SearchProviderFn): () => void {
    this.providers.update((list) => [...list.filter((p) => p.id !== id), { id, fn }]);
    return () => {
      this.providers.update((list) => list.filter((p) => p.id !== id));
    };
  }

  /** Registers callbacks used when executing parsed `0x...` address or `:line` jump results. */
  public registerJumpHandlers(handlers: SearchJumpHandlers): void {
    this.jumpHandlers.update((prev) => ({ ...prev, ...handlers }));
  }

  /** Executes the given (or currently selected) result item and persists non-empty queries. */
  public async executeResult(item: SearchResultItem | null = this.selectedResult()): Promise<boolean> {
    if (!item) return false;
    const trimmed = this.query().trim();
    if (trimmed) this.recordRecentQuery(trimmed);
    this.closeSearch();
    await item.onSelect?.();
    return true;
  }

  /** Forwards a global keydown event to the standalone `Shift+Shift` detector. */
  public handleWindowKeyDown(event: DoubleShiftKeyInput): void {
    this.detector.onKeyDown(event);
  }

  /** Forwards a global keyup event to the `Shift+Shift` detector, opening Search Everywhere on trigger. */
  public handleWindowKeyUp(event: DoubleShiftKeyInput): boolean {
    return this.detector.onKeyUp(event);
  }

  /** Resets the double-Shift detector state (e.g., on window blur). */
  public resetDoubleShift(): void {
    this.detector.reset();
  }

  /** Clears persisted recent Search Everywhere queries. */
  public clearRecentQueries(): void {
    this.recentQueries.set([]);
    this.saveRecentQueries([]);
  }

  private collectCandidates(
    rawQuery: string,
    tab: SearchEverywhereTab,
    jump: SearchJumpTarget | null
  ): SearchCandidate[] {
    const out: SearchCandidate[] = [];
    if (jump?.kind === 'address') {
      const handler = this.jumpHandlers().onAddress;
      out.push({
        id: `jump:addr:${jump.normalized}`,
        category: 'actions',
        title: `Jump to address ${jump.normalized}`,
        subtitle: 'Memory / Disassembly address jump',
        address: jump.address,
        baseScore: 1000,
        onSelect: handler ? () => handler(jump.address) : undefined,
      });
    } else if (jump?.kind === 'line' && !jump.fileFilter) {
      const handler = this.jumpHandlers().onLine;
      out.push({
        id: `jump:line:${jump.line}`,
        category: 'actions',
        title: `Go to line ${jump.line}`,
        subtitle: 'Active source line jump',
        line: jump.line,
        baseScore: 1000,
        onSelect: handler ? () => handler(jump.line) : undefined,
      });
    }

    out.push(...this.collectWorkspaceCandidates());
    for (const provider of this.providers()) {
      out.push(...provider.fn(rawQuery, tab));
    }
    return out;
  }

  private collectWorkspaceCandidates(): SearchCandidate[] {
    const out: SearchCandidate[] = [];
    const onWorkspace = this.jumpHandlers().onWorkspace;
    for (const ws of this.workspace.recentWorkspaces()) {
      out.push({
        id: `workspace:${ws.id}`,
        category: 'files',
        title: ws.name,
        subtitle: ws.path || ws.wsUrl,
        path: ws.path,
        baseScore: ws.pinned ? 20 : 10,
        onSelect: onWorkspace ? () => onWorkspace(ws) : undefined,
      });
    }
    const page = this.workspace.workspacePage();
    if (page) {
      for (const entry of page.entries) {
        out.push({
          id: `ws-entry:${entry.name}`,
          category: 'files',
          title: entry.name,
          subtitle: entry.kind,
          path: entry.name,
          baseScore: 15,
        });
      }
    }
    return out;
  }

  private recordRecentQuery(query: string): void {
    this.recentQueries.update((prev) => {
      const next = [query, ...prev.filter((q) => q !== query)].slice(0, MAX_RECENT_QUERIES);
      this.saveRecentQueries(next);
      return next;
    });
  }

  private loadRecentQueries(): string[] {
    if (typeof localStorage === 'undefined') return [];
    try {
      const raw = localStorage.getItem(RECENT_SEARCH_KEY);
      if (!raw) return [];
      const parsed: unknown = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === 'string') : [];
    } catch (err) {
      this.lastError.set(`Recent search load failed: ${err instanceof Error ? err.message : String(err)}`);
      return [];
    }
  }

  private saveRecentQueries(queries: readonly string[]): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(RECENT_SEARCH_KEY, JSON.stringify(queries));
    } catch (err) {
      this.lastError.set(`Recent search save failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
