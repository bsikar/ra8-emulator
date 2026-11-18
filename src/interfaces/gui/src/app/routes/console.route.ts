import { ChangeDetectionStrategy, Component, effect, inject, signal, untracked } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ConsoleStore } from '../core/stores/console.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { type WatchTriggerRule, evaluateWatchTriggers } from '../features/console/console-model';
import { ConsoleSidebarComponent } from '../features/console/console-sidebar.component';
import { ConsoleStreamComponent } from '../features/console/console-stream.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-console-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, ConsoleStreamComponent, ConsoleSidebarComponent],
  template: `
    <div class="console-shell">
      <app-split-pane primarySize="72%" persistKey="console-split" [minPrimaryPx]="420" [minSecondaryPx]="240">
        <app-console-stream pane-primary [symbolDecoderEnabled]="symbolDecoderEnabled()" />
        <app-console-sidebar
          pane-secondary
          [symbolDecoderEnabled]="symbolDecoderEnabled()"
          [watchRules]="watchRules()"
          (symbolDecoderChanged)="symbolDecoderEnabled.set($event)"
          (addRule)="onAddRule($event)"
          (removeRule)="onRemoveRule($event)"
        />
      </app-split-pane>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; }
      .console-shell { height: 100%; min-height: 0; min-width: 0; background: var(--es-canvas); }
    `,
  ],
})
export class ConsoleRouteComponent {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly consoleStore = inject(ConsoleStore);
  private readonly execution = inject(ExecutionStore);

  protected readonly symbolDecoderEnabled = signal<boolean>(true);
  protected readonly watchRules = signal<WatchTriggerRule[]>([]);
  private nextRuleId = 1;
  private lastEvaluatedId = 0;

  constructor() {
    effect(() => {
      const entries = this.consoleStore.entries();
      const latest = entries[entries.length - 1];
      if (!latest || latest.id <= this.lastEvaluatedId) return;
      const fresh = entries.filter((e) => e.id > this.lastEvaluatedId && !e.isInput);
      this.lastEvaluatedId = latest.id;
      if (fresh.length === 0) return;

      const currentRules = untracked(() => this.watchRules());
      if (currentRules.length === 0) return;
      let nextRules = currentRules;
      let pauseNeeded = false;
      for (const entry of fresh) {
        const res = evaluateWatchTriggers(entry.text, nextRules);
        nextRules = res.updated;
        if (res.shouldPause) pauseNeeded = true;
      }
      this.watchRules.set(nextRules);
      if (pauseNeeded && this.rpc.isConnected() && !this.rpc.observeOnly()) {
        void this.execution.pause();
      }
    });
  }

  protected onAddRule(evt: { pattern: string; pauseOnMatch: boolean }): void {
    const id = `r${this.nextRuleId++}`;
    this.watchRules.update((list) => [...list, { id, pattern: evt.pattern, pauseOnMatch: evt.pauseOnMatch, hits: 0 }]);
  }

  protected onRemoveRule(id: string): void {
    this.watchRules.update((list) => list.filter((item) => item.id !== id));
  }
}
