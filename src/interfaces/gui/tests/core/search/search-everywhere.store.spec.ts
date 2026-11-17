import { TestBed } from '@angular/core/testing';
import {
  SearchEverywhereStore,
  parseSearchJumpTarget,
  scoreFuzzyMatch,
} from '../../../src/app/core/search/search-everywhere.store';
import { WorkspaceStore } from '../../../src/app/core/stores/workspace.store';

describe('SearchEverywhereStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('scores fuzzy subsequences with matchIndices spans and parses jump targets', () => {
    const strong = scoreFuzzyMatch('npu', 'npu_driver.c');
    const weak = scoreFuzzyMatch('npu', 'main_app_run.c');
    expect(strong).not.toBeNull();
    expect(weak).not.toBeNull();
    expect(strong!.matchIndices).toEqual([0, 1, 2]);
    expect(strong!.score).toBeGreaterThan(weak!.score);
    expect(scoreFuzzyMatch('xyz', 'main.c')).toBeNull();

    expect(parseSearchJumpTarget('0x2000_0100')).toEqual({
      kind: 'address',
      address: 0x2000_0100,
      normalized: '0x20000100',
    });
    expect(parseSearchJumpTarget(':142')).toEqual({ kind: 'line', line: 142, fileFilter: '' });
    expect(parseSearchJumpTarget('main.c:42')).toEqual({
      kind: 'line',
      line: 42,
      fileFilter: 'main.c',
    });
  });

  it('opens on clean Shift+Shift, ignores Shift+A, and routes Workspace + provider results', async () => {
    TestBed.configureTestingModule({});
    const workspace = TestBed.inject(WorkspaceStore);
    const search = TestBed.inject(SearchEverywhereStore);

    workspace.recordRecentWorkspace({
      id: 'ws-ra8',
      name: 'RA8D2 Blink',
      path: '/work/blink.elf',
      wsUrl: 'ws://127.0.0.1:4567',
      pinned: true,
    });

    const jumped: string[] = [];
    search.registerJumpHandlers({
      onAddress: (addr) => {
        jumped.push(`addr:0x${addr.toString(16)}`);
      },
      onLine: (line) => {
        jumped.push(`line:${line}`);
      },
    });
    const unreg = search.registerProvider('symbols', () => [
      { id: 'sym-main', category: 'symbols', title: 'main_loop', subtitle: '0x02000100' },
      { id: 'act-ext', category: 'actions', title: 'Open Extensions', shortcut: 'Ctrl+Shift+X' },
    ]);

    // Shift+A must NOT open Search Everywhere
    search.handleWindowKeyDown({ key: 'Shift' });
    search.handleWindowKeyDown({ key: 'A', shiftKey: true });
    search.handleWindowKeyUp({ key: 'A' });
    search.handleWindowKeyUp({ key: 'Shift' });
    expect(search.open()).toBe(false);

    // Two standalone Shift taps open Search Everywhere
    search.handleWindowKeyDown({ key: 'Shift' });
    search.handleWindowKeyUp({ key: 'Shift' });
    search.handleWindowKeyDown({ key: 'Shift' });
    expect(search.handleWindowKeyUp({ key: 'Shift' })).toBe(true);
    expect(search.open()).toBe(true);

    search.setTab('symbols');
    search.setQuery('mloop');
    expect(search.results().map((r) => r.id)).toEqual(['sym-main']);

    search.setTab('all');
    search.setQuery('0x02000100');
    await search.executeResult();
    expect(jumped).toEqual(['addr:0x2000100']);
    expect(search.recentQueries()).toEqual(['0x02000100']);
    expect(search.open()).toBe(false);

    search.openSearch('all', ':88');
    await search.executeResult();
    expect(jumped).toEqual(['addr:0x2000100', 'line:88']);

    unreg();
  });
});
