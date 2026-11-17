import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import {
  type ArtifactCommit,
  type ArtifactExportResult,
  type BranchItem,
  type BundlePreview,
  CAP_ARTIFACTS,
  type DecodedDiff,
  Direction,
  EventKind,
  type ForkStatus,
  type FrameStatusResult,
  type NavQueryArgs,
  type NavQueryResult,
  type SessionEvent,
  previewBundleArchive,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { ExecutionStore } from './execution.store';
import {
  type DiffStateRow,
  formatSeekPoint,
  isPendingForkError,
  mapDiffRows,
} from './rewind-helpers';
import type { RecentBundleEntry } from '../../features/bundles/bundle-summary';

export { formatSeekPoint, isPendingForkError, mapDiffRows, type DiffStateRow, type RecentBundleEntry };

const RECENT_BUNDLES_KEY = 'ra8.recentBundles.v1';

@Injectable({ providedIn: 'root' })
export class RewindStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly subs = new Subscription();

  public readonly branches = signal<BranchItem[]>([]);
  public readonly historySupported = signal<boolean>(false);
  public readonly forkStatus = signal<ForkStatus | null>(null);
  public readonly frameStatus = signal<FrameStatusResult | null>(null);
  public readonly pendingForkPrompt = signal<boolean>(false);
  public readonly activeDiff = signal<DecodedDiff | null>(null);
  public readonly lastNavResult = signal<NavQueryResult | null>(null);
  public readonly stagedBundlePreview = signal<BundlePreview | null>(null);
  public readonly stagedBundleBytes = signal<Uint8Array | null>(null);
  public readonly stagedBundleFileName = signal<string | null>(null);
  public readonly stagedBundleSizeBytes = signal<number>(0);
  public readonly stagedBundleError = signal<string | null>(null);
  public readonly recentBundles = signal<RecentBundleEntry[]>(this.loadRecentBundles());
  public readonly diffRows = computed<DiffStateRow[]>(() =>
    this.activeDiff() ? mapDiffRows(this.activeDiff()!) : []
  );

  constructor() {
    this.subs.add(this.rpc.connected$.subscribe(() => void this.refreshBranches()));
    this.subs.add(this.rpc.disconnected$.subscribe(() => this.resetState()));
    this.subs.add(this.rpc.session$.subscribe((evt) => this.handleSessionEvent(evt)));
  }

  public async refreshBranches(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.branches.set(await client.getBranches());
      this.historySupported.set(true);
    } catch (err) {
      this.historySupported.set(false);
      this.rpc.noteOptionalError(err);
    }
    try {
      const status = await client.getForkStatus();
      this.forkStatus.set(status);
      this.pendingForkPrompt.set(status.pending);
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
    try {
      this.frameStatus.set(await client.getFrameStatus());
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
  }

  public async seekTo(target: string): Promise<boolean> {
    const client = this.rpc.activeClient;
    const clean = target.trim();
    if (!client || !clean) return false;
    try {
      const ok = await client.seek(clean);
      if (ok) await this.refreshAfterHistoryChange();
      return ok;
    } catch (err) {
      if (isPendingForkError(err)) this.pendingForkPrompt.set(true);
      this.rpc.reportError(`Seek("${clean}") failed`, err);
      return false;
    }
  }

  public seekPrev(): Promise<boolean> {
    return this.seekTo('prev');
  }

  public seekZero(): Promise<boolean> {
    return this.seekTo('0ns');
  }

  public seekPoint(branch: number, r: bigint | number): Promise<boolean> {
    return this.seekTo(formatSeekPoint(branch, r));
  }

  public async switchBranch(branchId: number): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      const ok = await client.switchBranch(branchId);
      if (ok) await this.refreshAfterHistoryChange();
      return ok;
    } catch (err) {
      this.rpc.reportError(`Switch branch #${branchId} failed`, err);
      return false;
    }
  }

  public async deleteBranch(branchId: number, confirm = false): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      const ok = await client.deleteBranch(branchId, confirm);
      if (ok) await this.refreshBranches();
      return ok;
    } catch (err) {
      this.rpc.reportError(`Delete branch #${branchId} failed`, err);
      return false;
    }
  }

  public async confirmFork(): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      const ok = await client.confirmFork(true);
      this.pendingForkPrompt.set(false);
      await this.refreshBranches();
      return ok;
    } catch (err) {
      this.rpc.reportError('Confirm fork failed', err);
      return false;
    }
  }

  public async cancelFork(): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      const ok = await client.cancelFork();
      this.pendingForkPrompt.set(false);
      await this.refreshBranches();
      return ok;
    } catch (err) {
      this.rpc.reportError('Cancel fork failed', err);
      return false;
    }
  }

  public async play(dir: Direction = Direction.Fwd, speedMilli = 1000n): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      return await client.play(dir, speedMilli);
    } catch (err) {
      this.rpc.reportError('History play failed', err);
      return false;
    }
  }

  public async navQuery(args: NavQueryArgs): Promise<NavQueryResult | null> {
    const client = this.rpc.activeClient;
    if (!client) return null;
    try {
      const res = await client.navQuery(args);
      this.lastNavResult.set(res);
      return res;
    } catch (err) {
      this.rpc.reportError('Navigation query failed', err);
      return null;
    }
  }

  public async setMarker(name: string, place: string): Promise<NavQueryResult | null> {
    const client = this.rpc.activeClient;
    if (!client) return null;
    try {
      const res = await client.setMarker(name, place);
      this.lastNavResult.set(res);
      return res;
    } catch (err) {
      this.rpc.reportError('Set marker failed', err);
      return null;
    }
  }

  public async compareDiff(pointA: string, pointB: string): Promise<DecodedDiff | null> {
    const client = this.rpc.activeClient;
    if (!client) return null;
    try {
      const diff = await client.getDiff(pointA, pointB);
      this.activeDiff.set(diff);
      return diff;
    } catch (err) {
      this.activeDiff.set(null);
      this.rpc.reportError('State diff failed', err);
      return null;
    }
  }

  public async previewStagedArchive(bytes: Uint8Array, fileName = 'session.tar'): Promise<BundlePreview | null> {
    this.stagedBundleFileName.set(fileName);
    this.stagedBundleSizeBytes.set(bytes.length);
    try {
      const preview = await previewBundleArchive(bytes);
      this.stagedBundleError.set(null);
      this.stagedBundleBytes.set(bytes);
      this.stagedBundlePreview.set(preview);
      return preview;
    } catch (err) {
      this.stagedBundleBytes.set(null);
      this.stagedBundlePreview.set(null);
      this.stagedBundleError.set(err instanceof Error ? err.message : String(err));
      this.rpc.reportError('Invalid session bundle archive', err);
      return null;
    }
  }

  public recordRecentBundle(preview: BundlePreview, fileName: string, sizeBytes: number, path?: string): RecentBundleEntry {
    const cleanName = fileName.trim() || 'session.tar';
    const m = preview.manifest;
    const entry: RecentBundleEntry = {
      id: `bun:${cleanName}:${sizeBytes}`,
      name: cleanName.replace(/\.(tar\.gz|tgz|tar)$/i, ''),
      path: path?.trim() || cleanName,
      sizeBytes,
      compressed: preview.compressed,
      board: m?.board ?? 'Custom Session',
      elfSummary: m?.elf1 ? `${m.elf0.name} + ${m.elf1.name}` : (m?.elf0.name ?? `${preview.entries.length} entries`),
      hasSaveState: preview.entries.some((e) => e.path.endsWith('.ra8snap')),
      recording: m?.recording ?? false,
      entryCount: preview.entries.length,
      importedIso: new Date().toISOString(),
    };
    this.recentBundles.update((prev) => {
      const next = [entry, ...prev.filter((b) => b.id !== entry.id)].slice(0, 12);
      this.saveRecentBundles(next);
      return next;
    });
    return entry;
  }

  public removeRecentBundle(id: string): void {
    this.recentBundles.update((prev) => {
      const next = prev.filter((b) => b.id !== id);
      this.saveRecentBundles(next);
      return next;
    });
  }

  public async exportArtifactBundle(recording = false): Promise<ArtifactExportResult | null> {
    const client = this.rpc.activeClient;
    if (!client || !this.rpc.hasCapability(CAP_ARTIFACTS)) return null;
    try {
      return await client.exportArtifact(recording);
    } catch (err) {
      this.rpc.reportError('Artifact export failed', err);
      return null;
    }
  }

  public async importArtifactBundle(bytes: Uint8Array): Promise<ArtifactCommit | null> {
    const client = this.rpc.activeClient;
    if (!client || !this.rpc.hasCapability(CAP_ARTIFACTS)) return null;
    try {
      const commit = await client.importArtifact(bytes);
      if (commit.accepted) {
        this.stagedBundleBytes.set(null);
        this.stagedBundlePreview.set(null);
        await this.refreshAfterHistoryChange();
      }
      return commit;
    } catch (err) {
      this.rpc.reportError('Artifact import failed', err);
      return null;
    }
  }

  public ngOnDestroy(): void {
    this.subs.unsubscribe();
  }

  private async refreshAfterHistoryChange(): Promise<void> {
    await this.execution.refreshClock();
    this.execution.inspectionEpoch.update((n) => n + 1);
    await this.refreshBranches();
  }

  private handleSessionEvent(evt: SessionEvent): void {
    if (evt.kind !== EventKind.Rewound) return;
    void this.refreshAfterHistoryChange();
  }

  private resetState(): void {
    this.branches.set([]);
    this.historySupported.set(false);
    this.forkStatus.set(null);
    this.frameStatus.set(null);
    this.pendingForkPrompt.set(false);
    this.activeDiff.set(null);
    this.lastNavResult.set(null);
    this.stagedBundlePreview.set(null);
    this.stagedBundleBytes.set(null);
    this.stagedBundleFileName.set(null);
    this.stagedBundleSizeBytes.set(0);
    this.stagedBundleError.set(null);
  }

  private loadRecentBundles(): RecentBundleEntry[] {
    if (typeof localStorage === 'undefined') return [];
    try {
      const raw = localStorage.getItem(RECENT_BUNDLES_KEY);
      if (!raw) return [];
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as RecentBundleEntry[]) : [];
    } catch (err) {
      this.rpc.noteOptionalError(err, 'Recent bundles storage');
      return [];
    }
  }

  private saveRecentBundles(list: readonly RecentBundleEntry[]): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(RECENT_BUNDLES_KEY, JSON.stringify(list));
    } catch (err) {
      this.rpc.errorMessage.set(`Bundle storage write failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
