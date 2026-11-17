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

export { formatSeekPoint, isPendingForkError, mapDiffRows, type DiffStateRow };

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

  public async previewStagedArchive(bytes: Uint8Array): Promise<BundlePreview | null> {
    try {
      const preview = await previewBundleArchive(bytes);
      this.stagedBundleBytes.set(bytes);
      this.stagedBundlePreview.set(preview);
      return preview;
    } catch (err) {
      this.stagedBundleBytes.set(null);
      this.stagedBundlePreview.set(null);
      this.rpc.reportError('Invalid session bundle archive', err);
      return null;
    }
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
  }
}
