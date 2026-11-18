import { ChangeDetectionStrategy, Component, computed, effect, inject, input, output, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';

type DiffScopeFilter = 'all' | 'CPU0' | 'CPU1' | 'Memory' | 'Peripheral';

@Component({
  selector: 'app-rewind-diff-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="diff-pane">
      <div class="diff-head">
        <div class="grp">
          <app-section-kicker label="STATE DIFF" />
          <select class="es-select" aria-label="Diff scope filter" [value]="scopeFilter()" (change)="onScopeChange($event)">
            <option value="all">All scopes</option>
            <option value="CPU0">CPU0</option>
            <option value="CPU1">CPU1</option>
            <option value="Memory">Memory</option>
            <option value="Peripheral">Peripheral</option>
          </select>
        </div>

        <form class="grp" (submit)="onCompareSubmit($event)">
          <input type="text" class="es-input mono" data-testid="rewind-diff-a" [value]="pointADraft()" (input)="onPointAInput($event)" placeholder="Point A (0)" />
          <span class="es-meta">vs</span>
          <input type="text" class="es-input mono" data-testid="rewind-diff-b" [value]="pointBDraft()" (input)="onPointBInput($event)" placeholder="Point B (latest)" />
          <button type="submit" class="mini-btn" data-testid="rewind-diff-btn" [disabled]="!rpc.isConnected()">Compare</button>
        </form>
      </div>

      <div class="diff-table">
        @if (filteredRows().length > 0) {
          <div class="row hdr mono">
            <span>Entity · Scope</span>
            <span>Point A (Before)</span>
            <span>Point B (After · Delta)</span>
          </div>
          @for (row of filteredRows(); track row.scope + ':' + row.entity) {
            <div class="row mono" [attr.data-testid]="'rewind-diff-row-' + $index">
              <span class="col-ent">{{ row.entity }} · <span class="es-meta">{{ row.scope }}</span></span>
              <span class="col-before es-meta">{{ row.beforeVal }}</span>
              <span class="col-after">{{ row.afterVal }} <span class="es-meta">({{ row.delta }})</span></span>
            </div>
          }
        } @else {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'No state delta between Point A and Point B.' : 'Connect a session to compare checkpoints.' }}
          </p>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .diff-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .diff-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .grp { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .es-input { width: 108px; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 2px 4px; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .diff-table { flex: 1; min-height: 0; overflow: auto; padding: 6px 12px; font-size: 12px; }
      .row { display: grid; grid-template-columns: 1.2fr 1fr 1.2fr; gap: 10px; padding: 4px 0; border-bottom: 1px solid var(--es-divider); min-width: 0; }
      .row.hdr { color: var(--es-text-muted); border-bottom-color: var(--es-border); }
      .col-ent, .col-before, .col-after { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
      .note { margin: 8px 0; }
    `,
  ],
})
export class RewindDiffPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);

  public readonly pointA = input<string>('0');
  public readonly pointB = input<string>('latest');
  public readonly pointsChanged = output<{ pointA: string; pointB: string }>();

  protected readonly pointADraft = signal<string>('0');
  protected readonly pointBDraft = signal<string>('latest');
  protected readonly scopeFilter = signal<DiffScopeFilter>('all');

  protected readonly filteredRows = computed(() => {
    const scope = this.scopeFilter();
    const rows = this.rewind.diffRows();
    return scope === 'all' ? rows : rows.filter((r) => r.scope === scope);
  });

  constructor() {
    effect(() => {
      this.pointADraft.set(this.pointA());
      this.pointBDraft.set(this.pointB());
    });
  }

  protected onScopeChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'all' || val === 'CPU0' || val === 'CPU1' || val === 'Memory' || val === 'Peripheral') {
      this.scopeFilter.set(val);
    }
  }

  protected onPointAInput(event: Event): void {
    this.pointADraft.set((event.target as HTMLInputElement).value);
  }

  protected onPointBInput(event: Event): void {
    this.pointBDraft.set((event.target as HTMLInputElement).value);
  }

  protected async onCompareSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const a = this.pointADraft().trim() || '0';
    const b = this.pointBDraft().trim() || 'latest';
    this.pointsChanged.emit({ pointA: a, pointB: b });
    await this.rewind.compareDiff(a, b);
  }
}
