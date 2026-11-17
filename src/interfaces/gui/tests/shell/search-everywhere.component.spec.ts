import { TestBed } from '@angular/core/testing';
import { SearchEverywhereStore } from '../../src/app/core/search/search-everywhere.store';
import { WorkspaceStore } from '../../src/app/core/stores/workspace.store';
import { SearchEverywhereComponent } from '../../src/app/shell/search-everywhere.component';

describe('SearchEverywhereComponent', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('opens on double-Shift, rejects Shift+A, renders tabs & fuzzy highlights, and supports 0x/line jumps', async () => {
    TestBed.configureTestingModule({});
    const workspace = TestBed.inject(WorkspaceStore);
    workspace.recordRecentWorkspace({
      id: 'ws-alpha',
      name: 'Alpha Blink Firmware',
      path: '~/work/alpha',
      wsUrl: 'ws://127.0.0.1:4567',
      pinned: true,
    });
    const store = TestBed.inject(SearchEverywhereStore);

    // Shift+A must NOT open Search Everywhere
    store.handleWindowKeyDown({ key: 'Shift' });
    store.handleWindowKeyDown({ key: 'A', shiftKey: true });
    store.handleWindowKeyUp({ key: 'A', shiftKey: true });
    store.handleWindowKeyUp({ key: 'Shift' });
    expect(store.open()).toBe(false);

    // Clean Shift+Shift opens Search Everywhere
    store.handleWindowKeyDown({ key: 'Shift' });
    store.handleWindowKeyUp({ key: 'Shift' });
    store.handleWindowKeyDown({ key: 'Shift' });
    store.handleWindowKeyUp({ key: 'Shift' });
    expect(store.open()).toBe(true);

    const fixture = TestBed.createComponent(SearchEverywhereComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="search-everywhere-dialog"]')).toBeTruthy();
    for (const tab of ['all', 'files', 'symbols', 'text', 'actions']) {
      expect(el.querySelector(`[data-testid="search-everywhere-tab-${tab}"]`)).toBeTruthy();
    }

    const input = el.querySelector('[data-testid="search-everywhere-input"]') as HTMLInputElement;
    input.value = 'alpha';
    input.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    expect(el.querySelectorAll('mark.fuzzy-hit').length).toBeGreaterThan(0);

    input.value = '0x20000400';
    input.dispatchEvent(new Event('input'));
    await fixture.whenStable();
    expect(el.textContent).toContain('Jump to address 0x20000400');

    input.value = ':42';
    input.dispatchEvent(new Event('input'));
    await fixture.whenStable();
    expect(el.textContent).toContain('Go to line 42');
  });
});
