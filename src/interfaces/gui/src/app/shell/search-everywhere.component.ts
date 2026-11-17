import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  effect,
  inject,
  viewChild,
} from '@angular/core';
import {
  type SearchEverywhereTab,
  SearchEverywhereStore,
  type SearchResultItem,
} from '../core/search/search-everywhere.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { type TextHighlightSegment, splitHighlightSegments } from './search-highlight';

interface TabOption {
  id: SearchEverywhereTab;
  label: string;
}

const SEARCH_TABS: readonly TabOption[] = [
  { id: 'all', label: 'All' },
  { id: 'files', label: 'Files' },
  { id: 'symbols', label: 'Symbols' },
  { id: 'text', label: 'Text' },
  { id: 'actions', label: 'Actions' },
];

@Component({
  selector: 'app-search-everywhere',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  styleUrl: './search-everywhere.component.css',
  template: `
    @if (search.open()) {
      <div class="search-backdrop" (click)="search.closeSearch()">
        <div
          class="search-sheet"
          role="dialog"
          aria-modal="true"
          aria-label="Search Everywhere"
          data-testid="search-everywhere-dialog"
          (click)="$event.stopPropagation()"
          (keydown)="onDialogKeyDown($event)"
        >
          <div class="search-head">
            <app-section-kicker label="SEARCH EVERYWHERE" />
            <div class="head-hints">
              <kbd class="esc-hint" data-allow-11px>Shift+Shift</kbd>
              <button type="button" class="esc-hint" data-allow-11px (click)="search.closeSearch()">Esc</button>
            </div>
          </div>

          <div class="tab-strip" role="tablist" aria-label="Search categories">
            @for (tab of tabs; track tab.id) {
              <button
                type="button"
                role="tab"
                class="tab-btn"
                [class.is-active]="tab.id === search.activeTab()"
                [attr.aria-selected]="tab.id === search.activeTab()"
                [attr.data-testid]="'search-everywhere-tab-' + tab.id"
                (click)="search.setTab(tab.id)"
              >
                {{ tab.label }}
              </button>
            }
          </div>

          <label class="search-input-wrap">
            <svg class="search-glyph" width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.65" />
              <path d="m20 20-3.5-3.5" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" />
            </svg>
            <input
              #searchInputEl
              type="text"
              class="search-input"
              data-testid="search-everywhere-input"
              aria-label="Search Everywhere query"
              placeholder="Search files, symbols, 0x<address>, :line, or actions..."
              [value]="search.query()"
              (input)="onQueryInput($event)"
            />
          </label>

          @if (search.query().trim().length === 0 && search.recentQueries().length > 0) {
            <div class="recent-row" data-testid="search-everywhere-recent">
              <span class="es-kicker">RECENT</span>
              <div class="recent-chips">
                @for (q of search.recentQueries(); track q) {
                  <button type="button" class="recent-chip" (click)="search.setQuery(q)">{{ q }}</button>
                }
              </div>
              <button type="button" class="es-ghost-link" (click)="search.clearRecentQueries()">Clear</button>
            </div>
          }

          <div class="result-list" role="listbox" aria-label="Search results">
            @for (item of search.results(); track item.id; let idx = $index) {
              <button
                type="button"
                role="option"
                class="result-row"
                [class.is-selected]="idx === search.selectedIndex()"
                [attr.aria-selected]="idx === search.selectedIndex()"
                [attr.data-testid]="'search-everywhere-row-' + item.id"
                (mouseenter)="search.selectedIndex.set(idx)"
                (click)="runItem(item)"
              >
                <span class="result-main">
                  <span class="result-title">
                    @for (seg of titleSegments(item); track $index) {
                      @if (seg.matched) {
                        <mark class="fuzzy-hit">{{ seg.text }}</mark>
                      } @else {
                        <span>{{ seg.text }}</span>
                      }
                    }
                  </span>
                  @if (item.subtitle) {
                    <span class="es-meta result-sub">· {{ item.subtitle }}</span>
                  }
                </span>
                <span class="result-meta">
                  <span class="result-cat mono">{{ item.category }}</span>
                  @if (item.shortcut) {
                    <kbd class="esc-hint" data-allow-11px>{{ item.shortcut }}</kbd>
                  }
                </span>
              </button>
            } @empty {
              <div class="search-empty">
                {{
                  search.query().trim()
                    ? 'No matching files, symbols, or actions.'
                    : 'Type a symbol, file name, 0x20000000 address, or :line jump.'
                }}
              </div>
            }
          </div>
        </div>
      </div>
    }
  `,
})
export class SearchEverywhereComponent {
  protected readonly search = inject(SearchEverywhereStore);
  protected readonly tabs = SEARCH_TABS;
  private readonly inputEl = viewChild<ElementRef<HTMLInputElement>>('searchInputEl');

  constructor() {
    effect(() => {
      if (this.search.open()) {
        queueMicrotask(() => this.inputEl()?.nativeElement.focus());
      }
    });
  }

  protected titleSegments(item: SearchResultItem): TextHighlightSegment[] {
    return splitHighlightSegments(item.title, item.matchIndices);
  }

  protected onQueryInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.search.setQuery(target.value);
    }
  }

  protected runItem(item: SearchResultItem): void {
    void this.search.executeResult(item);
  }

  protected onDialogKeyDown(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      this.search.closeSearch();
      return;
    }
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.search.moveSelection(1);
      return;
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.search.moveSelection(-1);
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      void this.search.executeResult();
      return;
    }
    if (event.key === 'Tab') {
      event.preventDefault();
      const idx = this.tabs.findIndex((t) => t.id === this.search.activeTab());
      const step = event.shiftKey ? -1 : 1;
      const next = this.tabs[(idx + step + this.tabs.length) % this.tabs.length];
      if (next) this.search.setTab(next.id);
    }
  }
}
