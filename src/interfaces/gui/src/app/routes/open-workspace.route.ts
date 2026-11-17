import { ChangeDetectionStrategy, Component, OnInit, computed, effect, inject, signal, untracked } from '@angular/core';
import { Router } from '@angular/router';
import {
  type BoardPreset,
  type BoardProfile,
  Core,
  OFFICIAL_BOARD_PRESETS,
  type WorkspaceEntry,
  inspectElf,
  parseBoardProfile,
  parseElfSymbols,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { BoardStore } from '../core/stores/board.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import { type RecentWorkspaceEntry, WorkspaceStore } from '../core/stores/workspace.store';
import { formatByteSize } from '../features/bundles/bundle-summary';
import { formatPresetArchSummary, formatRelativeTime } from '../features/launch/launch-commands';
import { LaunchIconComponent } from '../features/launch/launch-icons.component';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { pickBrowserFile } from '../shared/utils/file-picker';
import { formatHex32 } from '../shared/utils/hex';

export type OpenBrowserFilter = 'all' | 'folders' | 'elf' | 'board';

export interface StagedElfArtifact {
  name: string;
  sourcePath: string;
  bytes: Uint8Array;
  entryHex: string;
  hasDebugInfo: boolean;
  symbolCount: number;
  chunkedTransfer: boolean;
}

export interface StagedBoardArtifact {
  name: string;
  sourcePath: string;
  rawText: string;
  profile: BoardProfile;
}

const CHUNKED_LOAD_THRESHOLD = 65_536;
const WORKSPACE_READ_CHUNK = 131_072;

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
      if (filter === 'elf') return entry.kind === 'directory' || /\.(elf|axf)$/i.test(entry.name);
      if (filter === 'board') return entry.kind === 'directory' || /\.board$/i.test(entry.name);
      return true;
    });
  });

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

  protected goBack(): void {
    void this.router.navigateByUrl('/launch');
  }

  protected onPathInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.pathQuery.set(event.target.value);
  }

  protected onWsUrlInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.wsUrl.set(event.target.value);
  }

  protected onHostPresetSelect(event: Event): void {
    if (event.target instanceof HTMLSelectElement && event.target.value) this.wsUrl.set(event.target.value);
  }

  protected onBoardSelect(event: Event): void {
    if (event.target instanceof HTMLSelectElement) this.selectedBoardId.set(event.target.value);
  }

  protected onBreakToggle(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.breakAtMain.set(event.target.checked);
  }

  protected formatBytes(bytes: number): string {
    return formatByteSize(bytes);
  }

  protected formatAge(iso: string): string {
    return formatRelativeTime(iso);
  }

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
    const bytes = await this.readRemoteFileFully(nextPath);
    if (bytes) {
      this.stageArtifactBytes(entry.name, nextPath, bytes);
    }
  }

  protected async browseLocalFile(): Promise<void> {
    const file = await pickBrowserFile({
      accept: '.elf,.axf,.board',
      description: 'ARM Firmware (.elf / .axf) or Board Profile (.board)',
      extensions: ['.elf', '.axf', '.board'],
    });
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    this.stageArtifactBytes(file.name, file.name, bytes);
  }

  protected async onFallbackFileSelected(event: Event): Promise<void> {
    const input = event.target;
    if (!(input instanceof HTMLInputElement)) return;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    this.stageArtifactBytes(file.name, file.name, bytes);
  }

  protected stageArtifactBytes(fileName: string, sourcePath: string, bytes: Uint8Array): void {
    if (/\.board$/i.test(fileName)) {
      const rawText = new TextDecoder().decode(bytes);
      try {
        const profile = parseBoardProfile(rawText);
        this.stagedElf.set(null);
        this.validationError.set(null);
        this.stagedBoard.set({ name: fileName, sourcePath, rawText, profile });
      } catch (err) {
        this.stagedBoard.set(null);
        this.stagedElf.set(null);
        this.validationError.set(err instanceof Error ? err.message : `Invalid board profile: ${fileName}`);
      }
      return;
    }

    const header = inspectElf(bytes);
    if (!header.valid) {
      this.stagedElf.set(null);
      this.stagedBoard.set(null);
      this.validationError.set(header.reason ?? `Invalid ARM32 ELF image (${fileName})`);
      return;
    }
    const syms = parseElfSymbols(bytes);
    this.stagedBoard.set(null);
    this.validationError.set(null);
    this.stagedElf.set({
      name: fileName,
      sourcePath,
      bytes,
      entryHex: formatHex32(header.entry >>> 0),
      hasDebugInfo: header.hasDebugInfo,
      symbolCount: syms.length,
      chunkedTransfer: bytes.length > CHUNKED_LOAD_THRESHOLD,
    });
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
        return;
      }

      if (elf) {
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
        this.workspace.recordRecentWorkspace({
          id: `elf:${elf.name}`,
          name: elf.name.replace(/\.(elf|axf)$/i, ''),
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
    } finally {
      this.opening.set(false);
    }
  }

  private async readRemoteFileFully(remotePath: string): Promise<Uint8Array | null> {
    const chunks: Uint8Array[] = [];
    for (let offset = 0n, total = 0; ; ) {
      const part = await this.workspace.readWorkspaceFile(remotePath, offset, WORKSPACE_READ_CHUNK);
      if (!part) {
        this.validationError.set(this.rpc.errorMessage() ?? `Failed to read ${remotePath}`);
        return null;
      }
      if (part.bytes.length > 0) {
        chunks.push(part.bytes);
        total += part.bytes.length;
        offset += BigInt(part.bytes.length);
      }
      if (!part.eof && part.bytes.length > 0) continue;
      const merged = new Uint8Array(total);
      for (let i = 0, pos = 0; i < chunks.length; pos += chunks[i]!.length, i++) merged.set(chunks[i]!, pos);
      return merged;
    }
  }
}
