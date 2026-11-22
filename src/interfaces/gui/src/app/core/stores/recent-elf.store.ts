import { Injectable, InjectionToken, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { Core, type WorkspaceContents } from 'ra8-rpc-client';
import {
  type BrowserFileHandleLike,
  readBlobBytes,
  readFromFileHandle,
} from '../../shared/utils/file-picker';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { BoardStore } from './board.store';
import { DebugPointsStore } from './debug-points.store';
import { ExecutionStore } from './execution.store';
import {
  type RecentElfEntry,
  RecentElfRepository,
  type RecentElfSourceKind,
  isFirmwareImageFileName,
} from './recent-elf-db';
import { WorkspaceStore } from './workspace.store';

export const WORKSPACE_READ_CHUNK_SIZE = 131_072;

export const RECENT_ELF_REPOSITORY = new InjectionToken<RecentElfRepository>('RECENT_ELF_REPOSITORY', {
  providedIn: 'root',
  factory: () => new RecentElfRepository(),
});

export interface WorkspaceFileReader {
  readWorkspaceFile: (path: string, offset?: bigint, length?: number) => Promise<WorkspaceContents | null>;
}

export interface RecordLoadedElfParams {
  fileName: string;
  core?: Core;
  wsUrl?: string;
  handle?: BrowserFileHandleLike | null;
  workspacePath?: string | null;
  bytes?: Uint8Array | null;
}

/** Stream all chunks of a remote workspace file into a single byte buffer. */
export async function readWorkspaceFileFully(
  workspace: WorkspaceFileReader,
  remotePath: string,
  chunkSize = WORKSPACE_READ_CHUNK_SIZE
): Promise<Uint8Array | null> {
  const chunks: Uint8Array[] = [];
  for (let offset = 0n, total = 0; ; ) {
    const part = await workspace.readWorkspaceFile(remotePath, offset, chunkSize);
    if (!part) return null;
    if (part.bytes.length > 0) {
      chunks.push(part.bytes);
      total += part.bytes.length;
      offset += BigInt(part.bytes.length);
    }
    if (!part.eof && part.bytes.length > 0) continue;
    const merged = new Uint8Array(total);
    for (let i = 0, pos = 0; i < chunks.length; pos += chunks[i]!.length, i++) {
      merged.set(chunks[i]!, pos);
    }
    return merged;
  }
}

function resolveEntrySourceKind(params: RecordLoadedElfParams): RecentElfSourceKind {
  if (params.handle) return 'handle';
  if (params.workspacePath) return 'workspace';
  return 'bytes';
}

function buildRecentEntryId(params: RecordLoadedElfParams, core: Core, wsUrl: string): string {
  if (params.workspacePath) return `ws:${core}:${wsUrl}:${params.workspacePath}`;
  if (params.handle) return `handle:${core}:${params.fileName}`;
  return `bytes:${core}:${params.fileName}`;
}

@Injectable({ providedIn: 'root' })
export class RecentElfStore {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly board = inject(BoardStore);
  private readonly workspace = inject(WorkspaceStore);
  private readonly debugPoints = inject(DebugPointsStore);
  private readonly execution = inject(ExecutionStore);
  private readonly router = inject(Router);
  private readonly repo = inject(RECENT_ELF_REPOSITORY);

  public readonly entries = signal<RecentElfEntry[]>([]);
  public readonly activeSource = signal<RecentElfEntry | null>(null);
  public readonly reloading = signal<boolean>(false);

  public readonly canReload = computed<boolean>(
    () =>
      this.rpc.isConnected() &&
      !this.rpc.observeOnly() &&
      !this.reloading() &&
      this.activeSource() !== null
  );

  constructor() {
    void this.hydrate();
  }

  public async hydrate(): Promise<RecentElfEntry[]> {
    const items = await this.repo.list();
    this.entries.set(items);
    return items;
  }

  public async recordLoadedElf(params: RecordLoadedElfParams): Promise<RecentElfEntry | null> {
    if (!isFirmwareImageFileName(params.fileName)) return null;
    const core = params.core ?? Core.Cpu0;
    const wsUrl = (params.wsUrl ?? this.rpc.serverUrl()).trim() || 'ws://127.0.0.1:4567';
    const entry: RecentElfEntry = {
      id: buildRecentEntryId(params, core, wsUrl),
      fileName: params.fileName,
      core,
      sourceKind: resolveEntrySourceKind(params),
      workspacePath: params.workspacePath ?? null,
      handle: params.handle ?? null,
      cachedBytes: params.bytes ? new Uint8Array(params.bytes) : null,
      wsUrl,
      openedAtIso: new Date().toISOString(),
    };
    this.activeSource.set(entry);
    const updated = await this.repo.upsert(entry);
    this.entries.set(updated);
    return entry;
  }

  public findMatchingEntry(nameOrFileName: string, pathHint?: string): RecentElfEntry | null {
    const needle = nameOrFileName.trim().toLowerCase();
    const list = this.entries();
    if (pathHint) {
      const byPath = list.find((e) => e.workspacePath === pathHint);
      if (byPath) return byPath;
    }
    return (
      list.find(
        (e) =>
          e.fileName.toLowerCase() === needle ||
          e.fileName.replace(/\.(elf|axf|ra8app)$/i, '').toLowerCase() === needle
      ) ?? null
    );
  }

  public async openRecent(entry: RecentElfEntry): Promise<boolean> {
    if (this.rpc.observeOnly()) {
      this.rpc.pushToast('Observe mode is read-only: ELF upload disabled', 'neutral');
      return false;
    }
    const targetUrl = entry.wsUrl || this.rpc.serverUrl();
    if (!this.rpc.isConnected()) {
      const connected = await this.rpc.connect(targetUrl);
      if (!connected) return false;
    }

    const bytes = await this.resolveEntryBytes(entry, true);
    if (!bytes) {
      this.rpc.reportError('Open Recent failed', new Error(`Unable to read ${entry.fileName}`));
      return false;
    }

    const ok = await this.board.loadElfFile(entry.fileName, bytes, entry.core, { breakAtMain: false });
    if (!ok) return false;

    await this.recordLoadedElf({
      fileName: entry.fileName,
      core: entry.core,
      wsUrl: this.rpc.serverUrl(),
      handle: entry.handle,
      workspacePath: entry.workspacePath,
      bytes,
    });
    await this.router.navigateByUrl('/debug');
    return true;
  }

  public async reloadActiveElf(): Promise<boolean> {
    const src = this.activeSource();
    if (!src || !this.rpc.isConnected() || this.reloading()) return false;
    if (this.rpc.observeOnly()) {
      this.rpc.pushToast('Observe mode is read-only: Reload disabled', 'neutral');
      return false;
    }

    this.reloading.set(true);
    try {
      const symbols =
        src.core === Core.Cpu1 ? this.board.cpu1ElfSymbols() : this.board.cpu0ElfSymbols();
      const symbolNames = this.debugPoints.collectSymbolBreakpointNames(src.core, symbols);

      const allowFallback = src.sourceKind === 'bytes';
      const bytes = await this.resolveEntryBytes(src, allowFallback);
      if (!bytes) {
        this.rpc.reportError('Reload ELF failed', new Error(`Unable to re-read ${src.fileName}`));
        return false;
      }

      await this.debugPoints.clearBreakpointsForCore(src.core);
      const ok = await this.board.loadElfFile(src.fileName, bytes, src.core, { breakAtMain: false });
      if (!ok) return false;

      await this.recordLoadedElf({
        fileName: src.fileName,
        core: src.core,
        wsUrl: this.rpc.serverUrl(),
        handle: src.handle,
        workspacePath: src.workspacePath,
        bytes,
      });

      const restored = await this.debugPoints.restoreNamedBreakpoints(src.core, symbolNames);
      this.execution.inspectionEpoch.update((n) => n + 1);
      const totalRestored = restored.applied + restored.deferred;
      if (symbolNames.length > 0) {
        this.rpc.pushToast(
          `Reloaded ${src.fileName} at reset (${totalRestored}/${symbolNames.length} symbol breakpoints restored)`
        );
      } else {
        this.rpc.pushToast(`Reloaded ${src.fileName} at reset`);
      }
      return true;
    } finally {
      this.reloading.set(false);
    }
  }

  private async resolveEntryBytes(
    entry: RecentElfEntry,
    allowCachedFallback: boolean
  ): Promise<Uint8Array | null> {
    if (entry.handle) {
      try {
        const file = await readFromFileHandle(entry.handle);
        if (file) return await readBlobBytes(file);
      } catch (err) {
        this.rpc.noteOptionalError(err, `Re-read ${entry.fileName} from file handle`);
      }
    }
    if (entry.workspacePath && this.workspace.hasWorkspaceCap()) {
      const wsBytes = await readWorkspaceFileFully(this.workspace, entry.workspacePath);
      if (wsBytes) return wsBytes;
    }
    return allowCachedFallback ? entry.cachedBytes : null;
  }
}
