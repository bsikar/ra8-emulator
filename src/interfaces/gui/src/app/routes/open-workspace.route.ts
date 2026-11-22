import { ChangeDetectionStrategy, Component, OnInit, computed, effect, inject, signal, untracked } from '@angular/core';
import { Router } from '@angular/router';
import { type BoardPreset, Core, OFFICIAL_BOARD_PRESETS, type WorkspaceEntry } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { BoardStore } from '../core/stores/board.store';
import { ExecutionStore } from '../core/stores/execution.store';
import type { RecentElfEntry } from '../core/stores/recent-elf-db';
import { RecentElfStore, readWorkspaceFileFully } from '../core/stores/recent-elf.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import { type RecentWorkspaceEntry, WorkspaceStore } from '../core/stores/workspace.store';
import { formatByteSize } from '../features/bundles/bundle-summary';
import {
  type StagedBoardArtifact,
  type StagedElfArtifact,
  parseArtifactForStaging,
} from '../features/launch/launch-artifact';
import { formatPresetArchSummary, formatRelativeTime } from '../features/launch/launch-commands';
import { LaunchIconComponent } from '../features/launch/launch-icons.component';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { type BrowserFileHandleLike, pickBrowserFileWithHandle, readBlobBytes } from '../shared/utils/file-picker';

export type { StagedBoardArtifact, StagedElfArtifact };
export type OpenBrowserFilter = 'all' | 'folders' | 'elf' | 'board';

@Component({
  selector: 'app-open-workspace-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [LaunchIconComponent, SectionKickerComponent, StatusDotComponent],
  templateUrl: './open-workspace.route.html',
  styleUrl: './open-workspace.route.css',
})
export class OpenWorkspaceRouteComponent implements OnInit {
  private readonly router = inject(Router);
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);
  protected readonly workspace = inject(WorkspaceStore);
  protected readonly recentElf = inject(RecentElfStore);

  private stagedHandle: BrowserFileHandleLike | null = null;
  private stagedWorkspacePath: string | null = null;

  protected readonly currentDir = signal<string>('.');
  protected readonly pathQuery = signal<string>('');
  protected readonly activeFilter = signal<OpenBrowserFilter>('all');
  protected readonly loadingDir = signal<boolean>(false);
  protected readonly opening = signal<boolean>(false);
  protected readonly remoteEntries = signal<WorkspaceEntry[]>([]);
  protected readonly stagedElf = signal<StagedElfArtifact | null>(null);
  protected readonly stagedBoard = signal<StagedBoardArtifact | null>(null);
  protected readonly validationError = signal<string | null>(null);
  protected readonly wsUrl = signal<string>('ws://127.0.0.1:4567');
  protected readonly selectedBoardId = signal<string>(OFFICIAL_BOARD_PRESETS[0]!.id);
  protected readonly selectedCore = signal<Core>(Core.Cpu0);
  protected readonly breakAtMain = signal<boolean>(false);

  protected readonly allBoards = computed<BoardPreset[]>(() => [
    ...OFFICIAL_BOARD_PRESETS,
    ...this.board.savedBoards(),
  ]);

  protected readonly filteredEntries = computed<WorkspaceEntry[]>(() => {
    const filter = this.activeFilter();
    const query = this.pathQuery().trim().toLowerCase();
    const items = [...this.remoteEntries()].sort((a, b) => {
      const aDir = a.kind === 'directory' ? 0 : 1;
      const bDir = b.kind === 'directory' ? 0 : 1;
      return aDir !== bDir ? aDir - bDir : a.name.localeCompare(b.name);
    });
    return items.filter((entry) => {
      if (query && !entry.name.toLowerCase().includes(query)) return false;
      if (filter === 'folders') return entry.kind === 'directory';
      if (filter === 'elf') return entry.kind === 'directory' || /\.(elf|axf|ra8app)$/i.test(entry.name);
      if (filter === 'board') return entry.kind === 'directory' || /\.board$/i.test(entry.name);
      return true;
    });
  });

  protected readonly recentElfRows = computed<RecentElfEntry[]>(() =>
    this.recentElf.entries().slice(0, 6)
  );

  protected readonly recentArtifactRows = computed<RecentWorkspaceEntry[]>(() =>
    this.workspace.recentWorkspaces().slice(0, 6)
  );

  protected readonly canSubmit = computed<boolean>(
    () => !this.opening() && (this.stagedElf() !== null || this.stagedBoard() !== null)
  );

  constructor() {
    effect(() => {
      const canBrowse = this.workspace.hasWorkspaceCap();
      const dir = this.currentDir();
      if (canBrowse) {
        untracked(() => {
          void this.refreshDirectory(dir);
        });
      }
    });
  }

  public ngOnInit(): void {
    const currentUrl = this.rpc.serverUrl();
    if (currentUrl) this.wsUrl.set(currentUrl);
    const activePreset = this.board.selectedPreset();
    if (activePreset) this.selectedBoardId.set(activePreset.id);
    if (this.workspace.hasWorkspaceCap()) {
      void this.refreshDirectory(this.currentDir());
    }
  }

  protected goBack(): void { void this.router.navigateByUrl('/launch'); }
  protected onPathInput(e: Event): void { if (e.target instanceof HTMLInputElement) this.pathQuery.set(e.target.value); }
  protected onWsUrlInput(e: Event): void { if (e.target instanceof HTMLInputElement) this.wsUrl.set(e.target.value); }
  protected onHostPresetSelect(e: Event): void { if (e.target instanceof HTMLSelectElement && e.target.value) this.wsUrl.set(e.target.value); }
  protected onBoardSelect(e: Event): void { if (e.target instanceof HTMLSelectElement) this.selectedBoardId.set(e.target.value); }
  protected onBreakToggle(e: Event): void { if (e.target instanceof HTMLInputElement) this.breakAtMain.set(e.target.checked); }
  protected formatBytes(bytes: number): string { return formatByteSize(bytes); }
  protected formatAge(iso: string): string { return formatRelativeTime(iso); }

  protected isRootDir(): boolean {
    const d = this.currentDir().trim();
    return d === '' || d === '.';
  }

  protected goUpDirectory(): void {
    const cur = this.currentDir().replace(/\/+$/, '');
    if (!cur || cur === '.') return;
    const idx = cur.lastIndexOf('/');
    this.currentDir.set(idx > 0 ? cur.slice(0, idx) : '.');
  }

  protected async refreshDirectory(dir = this.currentDir()): Promise<void> {
    if (!this.workspace.hasWorkspaceCap()) return;
    this.loadingDir.set(true);
    try {
      const collected: WorkspaceEntry[] = [];
      let offset = 0;
      while (true) {
        const page = await this.workspace.listWorkspace(dir, offset, 64);
        if (!page) break;
        collected.push(...page.entries);
        if (!page.more || page.count <= 0) break;
        offset += page.count;
      }
      this.remoteEntries.set(collected);
    } finally {
      this.loadingDir.set(false);
    }
  }

  protected async openEntry(entry: WorkspaceEntry): Promise<void> {
    const nextPath = this.isRootDir() ? entry.name : `${this.currentDir()}/${entry.name}`;
    if (entry.kind === 'directory') {
      this.currentDir.set(nextPath);
      return;
    }
    const bytes = await readWorkspaceFileFully(this.workspace, nextPath);
    if (!bytes) {
      this.validationError.set(this.rpc.errorMessage() ?? `Failed to read ${nextPath}`);
      return;
    }
    this.stagedHandle = null;
    this.stagedWorkspacePath = nextPath;
    this.stageArtifactBytes(entry.name, nextPath, bytes);
  }

  protected openRecentElf(entry: RecentElfEntry): void {
    void this.recentElf.openRecent(entry);
  }

  protected async browseLocalFile(): Promise<void> {
    const picked = await pickBrowserFileWithHandle({
      accept: '.elf,.axf,.ra8app,.board',
      description: 'ARM Firmware (.elf / .axf / .ra8app) or Board Profile (.board)',
      extensions: ['.elf', '.axf', '.ra8app', '.board'],
    });
    if (!picked) return;
    this.stagedHandle = picked.handle;
    this.stagedWorkspacePath = null;
    const bytes = await readBlobBytes(picked.file);
    this.stageArtifactBytes(picked.file.name, picked.file.name, bytes);
  }

  protected async onFallbackFileSelected(event: Event): Promise<void> {
    const input = event.target;
    if (!(input instanceof HTMLInputElement)) return;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    this.stagedHandle = null;
    this.stagedWorkspacePath = null;
    const bytes = await readBlobBytes(file);
    this.stageArtifactBytes(file.name, file.name, bytes);
  }

  protected stageArtifactBytes(fileName: string, sourcePath: string, bytes: Uint8Array): void {
    const res = parseArtifactForStaging(fileName, sourcePath, bytes);
    if (res.kind === 'error') {
      this.stagedElf.set(null);
      this.stagedBoard.set(null);
      this.validationError.set(res.error);
      return;
    }
    this.validationError.set(null);
    if (res.kind === 'board') {
      this.stagedElf.set(null);
      this.stagedBoard.set(res.board);
    } else {
      this.stagedBoard.set(null);
      this.stagedElf.set(res.elf);
    }
  }

  protected async openStagedArtifact(): Promise<void> {
    const elf = this.stagedElf();
    const brd = this.stagedBoard();
    if ((!elf && !brd) || this.opening()) return;
    this.opening.set(true);
    try {
      const targetUrl = this.wsUrl().trim() || 'ws://127.0.0.1:4567';
      if (!this.rpc.isConnected() || this.rpc.serverUrl() !== targetUrl) {
        await this.rpc.connect(targetUrl);
      }
      if (!this.rpc.isConnected()) {
        this.validationError.set(this.rpc.errorMessage() ?? `Unable to connect to ${targetUrl}`);
        return;
      }
      const preset =
        this.board.selectBoardPreset(this.selectedBoardId()) ??
        this.allBoards().find((p) => p.id === this.selectedBoardId()) ??
        OFFICIAL_BOARD_PRESETS[0]!;
      if (brd) {
        await this.submitStagedBoard(brd, preset, targetUrl);
        return;
      }
      if (elf) {
        await this.submitStagedElf(elf, preset, targetUrl);
      }
    } finally {
      this.opening.set(false);
    }
  }

  private async submitStagedBoard(brd: StagedBoardArtifact, preset: BoardPreset, targetUrl: string): Promise<void> {
    if (!this.board.importBoardProfileText(brd.name, brd.rawText)) return;
    this.workspace.recordRecentWorkspace({
      id: `brd:${brd.name}`,
      name: brd.name.replace(/\.board$/i, ''),
      path: brd.sourcePath,
      wsUrl: targetUrl,
      pinned: false,
      targetModel: preset.targetId.toUpperCase(),
      archSummary: formatPresetArchSummary(preset),
      modeLabel: 'Board Profile',
      artifactSummary: brd.name,
    });
    await this.router.navigateByUrl('/hardware');
  }

  private async submitStagedElf(elf: StagedElfArtifact, preset: BoardPreset, targetUrl: string): Promise<void> {
    const ok = await this.board.loadElfFile(elf.name, elf.bytes, this.selectedCore(), {
      breakAtMain: this.breakAtMain(),
    });
    if (!ok) {
      this.validationError.set(this.rpc.errorMessage() ?? `Failed to load ${elf.name}`);
      return;
    }
    if (typeof document !== 'undefined') {
      document.title = `${elf.name} — RA8 Emulator`;
    }
    await this.recentElf.recordLoadedElf({
      fileName: elf.name,
      core: this.selectedCore(),
      wsUrl: targetUrl,
      handle: this.stagedHandle,
      workspacePath: this.stagedWorkspacePath,
      bytes: elf.bytes,
    });
    this.workspace.recordRecentWorkspace({
      id: `elf:${elf.name}`,
      name: elf.name.replace(/\.(elf|axf|ra8app)$/i, ''),
      path: elf.sourcePath,
      wsUrl: targetUrl,
      pinned: false,
      targetModel: preset.targetId.toUpperCase(),
      archSummary: formatPresetArchSummary(preset),
      modeLabel: 'Prebuilt .elf',
      artifactSummary: formatByteSize(elf.bytes.length),
      entryAddress: elf.entryHex,
    });
    await this.router.navigateByUrl('/debug');
  }
}
