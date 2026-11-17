import { Injectable, computed, inject, signal } from '@angular/core';
import {
  type BuildStartArgs,
  type BuildStatus,
  CAP_BUILD,
  CAP_PROJECT,
  CAP_TARGETS,
  CAP_WORKSPACE,
  DEFAULT_RPC_URL,
  type ProjectPrepared,
  RA8RpcClient,
  type TargetEntry,
  type TargetPerformArgs,
  type TargetSelection,
  type WorkspaceContents,
  type WorkspacePage,
  type WorkspaceVersion,
  type WorkspaceWriteArgs,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export interface RecentWorkspaceEntry {
  id: string;
  name: string;
  path: string;
  wsUrl: string;
  pinned: boolean;
  lastOpenedIso: string;
}

const RECENT_KEY = 'ra8.recentWorkspaces.v1';
const HOSTS_KEY = 'ra8.savedHosts.v1';

@Injectable({ providedIn: 'root' })
export class WorkspaceStore {
  private readonly rpc = inject(RpcConnectionStore);

  public readonly recentWorkspaces = signal<RecentWorkspaceEntry[]>(this.loadStorage<RecentWorkspaceEntry[]>(RECENT_KEY, []));
  public readonly savedHosts = signal<string[]>(this.loadStorage<string[]>(HOSTS_KEY, [DEFAULT_RPC_URL]));
  public readonly workspacePage = signal<WorkspacePage | null>(null);
  public readonly workspaceWatchIds = signal<number[]>([]);
  public readonly activeBuildId = signal<bigint | null>(null);
  public readonly buildStatus = signal<BuildStatus | null>(null);
  public readonly buildRunning = signal<boolean>(false);
  public readonly buildLog = signal<string[]>([]);
  public readonly activeProjectConfig = signal<string>('');
  public readonly projectReceipt = signal<string | null>(null);
  public readonly targets = signal<TargetEntry[]>([]);
  public readonly reservedTarget = signal<TargetSelection | null>(null);
  public readonly lastTargetOutput = signal<string>('');

  public readonly hasWorkspaceCap = computed(() => this.rpc.hasCapability(CAP_WORKSPACE));
  public readonly hasBuildCap = computed(() => this.rpc.hasCapability(CAP_BUILD));
  public readonly hasProjectCap = computed(() => this.rpc.hasCapability(CAP_PROJECT));
  public readonly hasTargetsCap = computed(() => this.rpc.hasCapability(CAP_TARGETS));

  public recordRecentWorkspace(entry: Omit<RecentWorkspaceEntry, 'lastOpenedIso'>): void {
    const nextEntry: RecentWorkspaceEntry = { ...entry, lastOpenedIso: new Date().toISOString() };
    this.recentWorkspaces.update((prev) => {
      const merged = [nextEntry, ...prev.filter((w) => w.id !== entry.id)].slice(0, 20);
      merged.sort((a, b) => Number(b.pinned) - Number(a.pinned));
      this.saveStorage(RECENT_KEY, merged);
      return merged;
    });
    this.addSavedHost(entry.wsUrl);
  }

  public togglePinWorkspace(id: string): void {
    this.recentWorkspaces.update((prev) => {
      const updated = prev
        .map((item) => (item.id === id ? { ...item, pinned: !item.pinned } : item))
        .sort((a, b) => Number(b.pinned) - Number(a.pinned));
      this.saveStorage(RECENT_KEY, updated);
      return updated;
    });
  }

  public removeWorkspace(id: string): void {
    this.recentWorkspaces.update((prev) => {
      const next = prev.filter((item) => item.id !== id);
      this.saveStorage(RECENT_KEY, next);
      return next;
    });
  }

  public addSavedHost(wsUrl: string): void {
    const clean = wsUrl.trim();
    if (!clean) return;
    this.savedHosts.update((prev) => {
      const next = [clean, ...prev.filter((u) => u !== clean)].slice(0, 12);
      this.saveStorage(HOSTS_KEY, next);
      return next;
    });
  }

  public async listWorkspace(path: string, offset = 0, limit = 64): Promise<WorkspacePage | null> {
    return this.callCap(CAP_WORKSPACE, 'Workspace list failed', null, async (c) => {
      const page = await c.workspaceList({ path, offset, limit });
      this.workspacePage.set(page);
      return page;
    });
  }

  public statWorkspace(path: string): Promise<WorkspaceVersion | null> {
    return this.callCap(CAP_WORKSPACE, 'Workspace stat failed', null, (c) => c.workspaceStat(path));
  }

  public readWorkspaceFile(path: string, offset = 0n, length?: number): Promise<WorkspaceContents | null> {
    return this.callCap(CAP_WORKSPACE, 'Workspace read failed', null, (c) =>
      c.workspaceRead({ path, offset, length })
    );
  }

  public writeWorkspaceFile(args: WorkspaceWriteArgs): Promise<WorkspaceVersion | null> {
    return this.callCap(CAP_WORKSPACE, 'Workspace write failed', null, (c) => c.workspaceWrite(args));
  }

  public async watchWorkspace(path: string): Promise<number | null> {
    return this.callCap(CAP_WORKSPACE, 'Workspace watch failed', null, async (c) => {
      const id = await c.workspaceWatch(path);
      this.workspaceWatchIds.update((ids) => [...ids.filter((x) => x !== id), id]);
      return id;
    });
  }

  public async unwatchWorkspace(id: number): Promise<boolean> {
    return this.callCap(CAP_WORKSPACE, 'Workspace unwatch failed', false, async (c) => {
      const ok = await c.workspaceUnwatch(id);
      if (ok) this.workspaceWatchIds.update((ids) => ids.filter((x) => x !== id));
      return ok;
    });
  }

  public async startBuild(args: BuildStartArgs): Promise<bigint | null> {
    return this.callCap(CAP_BUILD, 'Build start failed', null, async (c) => {
      const id = await c.buildStart(args);
      this.activeBuildId.set(id);
      this.buildRunning.set(true);
      this.buildLog.set([`Started build #${id.toString()} (${args.step})`]);
      return id;
    });
  }

  public async pollBuildStatus(id = this.activeBuildId()): Promise<BuildStatus | null> {
    if (id === null) return null;
    return this.callCap(CAP_BUILD, 'Build status failed', null, async (c) => {
      const status = await c.buildStatus(id);
      this.buildStatus.set(status);
      if (status.done) this.buildRunning.set(false);
      return status;
    });
  }

  public async cancelBuild(id = this.activeBuildId()): Promise<boolean> {
    if (id === null) return false;
    return this.callCap(CAP_BUILD, 'Build cancel failed', false, async (c) => {
      const ok = await c.buildCancel(id);
      if (ok) this.buildRunning.set(false);
      return ok;
    });
  }

  public async openProject(config: string): Promise<boolean> {
    return this.callCap(CAP_PROJECT, 'Open project failed', false, async (c) => {
      const ok = await c.projectOpen(config);
      if (ok) this.activeProjectConfig.set(config);
      return ok;
    });
  }

  public async closeProject(): Promise<boolean> {
    return this.callCap(CAP_PROJECT, 'Close project failed', false, async (c) => {
      const ok = await c.projectClose();
      if (ok) {
        this.activeProjectConfig.set('');
        this.projectReceipt.set(null);
      }
      return ok;
    });
  }

  public async buildProject(recipe: string): Promise<bigint | null> {
    return this.callCap(CAP_PROJECT, 'Project build failed', null, async (c) => {
      const id = await c.projectBuild(recipe);
      this.activeBuildId.set(id);
      this.buildRunning.set(true);
      return id;
    });
  }

  public async prepareProject(id: bigint | number): Promise<ProjectPrepared | null> {
    return this.callCap(CAP_PROJECT, 'Prepare project failed', null, async (c) => {
      const prepared = await c.projectPrepare(id);
      this.projectReceipt.set(prepared.receipt);
      return prepared;
    });
  }

  public async refreshTargets(): Promise<TargetEntry[]> {
    return this.callCap(CAP_TARGETS, 'List targets failed', [], async (c) => {
      const res = await c.targetsList();
      this.targets.set(res.targets);
      return res.targets;
    });
  }

  public async reserveTarget(selection: TargetSelection): Promise<boolean> {
    return this.callCap(CAP_TARGETS, 'Reserve target failed', false, async (c) => {
      const ok = await c.targetsReserve(selection);
      if (ok) this.reservedTarget.set(selection);
      return ok;
    });
  }

  public async releaseTarget(): Promise<boolean> {
    return this.callCap(CAP_TARGETS, 'Release target failed', false, async (c) => {
      const ok = await c.targetsRelease();
      if (ok) this.reservedTarget.set(null);
      return ok;
    });
  }

  public async performTarget(args: TargetPerformArgs): Promise<string | null> {
    return this.callCap(CAP_TARGETS, 'Target action failed', null, async (c) => {
      const output = await c.targetsPerform(args);
      this.lastTargetOutput.set(output);
      return output;
    });
  }

  private async callCap<T>(
    cap: number,
    label: string,
    fallback: T,
    fn: (client: RA8RpcClient) => Promise<T>
  ): Promise<T> {
    const client = this.rpc.activeClient;
    if (!client || !this.rpc.hasCapability(cap)) return fallback;
    try {
      return await fn(client);
    } catch (err) {
      this.rpc.reportError(label, err);
      return fallback;
    }
  }

  private loadStorage<T>(key: string, fallback: T): T {
    if (typeof localStorage === 'undefined') return fallback;
    try {
      const raw = localStorage.getItem(key);
      return raw ? (JSON.parse(raw) as T) : fallback;
    } catch (err) {
      this.rpc.errorMessage.set(`Storage read error (${key}): ${err instanceof Error ? err.message : String(err)}`);
      return fallback;
    }
  }

  private saveStorage(key: string, value: unknown): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch (err) {
      this.rpc.errorMessage.set(`Storage write error (${key}): ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
