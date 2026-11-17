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
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { CAP_ARTIFACTS, Core } from 'ra8-rpc-client';
import { filter } from 'rxjs/operators';
import { ExtensionStore } from '../core/extensions/extension.store';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { SearchEverywhereStore } from '../core/search/search-everywhere.store';
import { BoardStore } from '../core/stores/board.store';
import { DebugStore } from '../core/stores/debug.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import { RewindStore } from '../core/stores/rewind.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { VimStore } from '../core/vim/vim.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';
import {
  type CommandAction,
  CommandModeStore,
  formatShortcut,
  isEditableEventTarget,
} from './command-mode.store';
import { CommandPaletteComponent } from './command-palette.component';
import { ConnectionPopoverComponent } from './connection-popover.component';
import { DropVeilComponent } from './drop-veil.component';
import { ExtensionsSheetComponent } from './extensions-sheet.component';
import { SearchEverywhereComponent } from './search-everywhere.component';
import { registerShellExHandlers, registerShellSearchProviders } from './shell-ide-bridge';
import { ToastRegionComponent } from './toast-region.component';

interface NavRouteItem {
  path: string;
  label: string;
}

@Component({
  selector: 'app-shell',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: {
    '(window:keydown)': 'onWindowKeyDown($event)',
    '(window:keyup)': 'onWindowKeyUp($event)',
    '(window:blur)': 'onWindowBlur()',
  },
  imports: [
    RouterOutlet,
    RouterLink,
    RouterLinkActive,
    CommandPaletteComponent,
    ConnectionPopoverComponent,
    SearchEverywhereComponent,
    ExtensionsSheetComponent,
    DropVeilComponent,
    ToastRegionComponent,
    StatusDotComponent,
    SectionKickerComponent,
    TonalButtonComponent,
  ],
  templateUrl: './app-shell.component.html',
  styleUrl: './app-shell.component.css',
})
export class AppShellComponent implements OnInit, OnDestroy {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly board = inject(BoardStore);
  protected readonly debug = inject(DebugStore);
  protected readonly rewind = inject(RewindStore);
  protected readonly workspace = inject(WorkspaceStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);
  protected readonly cmdMode = inject(CommandModeStore);
  protected readonly searchEverywhere = inject(SearchEverywhereStore);
  protected readonly extStore = inject(ExtensionStore);
  protected readonly vim = inject(VimStore);
  private readonly router = inject(Router);

  private readonly vimExInputEl = viewChild<ElementRef<HTMLInputElement>>('vimExInputEl');
  private cleanups: Array<() => void> = [];

  protected readonly dragActive = signal<boolean>(false);
  protected readonly connectionPopoverOpen = signal<boolean>(false);
  protected readonly commandChordLabel = formatShortcut({ mod: true, key: 'k' });
  protected readonly extensionsChordLabel = formatShortcut({ mod: true, shift: true, key: 'x' });
  protected readonly viewLinks: readonly NavRouteItem[] = [
    { path: '/launch', label: 'Launch' },
    { path: '/debug', label: 'Debug' },
    { path: '/hardware', label: 'Hardware' },
    { path: '/rewind', label: 'Rewind' },
    { path: '/profile', label: 'Profile' },
    { path: '/console', label: 'Console' },
  ];

  protected readonly coreSummary = computed(() =>
    this.execution.cpu1Attached() ? 'CPU0 · CPU1' : 'CPU0'
  );

  protected readonly statusTone = computed(() => {
    if (this.rpc.isConnected()) return 'nominal' as const;
    if (this.rpc.errorMessage()) return 'fault' as const;
    return 'muted' as const;
  });

  constructor() {
    effect(() => {
      this.cmdMode.updateContext({
        connected: this.rpc.isConnected(),
        running: this.execution.isRunning(),
        historySupported: this.rewind.historySupported(),
        workspaceSupported: this.workspace.hasWorkspaceCap(),
        artifactsSupported: this.rpc.hasCapability(CAP_ARTIFACTS),
      });
    });

    effect(() => {
      const extCmds = this.extStore.contributedCommands();
      this.syncCommands(extCmds);
    });

    effect(() => {
      if (this.vim.mode() === 'command') {
        queueMicrotask(() => this.vimExInputEl()?.nativeElement.focus());
      }
    });

    this.router.events
      .pipe(filter((evt): evt is NavigationEnd => evt instanceof NavigationEnd))
      .subscribe((evt) => this.cmdMode.updateContext({ activePath: evt.urlAfterRedirects }));
  }

  public ngOnInit(): void {
    const deps = {
      router: this.router,
      rpc: this.rpc,
      board: this.board,
      debug: this.debug,
      workspace: this.workspace,
      remoteHosts: this.remoteHosts,
      cmdMode: this.cmdMode,
      searchEverywhere: this.searchEverywhere,
      vim: this.vim,
    };
    this.cleanups.push(registerShellSearchProviders(deps), registerShellExHandlers(deps));
    this.extStore.setCommandExecutor((cmdId) => {
      const match = this.cmdMode.resolvedCommands().find((c) => c.action.id === cmdId);
      if (match) return Promise.resolve(this.cmdMode.execute(match));
      return Promise.resolve(false);
    });
    this.syncCommands(this.extStore.contributedCommands());
  }

  public ngOnDestroy(): void {
    for (const cleanup of this.cleanups) cleanup();
    this.cleanups = [];
  }

  protected onWindowKeyDown(event: KeyboardEvent): void {
    if (this.connectionPopoverOpen() && event.key === 'Escape') {
      event.preventDefault();
      this.connectionPopoverOpen.set(false);
      return;
    }
    this.searchEverywhere.handleWindowKeyDown(event);
    if (this.searchEverywhere.open() && event.key === 'Escape') {
      event.preventDefault();
      this.searchEverywhere.closeSearch();
      return;
    }
    if (this.cmdMode.handleKeyDown(event)) {
      return;
    }
    if (this.cmdMode.hasOpenOverlay() || this.searchEverywhere.open()) {
      return;
    }
    const target = event.target;
    if (target instanceof HTMLElement && target.dataset['testid'] === 'vim-ex-input') {
      if (event.key === 'Enter' || event.key === 'Escape') {
        event.preventDefault();
        this.vim.handleKeyDown({ key: event.key });
      }
      return;
    }
    if (isEditableEventTarget(target)) {
      return;
    }
    const res = this.vim.handleKeyDown(
      { key: event.key, ctrlKey: event.ctrlKey, shiftKey: event.shiftKey, altKey: event.altKey, metaKey: event.metaKey },
      { allowColonWhenDisabled: true }
    );
    if (res.handled) event.preventDefault();
  }

  protected onWindowKeyUp(event: KeyboardEvent): void {
    if (this.searchEverywhere.open()) return;
    this.searchEverywhere.handleWindowKeyUp(event);
  }

  protected onWindowBlur(): void {
    this.searchEverywhere.resetDoubleShift();
  }

  protected onVimExInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.vim.openCommandMode(target.value);
    }
  }

  protected onDragOver(event: DragEvent): void {
    event.preventDefault();
    this.dragActive.set(true);
  }

  protected onDragLeave(event: DragEvent): void {
    if (event.currentTarget === event.target) {
      this.dragActive.set(false);
    }
  }

  protected async onDrop(event: DragEvent): Promise<void> {
    event.preventDefault();
    this.dragActive.set(false);
    const file = event.dataTransfer?.files?.[0];
    if (!file) return;
    const lower = file.name.toLowerCase();
    if (lower.endsWith('.board')) {
      this.board.importBoardProfileText(file.name, await file.text());
      return;
    }
    if (lower.endsWith('.tar') || lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      const preview = await this.rewind.previewStagedArchive(new Uint8Array(await file.arrayBuffer()));
      if (preview) {
        this.rpc.pushToast(`Staged archive ${file.name} (${preview.entries.length} entries)`);
        await this.router.navigateByUrl('/rewind');
      }
      return;
    }
    const ok = await this.board.loadElfFile(file.name, new Uint8Array(await file.arrayBuffer()), Core.Cpu0);
    if (ok) await this.router.navigateByUrl('/debug');
  }

  protected openConnectRoute(): void {
    void this.router.navigateByUrl('/connect');
  }

  protected toggleRunPause(): void {
    if (this.execution.isRunning()) {
      void this.execution.pause();
    } else {
      void this.execution.run();
    }
  }

  private syncCommands(extCmds: ReturnType<ExtensionStore['contributedCommands']>): void {
    const base: CommandAction[] = [
      { id: 'nav-launch', label: 'Go to Launch', category: 'navigation', menu: 'view', shortcut: { key: '1' }, run: () => this.router.navigateByUrl('/launch') },
      { id: 'nav-connect', label: 'Connect Remote Host...', category: 'session', menu: 'file', shortcut: { mod: true, key: 'r' }, run: () => this.router.navigateByUrl('/connect') },
      { id: 'nav-debug', label: 'Go to Debug', category: 'navigation', menu: 'view', shortcut: { key: '2' }, run: () => this.router.navigateByUrl('/debug') },
      { id: 'nav-hw', label: 'Go to Hardware', category: 'navigation', menu: 'view', shortcut: { key: '3' }, run: () => this.router.navigateByUrl('/hardware') },
      { id: 'nav-rewind', label: 'Go to Rewind', category: 'navigation', menu: 'view', shortcut: { key: '4' }, run: () => this.router.navigateByUrl('/rewind') },
      { id: 'nav-profile', label: 'Go to Profile', category: 'navigation', menu: 'view', shortcut: { key: '5' }, run: () => this.router.navigateByUrl('/profile') },
      { id: 'nav-console', label: 'Go to Console', category: 'navigation', menu: 'terminal', shortcut: { key: '6' }, run: () => this.router.navigateByUrl('/console') },
      { id: 'open-search', label: 'Search Everywhere', category: 'navigation', menu: 'view', run: () => this.searchEverywhere.openSearch() },
      { id: 'open-extensions', label: 'Extensions', category: 'extensions', menu: 'view', shortcut: { mod: true, shift: true, key: 'x' }, run: () => this.cmdMode.extensionsOpen.set(true) },
      { id: 'toggle-vim', label: 'Toggle Vim Keybindings', category: 'session', menu: 'edit', run: () => this.vim.toggleEnabled() },
      { id: 'exec-run', label: 'Continue / Pause', category: 'execution', menu: 'file', shortcut: { key: 'F5' }, isEnabled: (c) => c.connected, run: () => this.toggleRunPause() },
      { id: 'exec-over', label: 'Step Over', category: 'execution', menu: 'edit', shortcut: { key: 'F10' }, isEnabled: (c) => c.connected && !c.running, run: () => this.execution.stepOver() },
      { id: 'exec-into', label: 'Step Into', category: 'execution', menu: 'edit', shortcut: { key: 'F11' }, isEnabled: (c) => c.connected && !c.running, run: () => this.execution.step() },
      { id: 'open-settings', label: 'Session Settings', category: 'session', menu: 'file', shortcut: { mod: true, key: ',' }, run: () => this.cmdMode.settingsOpen.set(true) },
      { id: 'open-help', label: 'Keyboard & Transport Help', category: 'help', menu: 'help', run: () => this.cmdMode.helpOpen.set(true) },
      { id: 'disconnect', label: 'Disconnect Session', category: 'session', menu: 'file', isEnabled: (c) => c.connected, run: () => this.rpc.disconnect(true) },
    ];
    const dynamic: CommandAction[] = extCmds.map((c) => ({
      id: `ext:${c.extensionId}:${c.command}`,
      label: `${c.extensionName}: ${c.title}`,
      category: 'extensions',
      run: () => this.extStore.executeContributedCommand(c.command),
    }));
    this.cmdMode.registerActions([...base, ...dynamic]);
  }
}
