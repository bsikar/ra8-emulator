import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { DebugStore } from '../../core/stores/debug.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { type EvaluatedLocal } from '../../shared/utils/dwarf-eval';
import { evaluateWatchExpressions } from './debug-view';

@Component({
  selector: 'app-debug-locals-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="locals-pane">
      <div class="pane-head">
        <app-section-kicker label="LOCALS & WATCH" />
        <div class="head-actions">
          @if (debug.canUndoWrite()) {
            <button
              type="button"
              class="mini-btn"
              data-testid="debug-undo-write-btn"
              [disabled]="rpc.observeOnly()"
              (click)="debug.undoWrite()"
            >
              Undo Write
            </button>
          }
          <form class="watch-form" (submit)="onAddWatch($event)">
            <input
              type="text"
              class="watch-input mono"
              data-testid="debug-watch-input"
              [value]="watchDraft()"
              (input)="onWatchInput($event)"
              placeholder="+ Watch"
            />
            <button type="submit" class="mini-btn" data-testid="debug-watch-add-btn">Add</button>
          </form>
        </div>
      </div>

      <div class="rows">
        @for (local of debug.locals(); track local.name) {
          <div class="var-row" [attr.data-testid]="'debug-local-' + local.name">
            <span class="var-name mono ellipsis">{{ local.name }}</span>
            <span class="var-type es-meta ellipsis">{{ local.typeName }}</span>
            <span class="var-where es-meta mono ellipsis">{{ local.locationLabel }}</span>
            @if (editingLocal() === local.name) {
              <form class="inline-edit" (submit)="commitLocal($event, local.name)">
                <input
                  type="text"
                  class="edit-input mono"
                  data-testid="debug-local-edit-input"
                  [value]="editDraft()"
                  (input)="onEditInput($event)"
                  aria-label="Edit local variable value"
                />
                <button type="submit" class="mini-btn" data-testid="debug-local-save-btn">Set</button>
                <button type="button" class="mini-btn" (click)="editingLocal.set(null)">Esc</button>
              </form>
            } @else if (isWritable(local)) {
              <button
                type="button"
                class="val-btn mono"
                [attr.data-testid]="'debug-local-val-' + local.name"
                (click)="beginEdit(local)"
              >
                {{ local.valueHex }}{{ local.valueDec ? ' (' + local.valueDec + ')' : '' }}
              </button>
            } @else {
              <span class="ro-val mono" [title]="readOnlyReason(local)">
                {{ local.valueHex }} · read-only
              </span>
            }
          </div>
        }

        @for (w of evaluatedWatches(); track w.expr) {
          <div class="var-row" [attr.data-testid]="'debug-watch-row-' + w.expr">
            <span class="var-name mono ellipsis">{{ w.expr }}</span>
            <span class="var-type es-meta ellipsis">{{ w.detail }}</span>
            <span class="var-val mono">{{ w.valueHex }}</span>
            <button type="button" class="rm-btn" (click)="debug.removeWatchExpression(w.expr)">×</button>
          </div>
        }

        @if (debug.locals().length === 0 && evaluatedWatches().length === 0) {
          <p class="es-meta note">No DWARF locals at current frame.</p>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .locals-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; }
      .pane-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); flex-wrap: wrap; }
      .head-actions, .watch-form, .inline-edit { display: inline-flex; align-items: center; gap: 6px; }
      .watch-input, .edit-input { background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; width: 96px; padding: 2px 4px; }
      .mini-btn, .val-btn, .rm-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; cursor: pointer; }
      .val-btn { border-color: transparent; color: var(--es-text-primary); text-align: right; }
      .val-btn:hover { border-color: var(--es-border); background: var(--es-interactive); }
      .rm-btn { border: 0; color: var(--es-text-muted); }
      .rows { flex: 1; overflow: auto; padding: 4px 12px; }
      .var-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-height: 26px; border-bottom: 1px solid var(--es-divider); font-size: 12px; min-width: 0; }
      .var-name { color: var(--es-text-primary); min-width: 64px; }
      .var-type, .var-where { flex: 1; }
      .ro-val, .var-val { color: var(--es-text-muted); white-space: nowrap; }
      .ellipsis { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
      .note { margin: 8px 0; }
    `,
  ],
})
export class DebugLocalsPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly debug = inject(DebugStore);

  protected readonly watchDraft = signal<string>('');
  protected readonly editingLocal = signal<string | null>(null);
  protected readonly editDraft = signal<string>('');

  protected readonly evaluatedWatches = computed(() =>
    evaluateWatchExpressions(
      this.debug.watchExpressions(),
      this.debug.locals(),
      this.debug.registers(),
      this.debug.activeCore() === 1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols()
    )
  );

  protected isWritable(local: EvaluatedLocal): boolean {
    if (this.rpc.observeOnly()) return false;
    if (local.locationLabel === 'optimized out' || local.locationLabel.includes('unwound')) return false;
    return true;
  }

  protected readOnlyReason(local: EvaluatedLocal): string {
    if (this.rpc.observeOnly()) return 'Read-only in Observe mode';
    if (local.locationLabel.includes('unwound')) return 'Register local unavailable on unwound caller frame';
    return 'Optimized out by compiler';
  }

  protected onWatchInput(event: Event): void {
    this.watchDraft.set((event.target as HTMLInputElement).value);
  }

  protected onAddWatch(event: Event): void {
    event.preventDefault();
    this.debug.addWatchExpression(this.watchDraft());
    this.watchDraft.set('');
  }

  protected beginEdit(local: EvaluatedLocal): void {
    this.editingLocal.set(local.name);
    this.editDraft.set(local.valueDec || local.valueHex);
  }

  protected onEditInput(event: Event): void {
    this.editDraft.set((event.target as HTMLInputElement).value);
  }

  protected async commitLocal(event: Event, name: string): Promise<void> {
    event.preventDefault();
    const val = this.editDraft().trim();
    if (!val) return;
    await this.debug.setVar(name, val);
    this.editingLocal.set(null);
  }
}
