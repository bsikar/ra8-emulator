import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  OnDestroy,
  OnInit,
  computed,
  effect,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { Core, type SourceLineResult, StopReason } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { DebugStore } from '../../core/stores/debug.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { WorkspaceStore } from '../../core/stores/workspace.store';
import { VimStore } from '../../core/vim/vim.store';
import { CommandModeStore } from '../../shell/command-mode.store';
import { formatHex32, parseHexAddress } from '../../shared/utils/hex';
import { type DebugCodeMode, buildCodeBufferLines } from './debug-code-format';

function normalizeWorkspacePath(raw: string): string {
  return raw.replace(/^\.\//, '').trim();
}

function baseFileName(raw: string): string {
  const parts = raw.split(/[\\/]/);
  return parts[parts.length - 1] || raw;
}

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
  protected readonly workspace = inject(WorkspaceStore);
  protected readonly vim = inject(VimStore);
  private readonly cmdMode = inject(CommandModeStore);

  private readonly codeViewport = viewChild<ElementRef<HTMLElement>>('codeViewport');
  private cleanups: Array<() => void> = [];
  private loadingPaths = new Set<string>();

  protected readonly cpu1 = Core.Cpu1;
  protected readonly mode = signal<DebugCodeMode>('disasm');
  protected readonly followPc = signal<boolean>(true);
  protected readonly splitCores = signal<boolean>(false);
  protected readonly jumpDraft = signal<string>('');
  protected readonly openTabs = signal<string[]>([]);
  protected readonly selectedTabPath = signal<string | null>(null);
  protected readonly workspaceSources = signal<Record<string, string[]>>({});
  protected readonly workspaceErrors = signal<Record<string, string>>({});

  protected readonly pcValue = computed(() => (this.debug.registers()['pc'] ?? 0) >>> 0);
  protected readonly symbolOptions = computed(() =>
    (this.debug.activeCore() === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols()).slice(0, 40)
  );

  protected readonly selectedFrame = computed(
    () => this.debug.backtrace()?.frames[this.debug.selectedFrameIndex()] ?? null
  );

  protected readonly effectiveSourceLine = computed<SourceLineResult | null>(() => {
    const tab = this.selectedTabPath();
    const sl = this.debug.sourceLine();
    const frame = this.selectedFrame();
    if (this.debug.selectedFrameIndex() > 0 && frame?.file) {
      if (!tab || tab === frame.file) {
        return { found: true, pc: frame.pc >>> 0, line: Math.max(1, frame.line), path: frame.file };
      }
    }
    if (tab && (!sl?.found || sl.path !== tab)) {
      return { found: true, pc: 0, line: 0, path: tab };
    }
    if (sl?.found) return sl;
    if (frame?.file) return { found: true, pc: frame.pc >>> 0, line: Math.max(1, frame.line), path: frame.file };
    return null;
  });

  protected readonly activeSourceLines = computed<string[]>(() => {
    const targetPath = this.effectiveSourceLine()?.path ?? '';
    const sl = this.debug.sourceLine();
    if (targetPath && sl?.found && sl.path === targetPath && this.debug.sourceFileLines().length > 0) {
      return this.debug.sourceFileLines();
    }
    if (targetPath) {
      return this.workspaceSources()[targetPath] ?? this.workspaceSources()[normalizeWorkspacePath(targetPath)] ?? [];
    }
    return this.debug.sourceFileLines();
  });

  protected readonly activeFileLabel = computed(() => {
    const sl = this.effectiveSourceLine();
    if (sl?.found && sl.path) {
      return sl.line > 0 ? `${sl.path}:${sl.line}` : sl.path;
    }
    const elf = this.debug.activeCore() === Core.Cpu1 ? this.board.cpu1ElfName() : this.board.cpu0ElfName();
    return elf ? `${elf} · ${this.hex(this.pcValue())}` : `CPU${this.debug.activeCore()} · ${this.hex(this.pcValue())}`;
  });

  protected readonly canSkipBkpt = computed(() => {
    if (this.execution.isRunning()) return false;
    const stop = this.execution.lastStop();
    if (stop?.reason === StopReason.Breakpoint && stop.core === this.debug.activeCore()) return true;
    const activeRow = this.debug.disasm().find((r) => (r.address >>> 0) === this.pcValue());
    return Boolean(activeRow && /^bkpt(?:\.[nw])?\b/i.test(activeRow.text.trim()));
  });

  protected readonly codeLines = computed(() => {
    const core = this.debug.activeCore();
    const bps = core === Core.Cpu1 ? this.debug.cpu1Breakpoints() : this.debug.cpu0Breakpoints();
    const fnName = this.selectedFrame()?.name ?? this.debug.backtrace()?.frames[0]?.name;
    return buildCodeBufferLines({
      mode: this.mode(),
      disasmRows: this.debug.disasm(),
      sourceLines: this.activeSourceLines(),
      sourceLine: this.effectiveSourceLine(),
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
  protected readonly markLabelsByLine = computed<Record<number, string>>(() => {
    const marks = this.vim.bufferState().marks;
    const out: Record<number, string> = {};
    for (const [key, pos] of Object.entries(marks)) {
      out[pos.line] = out[pos.line] ? `${out[pos.line]}${key}` : key;
    }
    return out;
  });

  protected readonly emptyMessage = computed(() => {
    if (!this.rpc.isConnected()) return 'Connect a session to inspect disassembly and source.';
    const sl = this.effectiveSourceLine();
    if (this.mode() === 'source') {
      if (sl?.found && sl.path && !this.workspace.hasWorkspaceCap()) {
        return `Source mapped (${sl.path}:${sl.line}) — start daemon with --workspace to stream file via CAP_WORKSPACE.`;
      }
      const err = sl?.path ? this.workspaceErrors()[sl.path] : null;
      if (err) return `Unable to read ${sl?.path}: ${err}`;
      return 'No DWARF source file mapped at PC (use --workspace or switch to Disasm).';
    }
    return 'No active disassembly rows.';
  });

  constructor() {
    effect(() => {
      const lines = this.codeLines().map((l) => l.text);
      this.vim.updateLines(lines, true);
    });
    effect(() => {
      const sl = this.debug.sourceLine();
      const frame = this.selectedFrame();
      const target = this.debug.selectedFrameIndex() > 0 && frame?.file ? frame.file : (sl?.found ? sl.path : '');
      if (target) {
        this.ensureTab(target);
        void this.ensureWorkspaceFileLoaded(target);
      }
    });
    effect(() => {
      const cursorLine = this.vimCursorLine();
      const pc = this.pcValue();
      const follow = this.followPc();
      const host = this.codeViewport()?.nativeElement;
      if (!host) return;
      queueMicrotask(() => this.scrollActiveLine(host, cursorLine, follow, pc));
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
      }),
      this.vim.registerExHandler('b', async (cmd) => {
        if (cmd.kind !== 'custom' || !this.rpc.isConnected() || this.rpc.observeOnly()) return false;
        const target = cmd.args[0]?.trim();
        if (!target) return false;
        await this.armBreakpointTarget(target);
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

  protected tabTitle(path: string): string {
    return baseFileName(path);
  }

  protected selectTab(path: string): void {
    this.selectedTabPath.set(path);
    void this.ensureWorkspaceFileLoaded(path);
  }

  protected isSearchMatch(text: string): boolean {
    const q = this.vim.bufferState().lastSearchPattern;
    return Boolean(q && text.includes(q));
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
    await this.armBreakpointTarget(raw);
  }

  protected toggleLineBreakpoint(address: number | null, core: Core = this.debug.activeCore()): void {
    if (address === null || this.rpc.observeOnly()) return;
    void this.debug.toggleBreakpoint(address, core, formatHex32(address));
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

  private async armBreakpointTarget(raw: string): Promise<void> {
    const addr = parseHexAddress(raw);
    if (addr !== null) await this.debug.toggleBreakpoint(addr, this.debug.activeCore(), formatHex32(addr));
    else await this.debug.addNamedBreakpoint(raw, this.debug.activeCore());
  }

  private resolveJumpTarget(raw: string): number | null {
    const addr = parseHexAddress(raw);
    if (addr !== null) return addr;
    const sym = this.symbolOptions().find((s) => s.name === raw);
    return sym ? sym.address >>> 0 : null;
  }

  private ensureTab(path: string): void {
    if (!this.openTabs().includes(path)) {
      this.openTabs.update((tabs) => [...tabs.slice(-5), path]);
    }
    this.selectedTabPath.set(path);
  }

  private async ensureWorkspaceFileLoaded(path: string): Promise<void> {
    if (!this.rpc.isConnected() || !this.workspace.hasWorkspaceCap()) return;
    const clean = normalizeWorkspacePath(path);
    if (this.workspaceSources()[path] || this.workspaceSources()[clean] || this.loadingPaths.has(path)) return;
    this.loadingPaths.add(path);
    try {
      const contents =
        (await this.workspace.readWorkspaceFile(path, 0n, 65_536)) ??
        (clean !== path ? await this.workspace.readWorkspaceFile(clean, 0n, 65_536) : null);
      if (contents) {
        const lines = new TextDecoder().decode(contents.bytes).split(/\r?\n/);
        this.workspaceSources.update((map) => ({ ...map, [path]: lines, [clean]: lines }));
      } else {
        this.workspaceErrors.update((map) => ({ ...map, [path]: 'not found in workspace root' }));
      }
    } finally {
      this.loadingPaths.delete(path);
    }
  }

  private scrollActiveLine(host: HTMLElement, cursorLine: number, follow: boolean, _pc: number): void {
    const selector = cursorLine >= 0 ? `[data-vim-line="${cursorLine}"]` : follow ? '.es-code-line.is-active' : '';
    if (!selector) return;
    const target = host.querySelector(selector);
    if (target instanceof HTMLElement && typeof target.scrollIntoView === 'function') {
      target.scrollIntoView({ block: 'nearest' });
    }
  }
}
