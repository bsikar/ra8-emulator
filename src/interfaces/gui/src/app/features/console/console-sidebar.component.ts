import { ChangeDetectionStrategy, Component, computed, inject, input, output, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { ConsoleStore } from '../../core/stores/console.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatVirtualTime, parseHexAddress } from '../../shared/utils/hex';
import {
  type WatchTriggerRule,
  computeConsoleByteStats,
  resolveNearestElfSymbol,
} from './console-model';

@Component({
  selector: 'app-console-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <aside class="side-pane">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="STREAM TELEMETRY" />
          <button type="button" class="mini-btn" data-testid="console-reset-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="resetImage()">Reset Image</button>
        </div>
        <div class="kv-row"><span>RX Entries / Bytes</span><span class="mono">{{ stats().rxCount }} / {{ stats().rxBytes }} B</span></div>
        <div class="kv-row"><span>TX Entries / Bytes</span><span class="mono">{{ stats().txCount }} / {{ stats().txBytes }} B</span></div>
        <div class="kv-row"><span>Virtual Time</span><span class="mono">{{ virtualTime() }}</span></div>
        <div class="kv-row"><span>Channel Scope</span><span class="mono">{{ channelLabel() }}</span></div>
      </section>

      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="ELF SYMBOL DECODER" />
          <label class="toggle-lbl">
            <input type="checkbox" data-testid="console-symbol-toggle" [checked]="symbolDecoderEnabled()" (change)="onDecoderToggle($event)" />
            <span>Inline</span>
          </label>
        </div>
        <input type="text" class="es-input mono" data-testid="console-symbol-lookup" [value]="lookupDraft()" (input)="onLookupInput($event)" placeholder="Resolve hex address (0x02000000)" />
        <p class="es-meta mono note">{{ resolvedLookup() }}</p>
      </section>

      <section class="sec">
        <app-section-kicker label="WATCH TRIGGERS" />
        <form class="trigger-form" (submit)="onAddTrigger($event)">
          <input type="text" class="es-input mono" data-testid="console-trigger-input" [value]="patternDraft()" (input)="onPatternInput($event)" placeholder="Substring e.g. FAULT or ERROR" />
          <div class="trigger-opts">
            <label class="toggle-lbl">
              <input type="checkbox" data-testid="console-trigger-pause" [checked]="pauseOnMatch()" (change)="onPauseToggle($event)" />
              <span>Pause CPU</span>
            </label>
            <button type="submit" class="mini-btn" data-testid="console-trigger-add">Add Rule</button>
          </div>
        </form>

        @if (watchRules().length > 0) {
          @for (rule of watchRules(); track rule.id) {
            <div class="rule-row" [attr.data-testid]="'console-rule-' + rule.id">
              <span class="mono rule-pat">{{ rule.pattern }}</span>
              <span class="es-meta mono">{{ rule.pauseOnMatch ? 'Pause' : 'Count' }} · {{ rule.hits }}</span>
              <button type="button" class="rm-btn" (click)="removeRule.emit(rule.id)" aria-label="Remove trigger">×</button>
            </div>
          }
        } @else {
          <p class="es-meta note">No watch triggers configured.</p>
        }
      </section>
    </aside>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .side-pane { display: flex; flex-direction: column; height: 100%; overflow: auto; background: var(--es-canvas); }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 6px; min-width: 0; }
      .sec-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
      .kv-row, .rule-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 12px; color: var(--es-text-secondary); min-width: 0; }
      .rule-row { border-bottom: 1px solid var(--es-divider); padding: 3px 0; }
      .rule-pat { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--es-text-primary); }
      .toggle-lbl { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-secondary); }
      .es-input { width: 100%; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; min-width: 0; }
      .trigger-form { display: flex; flex-direction: column; gap: 6px; }
      .trigger-opts { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .rm-btn { border: 0; background: transparent; color: var(--es-text-muted); font-size: 13px; cursor: pointer; padding: 0 4px; }
      .note { margin: 0; }
    `,
  ],
})
export class ConsoleSidebarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly consoleStore = inject(ConsoleStore);
  protected readonly execution = inject(ExecutionStore);

  public readonly symbolDecoderEnabled = input<boolean>(true);
  public readonly watchRules = input<readonly WatchTriggerRule[]>([]);
  public readonly symbolDecoderChanged = output<boolean>();
  public readonly addRule = output<{ pattern: string; pauseOnMatch: boolean }>();
  public readonly removeRule = output<string>();

  protected readonly lookupDraft = signal<string>('');
  protected readonly patternDraft = signal<string>('');
  protected readonly pauseOnMatch = signal<boolean>(true);

  protected readonly stats = computed(() => computeConsoleByteStats(this.consoleStore.filteredEntries()));
  protected readonly virtualTime = computed(() => formatVirtualTime(this.execution.virtualTimeNs()));
  protected readonly channelLabel = computed(() =>
    this.consoleStore.selectedChannel() === 'all' ? 'All SCI channels' : `SCI${this.consoleStore.selectedChannel()}`
  );
  protected readonly resolvedLookup = computed(() => {
    const raw = this.lookupDraft().trim();
    if (!raw) return 'Enter a hex address to resolve ELF symbols.';
    const addr = parseHexAddress(raw);
    if (addr === null) return 'Invalid 32-bit hex address.';
    const syms = this.consoleStore.activeCore() === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols();
    return resolveNearestElfSymbol(addr, syms) ?? 'No matching ELF symbol within +/-4 KiB.';
  });

  protected onDecoderToggle(event: Event): void {
    this.symbolDecoderChanged.emit((event.target as HTMLInputElement).checked);
  }

  protected onLookupInput(event: Event): void {
    this.lookupDraft.set((event.target as HTMLInputElement).value);
  }

  protected onPatternInput(event: Event): void {
    this.patternDraft.set((event.target as HTMLInputElement).value);
  }

  protected onPauseToggle(event: Event): void {
    this.pauseOnMatch.set((event.target as HTMLInputElement).checked);
  }

  protected onAddTrigger(event: Event): void {
    event.preventDefault();
    const pattern = this.patternDraft().trim();
    if (!pattern) return;
    this.addRule.emit({ pattern, pauseOnMatch: this.pauseOnMatch() });
    this.patternDraft.set('');
  }

  protected resetImage(): void {
    void this.execution.resetImage();
  }
}
