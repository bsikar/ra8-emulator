import { ChangeDetectionStrategy, Component, effect, inject, signal } from '@angular/core';
import { CommandInputComponent } from '../shared/ui/command-input.component';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { CommandModeStore, type ResolvedCommand } from './command-mode.store';

@Component({
  selector: 'app-command-palette',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [CommandInputComponent, SectionKickerComponent],
  template: `
    @if (cmdMode.paletteOpen()) {
      <div class="palette-backdrop" (click)="cmdMode.closeOverlays()">
        <div
          class="palette-sheet"
          role="dialog"
          aria-modal="true"
          aria-label="Command mode"
          data-testid="command-palette"
          (click)="$event.stopPropagation()"
          (keydown)="onListKey($event)"
        >
          <div class="palette-head">
            <app-section-kicker label="COMMAND MODE" />
            <button type="button" class="esc-hint es-kbd" data-allow-11px (click)="cmdMode.closeOverlays()">
              Esc
            </button>
          </div>
          <app-command-input
            [value]="cmdMode.query()"
            (valueChange)="onQueryChange($event)"
            [autoFocus]="true"
            placeholder="Type a command or route..."
            ariaLabel="Command palette filter"
            testId="command-palette-input"
            (submitted)="runSelected()"
          />
          <div class="palette-list" role="listbox" aria-label="Available commands">
            @for (item of cmdMode.filteredCommands(); track item.action.id; let idx = $index) {
              <button
                type="button"
                role="option"
                class="palette-row"
                [class.is-selected]="idx === selectedIndex()"
                [disabled]="!item.enabled"
                [attr.aria-selected]="idx === selectedIndex()"
                [attr.data-command-id]="item.action.id"
                (mouseenter)="selectedIndex.set(idx)"
                (click)="runItem(item)"
              >
                <span class="row-label">{{ item.action.label }}</span>
                <span class="row-meta">
                  <span class="row-cat">{{ item.action.category }}</span>
                  @if (item.shortcutLabel) {
                    <kbd class="row-kbd" data-allow-11px>{{ item.shortcutLabel }}</kbd>
                  }
                </span>
              </button>
            } @empty {
              <div class="palette-empty">No matching commands.</div>
            }
          </div>
        </div>
      </div>
    }
  `,
  styles: [
    `
      .palette-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(11, 14, 21, 0.72);
        backdrop-filter: blur(8px);
        display: flex;
        justify-content: center;
        align-items: flex-start;
        padding-top: 76px;
        z-index: 70;
      }
      .palette-sheet {
        width: min(560px, calc(100vw - 32px));
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        padding: 16px 20px;
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .palette-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
      }
      .esc-hint {
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-sm);
        background: var(--es-interactive);
        color: var(--es-text-muted);
        font-family: var(--font-mono);
        font-size: 11px;
        padding: 2px 6px;
        cursor: pointer;
      }
      .palette-list {
        max-height: 320px;
        overflow-y: auto;
        display: flex;
        flex-direction: column;
      }
      .palette-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        width: 100%;
        min-height: 36px;
        padding: 6px 8px;
        border: 0;
        border-left: 2px solid transparent;
        border-bottom: 1px solid var(--es-divider);
        background: transparent;
        color: var(--es-text-secondary);
        font-family: var(--font-sans);
        font-size: 13px;
        text-align: left;
        cursor: pointer;
      }
      .palette-row:last-child {
        border-bottom: 0;
      }
      .palette-row.is-selected:not(:disabled),
      .palette-row:hover:not(:disabled) {
        background: var(--es-interactive);
        border-left-color: var(--es-signal-cursor);
        color: var(--es-text-primary);
      }
      .palette-row:disabled {
        opacity: 0.4;
        cursor: not-allowed;
      }
      .row-meta {
        display: inline-flex;
        align-items: center;
        gap: 10px;
      }
      .row-cat {
        font-size: 12px;
        font-weight: 300;
        color: var(--es-text-muted);
      }
      .row-kbd {
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--es-text-muted);
        background: var(--es-chrome);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-sm);
        padding: 1px 6px;
      }
      .palette-empty {
        padding: 16px 8px;
        font-size: 12px;
        color: var(--es-text-muted);
      }
    `,
  ],
})
export class CommandPaletteComponent {
  protected readonly cmdMode = inject(CommandModeStore);
  protected readonly selectedIndex = signal<number>(0);

  constructor() {
    effect(() => {
      if (this.cmdMode.paletteOpen()) {
        this.selectedIndex.set(0);
      }
    });
  }

  protected onQueryChange(val: string): void {
    this.cmdMode.query.set(val);
    this.selectedIndex.set(0);
  }

  protected runItem(item: ResolvedCommand): void {
    this.cmdMode.execute(item);
  }

  protected runSelected(): void {
    const items = this.cmdMode.filteredCommands();
    const candidate = items[this.selectedIndex()] ?? items.find((i) => i.enabled);
    if (candidate) this.cmdMode.execute(candidate);
  }

  protected onListKey(event: KeyboardEvent): void {
    const items = this.cmdMode.filteredCommands();
    if (items.length === 0) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.selectedIndex.update((i) => (i + 1) % items.length);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.selectedIndex.update((i) => (i - 1 + items.length) % items.length);
    }
  }
}
