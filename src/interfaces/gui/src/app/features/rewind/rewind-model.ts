import {
  type BranchItem,
  Core,
  type DecodedDiff,
  type DiffPageItem,
  type DiffSide,
  ForkReason,
  type FrameStatusResult,
} from 'ra8-rpc-client';
import type { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import type { ExecutionStore } from '../../core/stores/execution.store';
import { type RewindStore, formatSeekPoint } from '../../core/stores/rewind.store';
import { formatHex32 } from '../../shared/utils/hex';
import type {
  RewindLayoutMode,
  RewindLayoutNode,
  RewindTreeBranchInput,
  RewindTreeLayout,
  RewindTreeNodeInput,
} from '../../shared/utils/rewind-layout';
import { buildSidewaysRewindLayout } from '../../shared/utils/rewind-layout';
import { hitTestDagCanvasNode, renderRewindDagCanvas } from './rewind-dag-render';

export interface RewindBookmark {
  name: string;
  place: string;
  branch: number;
  r: bigint;
  virtualNs: bigint;
  count?: bigint;
}

export interface RewindDiffSummary {
  liveBranchId: number;
  liveRound: string;
  hotFrames: string;
  regCount: number;
  pageCount: number;
  periphCount: number;
  totalChanges: number;
  roundSpan: string;
}

export function forkReasonLabel(reason: ForkReason): string {
  const names: Record<number, string> = {
    [ForkReason.Base]: 'BASE',
    [ForkReason.Writes]: 'WRITE',
    [ForkReason.Taps]: 'TOUCH',
    [ForkReason.Buttons]: 'GPIO',
    [ForkReason.Keystrokes]: 'UART',
    [ForkReason.PlugUnplugFault]: 'HIL',
    [ForkReason.CameraChange]: 'CAM',
    [ForkReason.SkipBkpt]: 'BKPT',
    [ForkReason.Load]: 'ELF',
  };
  return names[reason] ?? `R${reason}`;
}

export function validateBareSnapshotName(raw: string): string | null {
  const clean = raw.trim();
  if (!clean || clean.includes('/') || clean.includes('\\') || clean.includes('..')) {
    return null;
  }
  return clean;
}

export async function saveNamedSnapshot(rpc: RpcConnectionStore, rawName: string): Promise<boolean> {
  const bare = validateBareSnapshotName(rawName);
  const client = rpc.activeClient;
  if (!bare || !client || rpc.observeOnly()) return false;
  try {
    const ok = await client.snapshot(bare);
    if (ok) rpc.pushToast(`Saved snapshot ${bare}`);
    return ok;
  } catch (err) {
    rpc.reportError(`Save snapshot "${bare}" failed`, err);
    return false;
  }
}

export async function restoreNamedSnapshot(
  rpc: RpcConnectionStore,
  rewind: RewindStore,
  rawName: string,
  execution?: ExecutionStore
): Promise<boolean> {
  const bare = validateBareSnapshotName(rawName);
  const client = rpc.activeClient;
  if (!bare || !client || rpc.observeOnly()) return false;
  try {
    const ok = await client.restore(bare);
    if (ok) {
      if (execution) {
        await execution.refreshClock();
        execution.inspectionEpoch.update((n) => n + 1);
      }
      await rewind.refreshBranches();
      rpc.pushToast(`Restored snapshot ${bare}`);
    }
    return ok;
  } catch (err) {
    rpc.reportError(`Restore snapshot "${bare}" failed`, err);
    return false;
  }
}

export async function stepBackRewind(execution: ExecutionStore, rewind: RewindStore): Promise<void> {
  await execution.reverseContinue();
  await rewind.refreshBranches();
}

export async function stepForwardRewind(execution: ExecutionStore, rewind: RewindStore): Promise<void> {
  await execution.step();
  await rewind.refreshBranches();
}

export async function pauseRewind(
  execution: ExecutionStore,
  rewind: RewindStore,
  rpc?: RpcConnectionStore
): Promise<void> {
  const client = rpc?.activeClient;
  if (client && !rpc?.observeOnly()) {
    try {
      await client.pause(Core.Cpu0);
    } catch (err) {
      rpc?.noteOptionalError(err, 'Pause note');
    }
  }
  await execution.pause();
  await rewind.refreshBranches();
}

export async function advanceRewind(
  rpc: RpcConnectionStore,
  execution: ExecutionStore,
  rewind: RewindStore,
  ns = 8_000_000n
): Promise<boolean> {
  const client = rpc.activeClient;
  if (!client || rpc.observeOnly()) return false;
  try {
    const ok = await client.advance(Core.Cpu0, ns);
    await execution.refreshClock();
    execution.inspectionEpoch.update((n) => n + 1);
    await rewind.refreshBranches();
    return ok;
  } catch (err) {
    rpc.reportError('Advance failed', err);
    return false;
  }
}

export async function exportRewindBundle(rewind: RewindStore, rpc: RpcConnectionStore): Promise<boolean> {
  const res = await rewind.exportArtifactBundle(true);
  if (!res) return false;
  const bytes = new Uint8Array(res.bytes.byteLength);
  bytes.set(res.bytes);
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/x-tar' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'ra8-history-bundle.tar';
  link.click();
  URL.revokeObjectURL(url);
  rpc.pushToast(`Exported session archive (${bytes.length} B)`);
  return true;
}

export function formatDiffSideLabel(side: DiffSide): string {
  return `b${side.branch}:r${side.r.toString()}`;
}

export function formatHexOffset(offset: number): string {
  return `0x${(offset >>> 0).toString(16).padStart(2, '0')}`;
}

export function formatChangedMask(mask: number): string {
  return `0x${(mask >>> 0).toString(16)}`;
}

export function formatDiffPageStatus(page: DiffPageItem): string {
  if (page.hasA && page.hasB) return 'modified (4 KiB)';
  if (page.hasB) return 'allocated';
  if (page.hasA) return 'freed';
  return 'unchanged';
}

export function formatDiffPageHash(page: DiffPageItem): string {
  const src = page.hasB ? page.objB : page.objA;
  const hex = Array.from(src.slice(0, 4), (b) => b.toString(16).padStart(2, '0')).join('');
  return `${formatHex32(page.address)} · #${page.pageIndex} (${hex})`;
}

export function computeDiffSummary(
  diff: DecodedDiff | null,
  branches: readonly BranchItem[],
  frameStatus: FrameStatusResult | null
): RewindDiffSummary {
  const live = branches.find((b) => b.isLive) ?? branches[0];
  const regCount = diff?.regs.length ?? 0;
  const pageCount = diff?.pages.length ?? 0;
  const periphCount = diff?.periphs.length ?? 0;
  const spanRounds = diff ? (diff.b.r >= diff.a.r ? diff.b.r - diff.a.r : diff.a.r - diff.b.r) : 0n;
  return {
    liveBranchId: live?.id ?? 0,
    liveRound: live ? `r${live.recordedEndR.toString()}` : 'r0',
    hotFrames: frameStatus ? frameStatus.frames.toString() : '0',
    regCount,
    pageCount,
    periphCount,
    totalChanges: regCount + pageCount + periphCount,
    roundSpan: diff ? `${diff.b.r >= diff.a.r ? '+' : '-'}${spanRounds.toString()} rounds` : 'No span',
  };
}

export function buildDagLayoutFromBranches(
  branches: readonly BranchItem[],
  bookmarks: readonly RewindBookmark[],
  mode: RewindLayoutMode
): RewindTreeLayout {
  if (branches.length === 0) {
    return buildSidewaysRewindLayout([], [{ id: 'b0:0', label: '0', round: 0, timeSec: 0, branch: 0, isCursor: true }], mode);
  }
  const treeBranches: RewindTreeBranchInput[] = branches.map((b) => ({
    branch: b.id,
    parentBranch: b.parent,
    forkRound: Number(b.forkR),
    name: `Branch #${b.id}`,
    actor: b.reason === ForkReason.Base ? 'human' : 'agent',
    reasonBadge: forkReasonLabel(b.reason),
    isActive: b.isLive,
  }));

  const nodes: RewindTreeNodeInput[] = [];
  const seenKey = new Set<string>();
  const pushUnique = (node: RewindTreeNodeInput): void => {
    const key = `${node.branch}:${node.round}`;
    if (seenKey.has(key)) return;
    seenKey.add(key);
    nodes.push(node);
  };

  for (const b of branches) {
    const startRound = b.parent === b.id ? 0 : Number(b.forkR);
    pushUnique({
      id: formatSeekPoint(b.id, startRound),
      label: `#${b.id}:${startRound}`,
      round: startRound,
      timeSec: startRound * 0.001,
      branch: b.id,
      isJunction: b.childCount > 0,
      isCursor: false,
    });
    const endRound = Number(b.recordedEndR);
    if (endRound > startRound + 4) {
      const midRound = startRound + Math.floor((endRound - startRound) / 2);
      pushUnique({
        id: formatSeekPoint(b.id, midRound),
        label: `CP r${midRound}`,
        round: midRound,
        timeSec: midRound * 0.001,
        branch: b.id,
        isJunction: true,
      });
    }
    if (endRound >= startRound) {
      pushUnique({
        id: formatSeekPoint(b.id, endRound),
        label: b.isLive ? `Live r${endRound}` : `Tip r${endRound}`,
        round: endRound,
        timeSec: endRound * 0.001,
        branch: b.id,
        isCursor: b.isLive,
      });
    }
  }

  for (const bm of bookmarks) {
    const rNum = Number(bm.r);
    pushUnique({
      id: formatSeekPoint(bm.branch, bm.r),
      label: bm.name,
      round: rNum,
      timeSec: rNum * 0.001,
      branch: bm.branch,
      faultBadge: bm.name,
    });
  }
  return buildSidewaysRewindLayout(treeBranches, nodes, mode);
}

export function hitTestRewindNode(
  layout: RewindTreeLayout,
  x: number,
  y: number,
  cssWidth?: number,
  cssHeight?: number
): RewindLayoutNode | null {
  return hitTestDagCanvasNode(layout, x, y, cssWidth, cssHeight);
}

export function drawRewindDag(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  cssWidth: number,
  cssHeight: number,
  dpr: number,
  pointAId: string,
  pointBId: string,
  bookmarks: readonly RewindBookmark[] = []
): void {
  renderRewindDagCanvas(ctx, layout, cssWidth, cssHeight, dpr, pointAId, pointBId, bookmarks);
}
