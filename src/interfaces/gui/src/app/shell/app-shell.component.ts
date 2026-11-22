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
import { PreferencesStore } from '../core/stores/preferences.store';
import type { RecentElfEntry } from '../core/stores/recent-elf-db';
import { RecentElfStore } from '../core/stores/recent-elf.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import { RewindStore } from '../core/stores/rewind.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { VimStore } from '../core/vim/vim.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';
import { extractDroppedFileWithHandle, readBlobBytes } from '../shared/utils/file-picker';
import { toggleDocumentFullscreen } from '../shared/utils/fullscreen';
import {
  CommandModeStore,
  formatShortcut,
  isEditableEventTarget,
} from './command-mode.store';
import { CommandPaletteComponent } from './command-palette.component';
import { ConnectionPopoverComponent } from './connection-popover.component';
import { DropVeilComponent } from './drop-veil.component';
import { ExtensionsSheetComponent } from './extensions-sheet.component';
import { SearchEverywhereComponent } from './search-everywhere.component';
import { SettingsModalComponent } from './settings-modal.component';
import { buildShellCommandActions } from './shell-commands';
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
    SettingsModalComponent,
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
  protected readonly recentElf = inject(RecentElfStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);
  protected readonly prefs = inject(PreferencesStore);
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
  protected readonly reloadChordLabel = formatShortcut({ mod: true, key: 'r' });
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
        canReload: this.recentElf.canReload(),
        historySupported: this.rewind.historySupported(),
        workspaceSupported: this.workspace.hasWorkspaceCap(),
        artifactsSupported: this.rpc.hasCapability(CAP_ARTIFACTS),
      });
    });

    effect(() => {
      this.syncCommands(this.recentElf.entries(), this.extStore.contributedCommands());
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
      recentElf: this.recentElf,
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
    this.syncCommands(this.recentElf.entries(), this.extStore.contributedCommands());
  }

  public ngOnDestroy(): void {
    for (const cleanup of this.cleanups) cleanup();
    this.cleanups = [];
  }

  protected onWindowKeyDown(event: KeyboardEvent): void {
    if (event.ctrlKey && event.metaKey && event.key.toLowerCase() === 'f') {
      event.preventDefault();
      void this.toggleFullScreen();
      return;
    }
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
    const picked = await extractDroppedFileWithHandle(event.dataTransfer);
    if (!picked) return;
    const { file, handle } = picked;
    const lower = file.name.toLowerCase();
    if (lower.endsWith('.board')) {
      const rawText = new TextDecoder().decode(await readBlobBytes(file));
      this.board.importBoardProfileText(file.name, rawText);
      return;
    }
    if (lower.endsWith('.tar') || lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      const preview = await this.rewind.previewStagedArchive(await readBlobBytes(file), file.name);
      if (preview) {
        this.rpc.pushToast(`Staged archive ${file.name} (${preview.entries.length} entries)`);
      }
      await this.router.navigateByUrl('/import');
      return;
    }
    const bytes = await readBlobBytes(file);
    const ok = await this.board.loadElfFile(file.name, bytes, Core.Cpu0, { breakAtMain: false });
    if (ok) {
      await this.recentElf.recordLoadedElf({
        fileName: file.name,
        core: Core.Cpu0,
        wsUrl: this.rpc.serverUrl(),
        handle,
        bytes,
      });
      this.workspace.recordRecentWorkspace({
        id: `elf:${file.name}`,
        name: file.name.replace(/\.(elf|axf|ra8app)$/i, ''),
        path: file.name,
        wsUrl: this.rpc.serverUrl(),
        pinned: false,
        modeLabel: 'Dropped ELF',
        artifactSummary: file.name,
      });
      await this.router.navigateByUrl('/debug');
    }
  }

  protected openRecentFromMenu(entry: RecentElfEntry): void {
    this.cmdMode.activeMenu.set(null);
    void this.recentElf.openRecent(entry);
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

  protected async toggleFullScreen(): Promise<void> {
    const res = await toggleDocumentFullscreen();
    if (res.error) this.rpc.pushToast(`Full Screen: ${res.error}`, 'neutral');
  }

  private syncCommands(
    recentElfs: readonly RecentElfEntry[],
    extCmds: ReturnType<ExtensionStore['contributedCommands']>
  ): void {
    const actions = buildShellCommandActions(
      {
        navigateByUrl: (url) => this.router.navigateByUrl(url),
        reloadActiveElf: () => this.recentElf.reloadActiveElf(),
        openRecentElf: (entry) => this.recentElf.openRecent(entry),
        toggleFullScreen: () => this.toggleFullScreen(),
        openSearchEverywhere: () => this.searchEverywhere.openSearch(),
        openExtensions: () => this.cmdMode.extensionsOpen.set(true),
        toggleVim: () => this.vim.toggleEnabled(),
        toggleRunPause: () => this.toggleRunPause(),
        stepOver: () => this.execution.stepOver(),
        stepInto: () => this.execution.step(),
        openSettings: () => this.cmdMode.settingsOpen.set(true),
        openHelp: () => this.cmdMode.helpOpen.set(true),
        disconnectSession: () => this.rpc.disconnect(true),
        executeExtensionCommand: (command) => this.extStore.executeContributedCommand(command),
      },
      recentElfs,
      extCmds
    );
    this.cmdMode.registerActions(actions);
  }
}
