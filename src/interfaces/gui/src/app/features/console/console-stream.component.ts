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
  type ConsoleStreamTab,
  type ConsoleTimestampMode,
  type WatchTriggerAction,
  classifyConsoleStream,
  compileConsoleSearch,
  decodeHexSymbolsInText,
  filterConsoleEntries,
  formatBytesAsHex,
  formatConsoleCopyText,
  formatEntryTimestamp,
} from './console-model';

const SCI_CHANNELS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] as const;

@Component({
  selector: 'app-console-stream',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './console-stream.component.html',
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .stream-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .stream-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .head-left, .head-right, .seg-group, .search-wrap { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .chip-btn, .mini-btn, .send-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .chip-btn.is-active, .send-btn { background: var(--es-interactive); color: var(--es-text-primary); border-color: var(--es-signal-cursor); }
      .send-btn:disabled, .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .seg-tab { border: 0; border-bottom: 2px solid transparent; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 2px 5px; cursor: pointer; }
      .seg-tab.is-active { color: var(--es-text-primary); border-bottom-color: var(--es-signal-cursor); }
      .filter-input, .tx-input { background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 4px; min-width: 0; }
      .filter-input { width: 148px; }
      .tx-input { flex: 1; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .regex-err { padding: 4px 12px; font-size: 12px; color: var(--es-signal-fault); border-bottom: 1px solid var(--es-border); }
      .viewport-wrap { flex: 1; min-height: 0; position: relative; display: flex; flex-direction: column; }
      .stream-viewport { flex: 1; min-height: 0; overflow: auto; padding: 8px 12px; font-size: 12px; line-height: 1.5; }
      .log-row { display: flex; align-items: baseline; gap: 10px; padding: 2px 4px; border-bottom: 1px solid var(--es-divider); white-space: pre-wrap; word-break: break-word; min-width: 0; }
      .log-row.is-tx { color: var(--es-text-primary); }
      .log-row.is-marked { background: var(--es-code-active-bg); border-left: 2px solid var(--es-signal-cursor); }
      .mark-dot { width: 6px; height: 6px; border-radius: var(--es-radius-full); flex-shrink: 0; align-self: center; }
      .mark-dot.is-fault { background: var(--es-signal-fault); }
      .mark-dot.is-marker { background: var(--es-signal-cursor); }
      .ts { min-width: 82px; flex-shrink: 0; }
      .tag { min-width: 68px; flex-shrink: 0; }
      .payload { flex: 1; min-width: 0; color: var(--es-text-secondary); }
      .sym-badge { margin-left: 4px; padding: 0 5px; border: 1px solid var(--es-border-strong); border-radius: var(--es-radius-sm); background: var(--es-container); color: var(--es-text-primary); }
      .autoscroll-pill { position: absolute; left: 14px; bottom: 12px; border: 1px solid var(--es-signal-cursor); background: var(--es-container); color: var(--es-text-primary); border-radius: var(--es-radius-full); font-size: 12px; padding: 3px 10px; cursor: pointer; }
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
  public readonly markedEntryIds = input<Readonly<Record<number, WatchTriggerAction>>>({});
  private readonly streamViewport = viewChild<ElementRef<HTMLDivElement>>('streamViewport');

  protected readonly cpu0 = Core.Cpu0;
  protected readonly cpu1 = Core.Cpu1;
  protected readonly streamTab = signal<ConsoleStreamTab>('all');
  protected readonly displayMode = signal<ConsoleDisplayMode>('ascii');
  protected readonly timestampMode = signal<ConsoleTimestampMode>('elapsed');
  protected readonly kindFilter = signal<ConsoleKindFilter>('all');
  protected readonly searchQuery = signal<string>('');
  protected readonly useRegex = signal<boolean>(false);
  protected readonly lineEnding = signal<ConsoleLineEnding>('lf');
  protected readonly localEcho = signal<boolean>(true);
  protected readonly txDraft = signal<string>('');
  protected readonly autoScrollLocked = signal<boolean>(false);

  protected readonly availableChannels = computed(() => {
    const merged = new Set<number>(SCI_CHANNELS);
    for (const ch of this.consoleStore.channels()) merged.add(ch);
    return Array.from(merged).sort((a, b) => a - b);
  });

  protected readonly channelSelectValue = computed(() => {
    const sel = this.consoleStore.selectedChannel();
    return sel === 'all' ? 'all' : String(sel);
  });

  protected readonly regexError = computed(() => compileConsoleSearch(this.searchQuery(), this.useRegex()).regexError);

  protected readonly filteredEntries = computed(() =>
    filterConsoleEntries(
      this.consoleStore.filteredEntries(),
      this.searchQuery(),
      this.kindFilter(),
      this.streamTab(),
      this.useRegex()
    )
  );

  protected readonly emptyMessage = computed(() => {
    if (!this.rpc.isConnected()) return 'Connect a session to stream device output.';
    const tab = this.streamTab();
    if (tab === 'swo') return 'No SWO trace packets received in this session.';
    if (tab === 'rtt') return 'No RTT channel frames received in this session.';
    return 'No UART bytes matching current filter.';
  });

  protected readonly visibleRows = computed(() => {
    const entries = this.filteredEntries();
    const firstNs = entries[0]?.virtualNs ?? 0n;
    const tsMode = this.timestampMode();
    const dispMode = this.displayMode();
    const decodeSymbols = this.symbolDecoderEnabled();
    const marks = this.markedEntryIds();
    const syms =
      this.consoleStore.activeCore() === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols();
    return entries.map((entry: ConsoleEntry) => {
      const bodyText = dispMode === 'hex' ? formatBytesAsHex(entry.bytes) : entry.text;
      const segments = decodeSymbols
        ? decodeHexSymbolsInText(bodyText, syms)
        : [{ text: bodyText, symbol: null, address: null }];
      const streamKind = classifyConsoleStream(entry);
      const streamTag = streamKind === 'uart' ? `CH${entry.channel}` : `${streamKind.toUpperCase()} CH${entry.channel}`;
      return {
        id: entry.id,
        streamTag,
        isInput: entry.isInput,
        markKind: marks[entry.id] ?? null,
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

  protected onChannelSelect(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'all') {
      this.consoleStore.selectedChannel.set('all');
      return;
    }
    const parsed = Number.parseInt(val, 10);
    if (Number.isFinite(parsed)) this.consoleStore.selectedChannel.set(parsed);
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

  protected async copyLog(): Promise<void> {
    const text = formatConsoleCopyText(this.filteredEntries(), this.displayMode(), this.timestampMode());
    if (!text) return;
    if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        this.rpc.pushToast(`Copied ${this.filteredEntries().length} console entries`);
        return;
      } catch (err) {
        this.rpc.noteOptionalError(err, 'Clipboard copy failed');
      }
    }
    this.rpc.pushToast('Clipboard API unavailable in this environment', 'neutral');
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
