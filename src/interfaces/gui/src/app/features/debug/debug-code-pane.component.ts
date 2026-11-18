import {
  ChangeDetectionStrategy,
  Component,
  OnDestroy,
  OnInit,
  computed,
  effect,
  inject,
  signal,
} from '@angular/core';
import { Core, StopReason } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { DebugStore } from '../../core/stores/debug.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { VimStore } from '../../core/vim/vim.store';
import { CommandModeStore } from '../../shell/command-mode.store';
import { formatHex32, parseHexAddress } from '../../shared/utils/hex';
import { type DebugCodeMode, buildCodeBufferLines } from './debug-view';

@Component({
  selector: 'app-debug-code-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './debug-code-pane.component.html',
  styleUrl: './debug-code-pane.component.css',
})
export class DebugCodePaneComponent implements OnInit, OnDestroy {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly debug = inject(DebugStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly vim = inject(VimStore);
  private readonly cmdMode = inject(CommandModeStore);

  private cleanups: Array<() => void> = [];

  protected readonly mode = signal<DebugCodeMode>('disasm');
  protected readonly followPc = signal<boolean>(true);
  protected readonly splitCores = signal<boolean>(false);
  protected readonly jumpDraft = signal<string>('');

  protected readonly pcValue = computed(() => (this.debug.registers()['pc'] ?? 0) >>> 0);
  protected readonly symbolOptions = computed(() =>
    (this.debug.activeCore() === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols()).slice(0, 40)
  );

  protected readonly activeFileLabel = computed(() => {
    const sl = this.debug.sourceLine();
    if (sl?.found && sl.path) return `${sl.path}:${sl.line}`;
    const elf = this.debug.activeCore() === Core.Cpu1 ? this.board.cpu1ElfName() : this.board.cpu0ElfName();
    return elf ? `${elf} · ${this.hex(this.pcValue())}` : `CPU${this.debug.activeCore()} · ${this.hex(this.pcValue())}`;
  });

  protected readonly canSkipBkpt = computed(() => {
    if (this.execution.lastStop()?.reason === StopReason.Breakpoint) return true;
    const activeRow = this.debug.disasm().find((r) => (r.address >>> 0) === this.pcValue());
    return Boolean(activeRow && /^bkpt\b/i.test(activeRow.text.trim()));
  });

  protected readonly codeLines = computed(() => {
    const core = this.debug.activeCore();
    const bps = core === Core.Cpu1 ? this.debug.cpu1Breakpoints() : this.debug.cpu0Breakpoints();
    const fnName = this.debug.backtrace()?.frames[0]?.name;
    return buildCodeBufferLines({
      mode: this.mode(),
      disasmRows: this.debug.disasm(),
      sourceLines: this.debug.sourceFileLines(),
      sourceLine: this.debug.sourceLine(),
      pc: this.pcValue(),
      breakpoints: bps,
      fnName,
    });
  });

  protected readonly cpu1Lines = computed(() =>
    buildCodeBufferLines({
      mode: 'disasm',
      disasmRows: this.debug.cpu1Disasm(),
      sourceLines: [],
      sourceLine: null,
      pc: (this.debug.cpu1Registers()['pc'] ?? 0) >>> 0,
      breakpoints: this.debug.cpu1Breakpoints(),
    })
  );

  protected readonly vimCursorLine = computed(() => (this.vim.enabled() ? this.vim.cursor().line : -1));

  protected readonly emptyMessage = computed(() => {
    if (!this.rpc.isConnected()) return 'Connect a session to inspect disassembly and source.';
    if (this.mode() === 'source') return 'No DWARF source file mapped at PC (use --workspace or switch to Disasm).';
    return 'No active disassembly rows.';
  });

  constructor() {
    effect(() => {
      const lines = this.codeLines().map((l) => l.text);
      this.vim.updateLines(lines, true);
    });
  }

  public ngOnInit(): void {
    this.vim.bindBuffer({ lines: this.codeLines().map((l) => l.text), readOnly: true, viewportHeight: 20 });
    this.cleanups.push(
      this.vim.registerExHandler('goto-address', async (cmd) => {
        if (cmd.kind !== 'goto-address' || !this.rpc.isConnected()) return false;
        this.followPc.set(false);
        await this.debug.refreshDisassembly(this.debug.activeCore(), cmd.address, 32);
        return true;
      }),
      this.vim.registerExHandler('goto-line', (cmd) => {
        if (cmd.kind !== 'goto-line') return false;
        const lines = this.vim.lines();
        const line = Math.max(0, Math.min(lines.length - 1, cmd.line - 1));
        this.vim.bindBuffer({ lines, readOnly: true, viewportHeight: 20, cursor: { line, col: 0 } });
        return true;
      })
    );
  }

  public ngOnDestroy(): void {
    for (const fn of this.cleanups) fn();
    this.cleanups = [];
  }

  protected hex(val: number): string {
    return formatHex32(val);
  }

  protected padLine(n: number): string {
    return String(n).padStart(4, ' ');
  }

  protected onJumpInput(event: Event): void {
    this.jumpDraft.set((event.target as HTMLInputElement).value);
  }

  protected async onJumpSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const raw = this.jumpDraft().trim();
    if (!raw || !this.rpc.isConnected()) return;
    const targetAddr = this.resolveJumpTarget(raw);
    if (targetAddr === null) return;
    this.followPc.set(false);
    await this.debug.refreshDisassembly(this.debug.activeCore(), targetAddr, 32);
  }

  protected async onBreakAction(): Promise<void> {
    if (!this.rpc.isConnected() || this.rpc.observeOnly()) return;
    const raw = this.jumpDraft().trim();
    if (!raw) {
      await this.debug.toggleBreakpoint(this.pcValue(), this.debug.activeCore(), this.hex(this.pcValue()));
      return;
    }
    const addr = parseHexAddress(raw);
    if (addr !== null) await this.debug.toggleBreakpoint(addr, this.debug.activeCore(), formatHex32(addr));
    else await this.debug.addNamedBreakpoint(raw, this.debug.activeCore());
  }

  protected toggleLineBreakpoint(address: number | null): void {
    if (address === null || this.rpc.observeOnly()) return;
    void this.debug.toggleBreakpoint(address, this.debug.activeCore(), formatHex32(address));
  }

  protected onCodeKeyDown(event: KeyboardEvent): void {
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement) return;
    if (this.cmdMode.hasOpenOverlay()) return;
    const k = event.key.toLowerCase();
    if (event.metaKey || event.altKey) return;
    if (event.ctrlKey && k !== 'u' && k !== 'd' && event.key !== '[') return;
    const res = this.vim.handleKeyDown({
      key: event.key,
      ctrlKey: event.ctrlKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
      metaKey: event.metaKey,
    });
    if (res.handled) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  private resolveJumpTarget(raw: string): number | null {
    const addr = parseHexAddress(raw);
    if (addr !== null) return addr;
    const sym = this.symbolOptions().find((s) => s.name === raw);
    return sym ? sym.address >>> 0 : null;
  }
}
