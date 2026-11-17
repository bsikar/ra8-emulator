import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import type { LaunchCommandItem, LaunchCommandSection } from './launch-commands';
import { LaunchIconComponent } from './launch-icons.component';

interface FlatCommandEntry {
  item: LaunchCommandItem;
  flatIndex: number;
}

interface IndexedCommandSection {
  group: string;
  entries: FlatCommandEntry[];
}

@Component({
  selector: 'app-launch-command-list',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [LaunchIconComponent],
  template: `
    <section class="index-card" aria-label="Launch command list" data-testid="launch-command-card">
      @for (section of indexedSections(); track section.group) {
        <div class="section-head">
          <span class="es-kicker">{{ section.group }}</span>
          <span class="es-kicker">SHORTCUT</span>
        </div>

        <div class="section-rows" role="listbox" [attr.aria-label]="section.group">
          @for (entry of section.entries; track entry.item.id) {
            <button
              type="button"
              role="option"
              class="cmd-row"
              [class.is-selected]="entry.flatIndex === selectedIndex()"
              [attr.aria-selected]="entry.flatIndex === selectedIndex()"
              [attr.data-testid]="'launch-cmd-' + entry.item.id"
              (mouseenter)="selectedChange.emit(entry.flatIndex)"
              (click)="execute.emit(entry.item)"
            >
              <span class="cmd-main">
                <app-launch-icon [name]="entry.item.icon" [size]="16" class="cmd-row-icon" />
                <span class="cmd-title">{{ entry.item.label }}</span>
                <span class="cmd-dot" aria-hidden="true">·</span>
                <span class="es-meta cmd-desc">{{ entry.item.description }}</span>
              </span>

              @if (entry.item.shortcut) {
                <kbd class="cmd-kbd es-kbd" data-allow-11px>{{ entry.item.shortcut }}</kbd>
              }
            </button>
          }
        </div>
      } @empty {
        <div class="empty-commands">
          <p class="es-meta">No launch commands match "{{ query() }}".</p>
        </div>
      }
    </section>
  `,
  styles: [
    `
      .index-card {
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        overflow: hidden;
      }
      .section-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 13px 22px 10px;
        border-bottom: 1px solid var(--es-divider);
      }
      .section-rows {
        display: flex;
        flex-direction: column;
      }
      .cmd-row {
        width: 100%;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        padding: 13px 22px;
        border: 0;
        border-left: 2px solid transparent;
        border-bottom: 1px solid var(--es-divider);
        background: transparent;
        color: var(--es-text-primary);
        text-align: left;
        cursor: pointer;
        transition: background 110ms ease, border-color 110ms ease;
      }
      .section-rows:last-child .cmd-row:last-child {
        border-bottom: 0;
      }
      .cmd-row.is-selected,
      .cmd-row:hover {
        background: var(--es-interactive);
        border-left-color: var(--es-signal-cursor);
      }
      .cmd-main {
        display: flex;
        align-items: center;
        gap: 8px;
        min-width: 0;
        flex: 1;
      }
      .cmd-row-icon {
        color: var(--es-text-muted);
      }
      .cmd-row.is-selected .cmd-row-icon,
      .cmd-row:hover .cmd-row-icon {
        color: var(--es-text-secondary);
      }
      .cmd-title {
        font-size: 14px;
        font-weight: 500;
        color: var(--es-text-primary);
        white-space: nowrap;
      }
      .cmd-dot {
        color: var(--es-text-muted);
      }
      .cmd-desc {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .cmd-kbd {
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--es-text-kicker);
        background: var(--es-chrome);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius);
        padding: 2px 8px;
        white-space: nowrap;
        flex-shrink: 0;
      }
      .empty-commands {
        padding: 24px 22px;
      }
      .empty-commands p {
        margin: 0;
      }
    `,
  ],
})
export class LaunchCommandListComponent {
  public readonly sections = input.required<readonly LaunchCommandSection[]>();
  public readonly selectedIndex = input<number>(0);
  public readonly query = input<string>('');
  public readonly selectedChange = output<number>();
  public readonly execute = output<LaunchCommandItem>();

  protected readonly indexedSections = computed<IndexedCommandSection[]>(() => {
    let idx = 0;
    return this.sections().map((section) => ({
      group: section.group,
      entries: section.items.map((item) => ({ item, flatIndex: idx++ })),
    }));
  });
}
