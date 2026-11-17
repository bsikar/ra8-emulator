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
import { Router } from '@angular/router';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore, resolveWsUrlFromSearch } from '../core/rpc/rpc-connection.store';
import { SearchEverywhereStore } from '../core/search/search-everywhere.store';
import { BoardStore } from '../core/stores/board.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { type RecentWorkspaceEntry, WorkspaceStore } from '../core/stores/workspace.store';
import { VimStore } from '../core/vim/vim.store';
import {
  type LaunchCommandItem,
  buildLaunchCommands,
  filterLaunchCommands,
  filterRecentWorkspaces,
  formatPresetArchSummary,
} from '../features/launch/launch-commands';
import { LaunchCommandListComponent } from '../features/launch/launch-command-list.component';
import { LaunchConnectBarComponent } from '../features/launch/launch-connect-bar.component';
import { LaunchIconComponent } from '../features/launch/launch-icons.component';
import {
  LaunchNewWorkspaceDialogComponent,
  type NewWorkspacePayload,
} from '../features/launch/launch-new-workspace-dialog.component';
import { LaunchWorkspaceListComponent } from '../features/launch/launch-workspace-list.component';
import { CommandModeStore, formatShortcut, isEditableEventTarget } from '../shell/command-mode.store';

@Component({
  selector: 'app-launch-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: {
    '(window:keydown.enter)': 'onWindowEnter($event)',
    '(window:keydown.escape)': 'onWindowEscape($event)',
  },
  imports: [
    LaunchIconComponent,
    LaunchWorkspaceListComponent,
    LaunchCommandListComponent,
    LaunchConnectBarComponent,
    LaunchNewWorkspaceDialogComponent,
  ],
  templateUrl: './launch.route.html',
  styleUrl: './launch.route.css',
})
export class LaunchRouteComponent implements OnInit, OnDestroy {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly workspace = inject(WorkspaceStore);
  protected readonly board = inject(BoardStore);
  protected readonly cmdMode = inject(CommandModeStore);
  protected readonly searchEverywhere = inject(SearchEverywhereStore);
  protected readonly vim = inject(VimStore);
  private readonly router = inject(Router);

  private readonly searchInputEl = viewChild<ElementRef<HTMLInputElement>>('searchInputEl');
  private readonly workspaceListRef = viewChild(LaunchWorkspaceListComponent);

  protected readonly wsInput = signal<string>(this.rpc.serverUrl());
  protected readonly searchQuery = signal<string>('');
  protected readonly inCommandMode = signal<boolean>(false);
  protected readonly selectedIndex = signal<number>(0);
  protected readonly connectBarOpen = signal<boolean>(false);
  protected readonly newDialogOpen = signal<boolean>(false);
  protected readonly commandChordLabel = formatShortcut({ mod: true, key: 'k' });

  protected readonly filteredWorkspaces = computed(() =>
    filterRecentWorkspaces(this.workspace.recentWorkspaces(), this.searchQuery())
  );

  protected readonly commandSections = computed(() =>
    filterLaunchCommands(this.buildLaunchCommands(), this.searchQuery())
  );

  protected readonly flatCommands = computed(() =>
    this.commandSections().flatMap((section) => section.items)
  );

  constructor() {
    effect(() => {
      const lines = this.filteredWorkspaces().map(
        (w) => `${w.name} ${w.targetModel ?? ''} ${w.path}`.trim()
      );
      this.vim.updateLines(lines.length > 0 ? lines : [''], true);
    });

    effect(() => {
      if (!this.vim.enabled() || this.inCommandMode() || this.newDialogOpen()) return;
      const list = this.filteredWorkspaces();
      if (list.length === 0) return;
      const line = Math.max(0, Math.min(list.length - 1, this.vim.cursor().line));
      this.selectedIndex.set(line);
    });
    effect(() => {
      if (this.newDialogOpen()) {
        this.cmdMode.setRouteModalDismiss(() => this.newDialogOpen.set(false));
      } else {
        this.cmdMode.setRouteModalDismiss(null);
      }
    });
  }

  public ngOnInit(): void {
    if (typeof window === 'undefined') return;
    const queryUrl = resolveWsUrlFromSearch(window.location.search);
    if (queryUrl) {
      this.wsInput.set(queryUrl);
      if (this.rpc.isConnected() && this.rpc.serverUrl() === queryUrl) return;
      void this.connectAndRecord(queryUrl);
    }
  }

  public ngOnDestroy(): void {
    this.cmdMode.setRouteModalDismiss(null);
  }

  protected onWindowEscape(event: KeyboardEvent): void {
    if (event.defaultPrevented || this.cmdMode.hasOpenOverlay() || this.searchEverywhere.open() || this.newDialogOpen()) {
      return;
    }
    this.closeWorkspaceMenus();
    if (this.inCommandMode()) {
      event.preventDefault();
      this.exitCommandMode();
      this.searchInputEl()?.nativeElement.focus();
    }
  }

  protected onWindowEnter(event: KeyboardEvent): void {
    if (!this.vim.enabled() || this.vim.mode() !== 'normal' || this.inCommandMode() || this.newDialogOpen()) return;
    if (this.cmdMode.hasOpenOverlay() || this.searchEverywhere.open()) return;
    const target = event.target;
    if (isEditableEventTarget(target) || target instanceof HTMLButtonElement || target instanceof HTMLAnchorElement) return;
    const entry = this.filteredWorkspaces()[this.selectedIndex()];
    if (entry) {
      event.preventDefault();
      void this.openRecentWorkspace(entry);
    }
  }

  protected onSearchInput(event: Event): void {
    const target = event.target;
    if (!(target instanceof HTMLInputElement)) return;
    const val = target.value;
    if (!this.inCommandMode() && val.startsWith('>')) {
      this.inCommandMode.set(true);
      const rest = val.slice(1).replace(/^\s+/, '');
      this.searchQuery.set(rest);
      target.value = rest;
      this.selectedIndex.set(0);
      return;
    }
    this.searchQuery.set(val);
    this.selectedIndex.set(0);
  }

  protected onSearchKeyDown(event: KeyboardEvent): void {
    if (event.key === 'Escape' && this.inCommandMode()) {
      event.preventDefault();
      event.stopPropagation();
      this.exitCommandMode();
      return;
    }
    if (event.key === 'Backspace' && this.inCommandMode() && this.searchQuery().length === 0) {
      event.preventDefault();
      this.exitCommandMode();
      return;
    }
    const count = this.inCommandMode() ? this.flatCommands().length : this.filteredWorkspaces().length;
    if (count === 0) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.selectedIndex.update((i) => (i + 1) % count);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.selectedIndex.update((i) => (i - 1 + count) % count);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      this.executeActiveItem();
    }
  }

  protected exitCommandMode(): void {
    this.inCommandMode.set(false);
    this.searchQuery.set('');
    this.selectedIndex.set(0);
    const el = this.searchInputEl()?.nativeElement;
    if (el) el.value = '';
  }

  protected openWorkspacePicker(): void {
    void this.router.navigateByUrl('/open');
  }

  protected openImportArchivePicker(): void {
    void this.router.navigateByUrl('/import');
  }

  protected toggleConnectRemote(): void {
    void this.router.navigateByUrl('/connect');
  }

  protected onWorkspaceCreated(payload: NewWorkspacePayload): void {
    this.board.selectBoardPreset(payload.preset.targetId);
    this.wsInput.set(payload.wsUrl);
    this.workspace.recordRecentWorkspace({
      id: `ws:${Date.now().toString(36)}`,
      name: payload.name,
      path: payload.path,
      wsUrl: payload.wsUrl,
      pinned: false,
      targetModel: payload.preset.targetId.toUpperCase(),
      archSummary: formatPresetArchSummary(payload.preset),
      modeLabel: payload.modeLabel,
      artifactSummary: `${payload.preset.targetId.replace('-', '_')}.board`,
    });
    this.newDialogOpen.set(false);
    this.selectedIndex.set(0);
    this.rpc.pushToast(`Created workspace ${payload.name}`);
    if (payload.cpu0ElfFile && this.rpc.isConnected()) {
      void this.board
        .loadElfFile(payload.cpu0ElfFile.name, payload.cpu0ElfFile.bytes, Core.Cpu0)
        .then((ok) => {
          if (ok) void this.router.navigateByUrl('/debug');
        });
    }
  }

  protected async openRecentWorkspace(entry: RecentWorkspaceEntry): Promise<void> {
    this.wsInput.set(entry.wsUrl);
    this.workspace.recordRecentWorkspace({ ...entry });
    const ok = await this.connectAndRecord(entry.wsUrl);
    if (ok) {
      await this.router.navigateByUrl('/debug');
    } else if (this.workspace.recentWorkspaces().length > 0) {
      this.connectBarOpen.set(true);
    }
  }

  protected connectNow(): void {
    void this.connectAndRecord(this.wsInput());
  }

  protected connectSavedHost(url: string): void {
    this.wsInput.set(url);
    void this.connectAndRecord(url);
  }

  protected runCommandItem(item: LaunchCommandItem): void {
    this.exitCommandMode();
    void item.run();
  }

  protected closeWorkspaceMenus(): void {
    this.workspaceListRef()?.closeMenus();
  }

  private executeActiveItem(): void {
    if (this.inCommandMode()) {
      const cmd = this.flatCommands()[this.selectedIndex()] ?? this.flatCommands()[0];
      if (cmd) this.runCommandItem(cmd);
      return;
    }
    const entry = this.filteredWorkspaces()[this.selectedIndex()] ?? this.filteredWorkspaces()[0];
    if (entry) void this.openRecentWorkspace(entry);
  }

  private async connectAndRecord(url: string): Promise<boolean> {
    const ok = await this.rpc.connect(url);
    if (ok) {
      this.workspace.addSavedHost(url);
      if (this.router.url.startsWith('/launch')) void this.execution.refreshClock();
    } else if (this.workspace.recentWorkspaces().length > 0) {
      this.connectBarOpen.set(true);
    }
    return ok;
  }

  private buildLaunchCommands(): LaunchCommandItem[] {
    return buildLaunchCommands({
      commandChordLabel: this.commandChordLabel,
      createWorkspace: () => this.newDialogOpen.set(true),
      openWorkspace: () => this.openWorkspacePicker(),
      importArchive: () => this.openImportArchivePicker(),
      connectRemote: () => this.toggleConnectRemote(),
      openMonitor: () => void this.router.navigateByUrl('/console'),
      openBoardComposer: () => void this.router.navigateByUrl('/hardware'),
      openSettings: () => this.cmdMode.settingsOpen.set(true),
      openPalette: () => this.cmdMode.openPalette(),
      openSearchEverywhere: () => this.searchEverywhere.openSearch(),
      openExtensions: () => this.cmdMode.extensionsOpen.set(true),
      toggleVim: () => this.vim.toggleEnabled(),
    });
  }
}
