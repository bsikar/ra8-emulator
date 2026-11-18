import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  computed,
  effect,
  inject,
  input,
  signal,
  viewChild,
} from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import {
  type ConsoleEntry,
  type ConsoleLineEnding,
  ConsoleStore,
} from '../../core/stores/console.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import {
  type ConsoleDisplayMode,
  type ConsoleKindFilter,
  type ConsoleTimestampMode,
  decodeHexSymbolsInText,
  filterConsoleEntries,
  formatBytesAsHex,
  formatEntryTimestamp,
} from './console-model';

@Component({
  selector: 'app-console-stream',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="stream-pane">
      <div class="stream-head">
        <div class="head-left">
          <app-section-kicker label="UART SERIAL STREAM" />
          <div class="seg-group">
            <button type="button" class="chip-btn" [class.is-active]="consoleStore.selectedChannel() === 'all'" (click)="consoleStore.selectedChannel.set('all')">All</button>
            @for (ch of consoleStore.channels(); track ch) {
              <button type="button" class="chip-btn mono" [class.is-active]="consoleStore.selectedChannel() === ch" (click)="consoleStore.selectedChannel.set(ch)">SCI{{ ch }}</button>
            }
          </div>
        </div>
        <div class="head-right">
          <div class="seg-group">
            <button type="button" class="seg-tab" [class.is-active]="displayMode() === 'ascii'" data-testid="console-mode-ascii" (click)="displayMode.set('ascii')">ASCII</button>
            <button type="button" class="seg-tab" [class.is-active]="displayMode() === 'hex'" data-testid="console-mode-hex" (click)="displayMode.set('hex')">Hex</button>
          </div>
          <div class="seg-group">
            <button type="button" class="seg-tab" [class.is-active]="timestampMode() === 'elapsed'" data-testid="console-ts-elapsed" (click)="timestampMode.set('elapsed')">Elapsed</button>
            <button type="button" class="seg-tab" [class.is-active]="timestampMode() === 'virtual'" data-testid="console-ts-virtual" (click)="timestampMode.set('virtual')">Virtual ns</button>
          </div>
          <select class="es-select" aria-label="Filter stream direction" [value]="kindFilter()" (change)="onKindChange($event)">
            <option value="all">RX + TX</option>
            <option value="rx">RX only</option>
            <option value="tx">TX only</option>
          </select>
          <input type="text" class="filter-input mono" data-testid="console-filter-input" [value]="searchQuery()" (input)="onSearchInput($event)" placeholder="Filter output..." />
          <button type="button" class="mini-btn" data-testid="console-clear-btn" [disabled]="consoleStore.entries().length === 0" (click)="consoleStore.clear()">Clear</button>
          <button type="button" class="mini-btn" data-testid="console-export-btn" [disabled]="consoleStore.filteredEntries().length === 0" (click)="exportLog()">Export .log</button>
        </div>
      </div>

      <div #streamViewport class="stream-viewport mono" data-testid="console-stream-viewport" (scroll)="onViewportScroll()">
        @if (visibleRows().length > 0) {
          @for (row of visibleRows(); track row.id) {
            <div class="log-row" [class.is-tx]="row.isInput" [attr.data-testid]="'console-row-' + row.id">
              <span class="ts es-meta">{{ row.timestamp }}</span>
              <span class="tag es-meta">CH{{ row.channel }} {{ row.isInput ? 'TX' : 'RX' }}</span>
              <span class="payload">
                @for (seg of row.segments; track $index) {
                  <span>{{ seg.text }}</span>
                  @if (seg.symbol) {
                    <span class="sym-badge">[{{ seg.symbol }}]</span>
                  }
                }
              </span>
            </div>
          }
        } @else {
          <p class="es-meta empty-note">
            {{ rpc.isConnected() ? 'No UART bytes matching current filter.' : 'Connect a session to stream UART output.' }}
          </p>
        }
      </div>

      @if (autoScrollLocked()) {
        <button type="button" class="autoscroll-pill" data-testid="console-autoscroll-pill" (click)="resumeAutoScroll()">Resume Autoscroll ↓</button>
      }

      <form class="tx-bar" (submit)="onTxSubmit($event)">
        @if (execution.cpu1Attached()) {
          <select class="es-select mono" aria-label="Target core" [value]="consoleStore.activeCore()" (change)="onCoreChange($event)">
            <option [value]="cpu0">CPU0</option>
            <option [value]="cpu1">CPU1</option>
          </select>
        }
        <select class="es-select mono" aria-label="Line ending" data-testid="console-line-ending" [value]="lineEnding()" (change)="onEndingChange($event)">
          <option value="lf">LF</option>
          <option value="crlf">CRLF</option>
          <option value="none">Raw</option>
        </select>
        <label class="echo-label">
          <input type="checkbox" data-testid="console-echo-toggle" [checked]="localEcho()" (change)="onEchoToggle($event)" />
          <span>Echo</span>
        </label>
        <input type="text" class="tx-input mono" data-testid="console-tx-input" [value]="txDraft()" (input)="onTxInput($event)" placeholder="Send UART command or AT string..." />
        <button type="submit" class="send-btn" data-testid="console-send-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()">Send</button>
      </form>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; position: relative; }
      .stream-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .stream-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .head-left, .head-right, .seg-group { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .chip-btn, .mini-btn, .send-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .chip-btn.is-active, .send-btn { background: var(--es-interactive); color: var(--es-text-primary); }
      .send-btn:disabled, .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .seg-tab { border: 0; border-bottom: 2px solid transparent; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 2px 4px; cursor: pointer; }
      .seg-tab.is-active { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .filter-input, .tx-input { background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 4px; min-width: 0; }
      .filter-input { width: 136px; }
      .tx-input { flex: 1; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .stream-viewport { flex: 1; min-height: 0; overflow: auto; padding: 8px 12px; font-size: 12px; line-height: 1.5; }
      .log-row { display: flex; gap: 10px; padding: 2px 0; border-bottom: 1px solid var(--es-divider); white-space: pre-wrap; word-break: break-word; min-width: 0; }
      .log-row.is-tx { color: var(--es-text-primary); }
      .ts { min-width: 84px; flex-shrink: 0; }
      .tag { min-width: 56px; flex-shrink: 0; }
      .payload { flex: 1; min-width: 0; color: var(--es-text-secondary); }
      .sym-badge { margin-left: 4px; padding: 0 5px; border: 1px solid var(--es-border-strong); border-radius: var(--es-radius-sm); background: var(--es-container); color: var(--es-text-primary); }
      .autoscroll-pill { position: absolute; right: 18px; bottom: 52px; border: 1px solid var(--es-signal-cursor); background: var(--es-container); color: var(--es-text-primary); border-radius: var(--es-radius-full); font-size: 12px; padding: 3px 10px; cursor: pointer; }
      .tx-bar { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--es-border); background: var(--es-chrome); }
      .echo-label { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-muted); white-space: nowrap; }
      .empty-note { margin: 8px 0; }
    `,
  ],
})
export class ConsoleStreamComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly consoleStore = inject(ConsoleStore);
  protected readonly execution = inject(ExecutionStore);

  public readonly symbolDecoderEnabled = input<boolean>(true);
  private readonly streamViewport = viewChild<ElementRef<HTMLDivElement>>('streamViewport');

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly displayMode = signal<ConsoleDisplayMode>('ascii');
  protected readonly timestampMode = signal<ConsoleTimestampMode>('elapsed');
  protected readonly kindFilter = signal<ConsoleKindFilter>('all');
  protected readonly searchQuery = signal<string>('');
  protected readonly lineEnding = signal<ConsoleLineEnding>('lf');
  protected readonly localEcho = signal<boolean>(true);
  protected readonly txDraft = signal<string>('');
  protected readonly autoScrollLocked = signal<boolean>(false);

  protected readonly visibleRows = computed(() => {
    const entries = filterConsoleEntries(this.consoleStore.filteredEntries(), this.searchQuery(), this.kindFilter());
    const firstNs = entries[0]?.virtualNs ?? 0n;
    const tsMode = this.timestampMode();
    const dispMode = this.displayMode();
    const decodeSymbols = this.symbolDecoderEnabled();
    const syms = this.consoleStore.activeCore() === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols();
    return entries.map((entry: ConsoleEntry) => {
      const bodyText = dispMode === 'hex' ? formatBytesAsHex(entry.bytes) : entry.text;
      const segments = decodeSymbols ? decodeHexSymbolsInText(bodyText, syms) : [{ text: bodyText, symbol: null, address: null }];
      return {
        id: entry.id,
        channel: entry.channel,
        isInput: entry.isInput,
        timestamp: formatEntryTimestamp(entry.virtualNs, firstNs, tsMode),
        segments,
      };
    });
  });

  constructor() {
    effect(() => {
      const count = this.visibleRows().length;
      if (count > 0 && !this.autoScrollLocked()) {
        queueMicrotask(() => this.scrollToBottom());
      }
    });
  }

  protected onViewportScroll(): void {
    const el = this.streamViewport()?.nativeElement;
    if (!el) return;
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    this.autoScrollLocked.set(distanceFromBottom > 24);
  }

  protected resumeAutoScroll(): void {
    this.autoScrollLocked.set(false);
    this.scrollToBottom();
  }

  protected onKindChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'all' || val === 'rx' || val === 'tx') this.kindFilter.set(val);
  }

  protected onSearchInput(event: Event): void {
    this.searchQuery.set((event.target as HTMLInputElement).value);
  }

  protected onCoreChange(event: Event): void {
    const val = Number.parseInt((event.target as HTMLSelectElement).value, 10);
    this.consoleStore.activeCore.set(val === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0);
  }

  protected onEndingChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'lf' || val === 'crlf' || val === 'none') this.lineEnding.set(val);
  }

  protected onEchoToggle(event: Event): void {
    this.localEcho.set((event.target as HTMLInputElement).checked);
  }

  protected onTxInput(event: Event): void {
    this.txDraft.set((event.target as HTMLInputElement).value);
  }

  protected async onTxSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const raw = this.txDraft();
    if (!raw) return;
    this.txDraft.set('');
    await this.consoleStore.sendInput(raw, this.consoleStore.activeCore(), this.lineEnding(), this.localEcho());
  }

  protected exportLog(): void {
    const blob = this.consoleStore.exportLogBlob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'ra8-uart-console.log';
    link.click();
    URL.revokeObjectURL(url);
  }

  private scrollToBottom(): void {
    const el = this.streamViewport()?.nativeElement;
    if (el) el.scrollTop = el.scrollHeight;
  }
}
