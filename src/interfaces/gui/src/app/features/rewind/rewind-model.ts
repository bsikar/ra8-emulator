import { type BranchItem, ForkReason } from 'ra8-rpc-client';
import type { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { type RewindStore, formatSeekPoint } from '../../core/stores/rewind.store';
import type {
  RewindLayoutMode,
  RewindLayoutNode,
  RewindTreeBranchInput,
  RewindTreeLayout,
  RewindTreeNodeInput,
} from '../../shared/utils/rewind-layout';
import { buildSidewaysRewindLayout } from '../../shared/utils/rewind-layout';

export interface RewindBookmark {
  name: string;
  place: string;
  branch: number;
  r: bigint;
  virtualNs: bigint;
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
  rawName: string
): Promise<boolean> {
  const bare = validateBareSnapshotName(rawName);
  const client = rpc.activeClient;
  if (!bare || !client || rpc.observeOnly()) return false;
  try {
    const ok = await client.restore(bare);
    if (ok) {
      await rewind.refreshBranches();
      rpc.pushToast(`Restored snapshot ${bare}`);
    }
    return ok;
  } catch (err) {
    rpc.reportError(`Restore snapshot "${bare}" failed`, err);
    return false;
  }
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
  for (const b of branches) {
    const startRound = b.parent === b.id ? 0 : Number(b.forkR);
    nodes.push({
      id: formatSeekPoint(b.id, startRound),
      label: `#${b.id}:${startRound}`,
      round: startRound,
      timeSec: startRound * 0.001,
      branch: b.id,
      isJunction: b.childCount > 0,
      isCursor: false,
    });
    const endRound = Number(b.recordedEndR);
    if (endRound >= startRound) {
      nodes.push({
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
    nodes.push({
      id: formatSeekPoint(bm.branch, bm.r),
      label: bm.name,
      round: rNum,
      timeSec: rNum * 0.001,
      branch: bm.branch,
    });
  }
  return buildSidewaysRewindLayout(treeBranches, nodes, mode);
}

export function hitTestRewindNode(
  layout: RewindTreeLayout,
  x: number,
  y: number
): RewindLayoutNode | null {
  for (const node of layout.nodes) {
    const halfW = node.pillWidth / 2;
    if (x >= node.x - halfW && x <= node.x + halfW && y >= node.y - 16 && y <= node.y + 16) {
      return node;
    }
  }
  return null;
}

export function drawRewindDag(
  ctx: CanvasRenderingContext2D,
  layout: RewindTreeLayout,
  cssWidth: number,
  cssHeight: number,
  dpr: number,
  pointAId: string,
  pointBId: string
): void {
  ctx.save();
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssWidth, cssHeight);
  ctx.fillStyle = '#10131A';
  ctx.fillRect(0, 0, cssWidth, cssHeight);

  const byId = new Map(layout.nodes.map((n) => [n.id, n]));
  ctx.lineWidth = 1.5;
  for (const edge of layout.edges) {
    const from = byId.get(edge.fromId);
    const to = byId.get(edge.toId);
    if (!from || !to) continue;
    ctx.strokeStyle = edge.isActiveBranch ? '#8B9BB4' : '#2E3644';
    ctx.beginPath();
    const dx = Math.max(36, Math.abs(to.x - from.x) * 0.5);
    ctx.moveTo(from.x, from.y);
    ctx.bezierCurveTo(from.x + dx, from.y, to.x - dx, to.y, to.x, to.y);
    ctx.stroke();
  }

  ctx.font = '12px monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (const node of layout.nodes) {
    const halfW = node.pillWidth / 2;
    const isSelected = node.id === pointAId || node.id === pointBId || node.isCursor;
    ctx.fillStyle = node.isCursor ? '#242B35' : '#181C24';
    ctx.strokeStyle = isSelected ? '#F1F5F9' : '#3C4658';
    ctx.fillRect(node.x - halfW, node.y - 14, node.pillWidth, 28);
    ctx.strokeRect(node.x - halfW, node.y - 14, node.pillWidth, 28);
    ctx.fillStyle = node.isCursor ? '#F8FAFC' : '#CBD5E1';
    ctx.fillText(node.label, node.x, node.y);
  }
  ctx.restore();
}
