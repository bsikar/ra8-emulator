import { ChangeDetectionStrategy, Component, computed, inject, input, output, signal } from '@angular/core';
import { Core, type SourceLineResult } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { ConsoleStore } from '../../core/stores/console.store';
import { DebugStore } from '../../core/stores/debug.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatVirtualTime, parseHexAddress } from '../../shared/utils/hex';
import {
  type WatchTriggerAction,
  type WatchTriggerRule,
  computeConsoleByteStats,
  formatSourceLineSummary,
  formatTriggerActionLabel,
  resolveAddressDetail,
} from './console-model';

@Component({
  selector: 'app-console-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <aside class="side-pane">
      <section class="sec">
        <div class="sec-head">
          <app-section-kicker label="SERIAL & PROBE LINK" />
          <button
            type="button"
            class="mini-btn"
            data-testid="console-reset-btn"
            [disabled]="!rpc.isConnected() || rpc.observeOnly()"
            (click)="resetImage()"
          >
            Reset Image
          </button>
        </div>
        <div class="kv-row">
          <span>Session Link</span>
          <span class="mono val-ellipsis">{{ rpc.isConnected() ? rpc.serverUrl() : 'Offline' }}</span>
        </div>
        @if (execution.cpu1Attached()) {
          <div class="kv-row">
            <span>Target Core</span>
            <select class="es-select mono" aria-label="Decoder core" [value]="consoleStore.activeCore()" (change)="onCoreChange($event)">
              <option [value]="cpu0">CPU0</option>
              <option [value]="cpu1">CPU1</option>
            </select>
          </div>
        }
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
        <div class="kv-row">
          <span class="mono val-ellipsis">{{ activeElfName() ?? 'No ELF loaded' }}</span>
          <span class="es-meta">{{ activeElfDwarf() ? 'DWARF synced' : 'Symbol table' }}</span>
        </div>
        <div class="lookup-row">
          <input
            type="text"
            class="es-input mono"
            data-testid="console-symbol-lookup"
            [value]="lookupDraft()"
            (input)="onLookupInput($event)"
            placeholder="Resolve hex address (0x02000000)"
          />
          <button
            type="button"
            class="mini-btn"
            data-testid="console-source-line-btn"
            [disabled]="!rpc.isConnected()"
            (click)="lookupCurrentPcSource()"
          >
            PC Source
          </button>
        </div>
        <p class="es-meta mono note" data-testid="console-symbol-result">{{ resolvedLookup() }}</p>
        @if (sourceLineStatus()) {
          <p class="es-meta mono note" data-testid="console-source-line-out">{{ sourceLineStatus() }}</p>
        }
      </section>

      <section class="sec">
        <app-section-kicker label="WATCH TRIGGERS" />
        <form class="trigger-form" (submit)="onAddTrigger($event)">
          <input
            type="text"
            class="es-input mono"
            data-testid="console-trigger-input"
            [value]="patternDraft()"
            (input)="onPatternInput($event)"
            placeholder="Substring e.g. FAULT or ERROR"
          />
          <div class="trigger-opts">
            <div class="seg-group" role="group" aria-label="Trigger action">
              <button
                type="button"
                class="seg-tab"
                [class.is-active]="triggerAction() === 'alert_halt'"
                data-testid="console-trigger-action-halt"
                (click)="triggerAction.set('alert_halt')"
              >
                Alert + Halt
              </button>
              <button
                type="button"
                class="seg-tab"
                [class.is-active]="triggerAction() === 'marker'"
                data-testid="console-trigger-action-marker"
                (click)="triggerAction.set('marker')"
              >
                Marker
              </button>
            </div>
            <button type="submit" class="mini-btn" data-testid="console-trigger-add">Add Rule</button>
          </div>
        </form>

        @if (watchRules().length > 0) {
          @for (rule of watchRules(); track rule.id) {
            <div class="rule-row" [attr.data-testid]="'console-rule-' + rule.id">
              <span class="mono rule-pat">{{ rule.pattern }}</span>
              <span class="es-meta mono">{{ actionLabel(rule) }} · {{ rule.hits }}</span>
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
      .side-pane { display: flex; flex-direction: column; height: 100%; overflow: auto; background: var(--es-canvas); padding-bottom: 56px; }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 6px; min-width: 0; }
      .sec-head, .lookup-row, .trigger-opts { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
      .kv-row, .rule-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 12px; color: var(--es-text-secondary); min-width: 0; }
      .rule-row { border-bottom: 1px solid var(--es-divider); padding: 3px 0; }
      .rule-pat, .val-ellipsis { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--es-text-primary); }
      .val-ellipsis { text-align: right; max-width: 170px; }
      .toggle-lbl { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-secondary); }
      .es-input { flex: 1; width: 100%; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; min-width: 0; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .trigger-form { display: flex; flex-direction: column; gap: 6px; }
      .seg-group { display: inline-flex; align-items: center; gap: 6px; }
      .seg-tab { border: 0; border-bottom: 2px solid transparent; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 2px 4px; cursor: pointer; }
      .seg-tab.is-active { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; white-space: nowrap; }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .rm-btn { border: 0; background: transparent; color: var(--es-text-muted); font-size: 13px; cursor: pointer; padding: 0 4px; }
      .note { margin: 0; word-break: break-word; }
    `,
  ],
})
export class ConsoleSidebarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly consoleStore = inject(ConsoleStore);
  protected readonly debug = inject(DebugStore);
  protected readonly execution = inject(ExecutionStore);

  public readonly symbolDecoderEnabled = input<boolean>(true);
  public readonly watchRules = input<readonly WatchTriggerRule[]>([]);
  public readonly symbolDecoderChanged = output<boolean>();
  public readonly addRule = output<{ pattern: string; action: WatchTriggerAction; pauseOnMatch: boolean }>();
  public readonly removeRule = output<string>();

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly lookupDraft = signal<string>('');
  protected readonly patternDraft = signal<string>('');
  protected readonly triggerAction = signal<WatchTriggerAction>('alert_halt');
  protected readonly queriedSourceLine = signal<SourceLineResult | null>(null);

  protected readonly stats = computed(() => computeConsoleByteStats(this.consoleStore.filteredEntries()));
  protected readonly virtualTime = computed(() => formatVirtualTime(this.execution.virtualTimeNs()));
  protected readonly channelLabel = computed(() =>
    this.consoleStore.selectedChannel() === 'all' ? 'All SCI channels' : `CH${this.consoleStore.selectedChannel()}`
  );
  protected readonly activeElfName = computed(() =>
    this.consoleStore.activeCore() === Core.Cpu1 ? this.board.cpu1ElfName() : this.board.cpu0ElfName()
  );
  protected readonly activeElfDwarf = computed(() =>
    this.consoleStore.activeCore() === Core.Cpu1 ? this.board.cpu1HasDwarf() : this.board.cpu0HasDwarf()
  );
  protected readonly sourceLineStatus = computed(() => {
    const sl = this.queriedSourceLine() ?? this.debug.sourceLine();
    return sl ? formatSourceLineSummary(sl) : '';
  });

  protected readonly resolvedLookup = computed(() => {
    const raw = this.lookupDraft().trim();
    if (!raw) return 'Enter a hex address to resolve ELF symbols & file:line.';
    const addr = parseHexAddress(raw);
    if (addr === null) return 'Invalid 32-bit hex address.';
    const isCpu1 = this.consoleStore.activeCore() === Core.Cpu1;
    const syms = isCpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols();
    const bt = isCpu1 ? this.debug.cpu1Backtrace() : this.debug.cpu0Backtrace();
    const sl = this.queriedSourceLine() ?? this.debug.sourceLine();
    const detail = resolveAddressDetail(addr, syms, sl, bt?.frames ?? []);
    if (!detail.symbol && !detail.fileLine) return 'No matching ELF symbol within +/-4 KiB.';
    return detail.fileLine ? `${detail.symbol ?? 'pc'} · ${detail.fileLine}` : (detail.symbol ?? '');
  });

  protected actionLabel(rule: WatchTriggerRule): string {
    return formatTriggerActionLabel(rule);
  }

  protected onCoreChange(event: Event): void {
    const val = Number.parseInt((event.target as HTMLSelectElement).value, 10);
    this.consoleStore.activeCore.set(val === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0);
  }

  protected onDecoderToggle(event: Event): void {
    this.symbolDecoderChanged.emit((event.target as HTMLInputElement).checked);
  }

  protected onLookupInput(event: Event): void {
    this.lookupDraft.set((event.target as HTMLInputElement).value);
  }

  protected async lookupCurrentPcSource(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const sl = await client.getSourceLine(this.consoleStore.activeCore());
      this.queriedSourceLine.set(sl);
      if (sl.found && !this.lookupDraft().trim()) {
        this.lookupDraft.set(`0x${(sl.pc >>> 0).toString(16).padStart(8, '0')}`);
      }
    } catch (err) {
      this.rpc.noteOptionalError(err, 'Source line lookup');
    }
  }

  protected onPatternInput(event: Event): void {
    this.patternDraft.set((event.target as HTMLInputElement).value);
  }

  protected onAddTrigger(event: Event): void {
    event.preventDefault();
    const pattern = this.patternDraft().trim();
    if (!pattern) return;
    const action = this.triggerAction();
    this.addRule.emit({ pattern, action, pauseOnMatch: action === 'alert_halt' });
    this.patternDraft.set('');
  }

  protected resetImage(): void {
    void this.execution.resetImage();
  }
}
