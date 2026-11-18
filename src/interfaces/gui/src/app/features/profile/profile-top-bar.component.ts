import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ALL_THREADS_FILTER, ProfileViewService } from './profile-view.service';
import type { TimelineCoreFilter } from './timeline-model';

@Component({
  selector: 'app-profile-top-bar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <header class="prof-bar" data-testid="profile-top-bar">
      <div class="bar-grp">
        <div class="seg-strip" role="group" aria-label="Core selector">
          <button
            type="button"
            class="seg-btn"
            [class.is-active]="view.coreFilter() === 'cpu0'"
            data-testid="profile-core-cpu0"
            (click)="setCore('cpu0')"
          >
            CPU0 · Cortex-M85
          </button>
          <button
            type="button"
            class="seg-btn"
            [class.is-active]="view.coreFilter() === 'cpu1'"
            [disabled]="!execution.cpu1Attached()"
            data-testid="profile-core-cpu1"
            (click)="setCore('cpu1')"
          >
            CPU1 · Cortex-M33
          </button>
          <button
            type="button"
            class="seg-btn"
            [class.is-active]="view.coreFilter() === 'both'"
            data-testid="profile-core-both"
            (click)="setCore('both')"
          >
            Both Cores
          </button>
        </div>

        <label class="thread-wrap">
          <span class="es-meta">Thread:</span>
          <select
            class="es-select mono"
            aria-label="Filter thread"
            data-testid="profile-thread-filter"
            [value]="view.threadFilter()"
            (change)="onThreadChange($event)"
          >
            <option [value]="allThreads">All ({{ view.threadOptions().length }})</option>
            @for (opt of view.threadOptions(); track opt.thread) {
              <option [value]="opt.thread">{{ opt.label }}</option>
            }
          </select>
        </label>
      </div>

      <div class="bar-grp">
        <span class="es-meta">Brushed Window:</span>
        <span class="mono win-val" data-testid="profile-brushed-indicator">{{ view.brushSummary() }}</span>
        <button
          type="button"
          class="ghost-act"
          data-testid="profile-full-run-btn"
          (click)="fullRun()"
        >
          Full Run
        </button>
      </div>

      <div class="bar-grp">
        <button
          type="button"
          class="tonal-act"
          data-testid="profile-export-folded-btn"
          [disabled]="!rpc.isConnected() && view.threadOptions().length === 0 && !hasFolded()"
          (click)="exportFolded()"
        >
          Export .folded
        </button>
        <button
          type="button"
          class="ghost-act"
          data-testid="profile-clear-btn"
          (click)="view.clearAll()"
        >
          Clear
        </button>
      </div>
    </header>
  `,
  styles: [
    `
      .prof-bar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
        padding: 6px 12px;
        border-bottom: 1px solid var(--es-border);
        background: var(--es-chrome);
        flex-wrap: wrap;
        font-size: 12px;
      }
      .bar-grp {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        flex-wrap: wrap;
        min-width: 0;
      }
      .seg-strip {
        display: inline-flex;
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius);
        overflow: hidden;
        background: var(--es-container);
      }
      .seg-btn {
        border: 0;
        border-bottom: 1px solid transparent;
        background: transparent;
        color: var(--es-text-muted);
        font-size: 12px;
        padding: 4px 10px;
        cursor: pointer;
        white-space: nowrap;
      }
      .seg-btn.is-active {
        background: var(--es-interactive);
        color: var(--es-text-primary);
        border-bottom-color: var(--es-signal-cursor);
      }
      .seg-btn:disabled {
        opacity: 0.4;
        cursor: not-allowed;
      }
      .thread-wrap {
        display: inline-flex;
        align-items: center;
        gap: 6px;
      }
      .es-select {
        background: transparent;
        color: var(--es-text-primary);
        border: 0;
        border-bottom: 1px solid var(--es-border);
        font-size: 12px;
        padding: 3px 6px;
      }
      .es-select option {
        background: var(--es-container);
        color: var(--es-text-primary);
      }
      .win-val {
        color: var(--es-text-primary);
        font-size: 12px;
      }
      .ghost-act {
        border: 0;
        background: transparent;
        color: var(--es-text-secondary);
        font-size: 12px;
        padding: 3px 6px;
        cursor: pointer;
      }
      .ghost-act:hover {
        color: var(--es-text-primary);
      }
      .tonal-act {
        height: 26px;
        padding: 0 10px;
        border: 1px solid var(--es-interactive-highest);
        border-radius: var(--es-radius);
        background: var(--es-interactive);
        color: var(--es-text-primary);
        font-size: 12px;
        cursor: pointer;
      }
      .tonal-act:disabled {
        opacity: 0.45;
        cursor: not-allowed;
      }
    `,
  ],
})
export class ProfileTopBarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly view = inject(ProfileViewService);
  protected readonly allThreads = ALL_THREADS_FILTER;

  protected hasFolded(): boolean {
    return this.view.brushSummary() !== 'Full Run (0 samples)';
  }

  protected setCore(filter: TimelineCoreFilter): void {
    void this.view.selectCoreFilter(filter);
  }

  protected onThreadChange(event: Event): void {
    const raw = (event.target as HTMLSelectElement).value;
    const parsed = Number.parseInt(raw, 10);
    void this.view.selectThreadFilter(Number.isFinite(parsed) ? parsed : ALL_THREADS_FILTER);
  }

  protected fullRun(): void {
    void this.view.resetToFullRun();
  }

  protected exportFolded(): void {
    void this.view.exportFolded();
  }
}
