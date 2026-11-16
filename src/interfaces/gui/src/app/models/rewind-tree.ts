export interface RewindTreeBranchInput {
  branch: number;
  parentBranch: number;
  forkRound: number;
  name: string;
  actor: 'human' | 'agent' | string;
  reasonBadge: string;
  isActive?: boolean;
}

export interface RewindTreeNodeInput {
  id: string;
  label: string;
  round: number;
  timeSec: number;
  branch: number;
  isJunction?: boolean;
  isCursor?: boolean;
  faultBadge?: string;
}

export interface RewindLayoutNode extends RewindTreeNodeInput {
  x: number;
  y: number;
  laneIndex: number;
  branchName: string;
  actor: string;
  reasonBadge: string;
  isActiveBranch: boolean;
  pillWidth: number;
}

export interface RewindLayoutEdge {
  id: string;
  fromId: string;
  toId: string;
  branch: number;
  isForkEdge: boolean;
  isActiveBranch: boolean;
  pathD: string;
}

export interface RewindTreeLayout {
  width: number;
  height: number;
  laneCount: number;
  nodes: RewindLayoutNode[];
  edges: RewindLayoutEdge[];
  branchLanes: Array<RewindTreeBranchInput & { y: number; laneIndex: number }>;
}

const LEFT_PAD = 112;
const COL_STEP = 196;
const TOP_PAD = 56;
const LANE_STEP = 88;

function bezierPath(x1: number, y1: number, x2: number, y2: number): string {
  const dx = Math.max(40, Math.abs(x2 - x1) * 0.5);
  const cx1 = Math.round(x1 + dx);
  const cx2 = Math.round(x2 - dx);
  return `M ${Math.round(x1)} ${Math.round(y1)} C ${cx1} ${Math.round(y1)}, ${cx2} ${Math.round(y2)}, ${Math.round(x2)} ${Math.round(y2)}`;
}

export function buildSidewaysRewindLayout(
  branches: readonly RewindTreeBranchInput[],
  nodes: readonly RewindTreeNodeInput[]
): RewindTreeLayout {
  const branchList =
    branches.length > 0
      ? [...branches].sort((a, b) => a.branch - b.branch)
      : [{ branch: 0, parentBranch: 0, forkRound: 0, name: 'Branch 0 · Baseline', actor: 'human', reasonBadge: 'BASE', isActive: true }];

  const laneByBranch = new Map<number, number>();
  const branchMap = new Map<number, RewindTreeBranchInput>();
  branchList.forEach((b, idx) => {
    laneByBranch.set(b.branch, idx);
    branchMap.set(b.branch, b);
  });

  const sortedNodes = [...nodes].sort(
    (a, b) => a.round - b.round || a.timeSec - b.timeSec || a.branch - b.branch || a.id.localeCompare(b.id)
  );

  // Assign monotonically advancing horizontal columns for strictly later timestamps.
  const colIndexById = new Map<string, number>();
  let colIdx = -1;
  let lastKey = '';
  for (const n of sortedNodes) {
    const key = `${n.round}:${Math.round(n.timeSec * 1000)}`;
    if (key !== lastKey) {
      colIdx += 1;
      lastKey = key;
    }
    colIndexById.set(n.id, colIdx);
  }

  const layoutNodes: RewindLayoutNode[] = sortedNodes.map((n) => {
    const laneIndex = laneByBranch.get(n.branch) ?? 0;
    const branchMeta = branchMap.get(n.branch);
    const col = colIndexById.get(n.id) ?? 0;
    const pillWidth = Math.min(184, Math.max(128, n.label.length * 7 + 34));
    return {
      ...n,
      x: LEFT_PAD + col * COL_STEP,
      y: TOP_PAD + laneIndex * LANE_STEP,
      laneIndex,
      branchName: branchMeta?.name ?? `Branch ${n.branch}`,
      actor: branchMeta?.actor ?? 'human',
      reasonBadge: branchMeta?.reasonBadge ?? 'BASE',
      isActiveBranch: Boolean(branchMeta?.isActive),
      pillWidth,
    };
  });

  const edges: RewindLayoutEdge[] = [];
  const byBranch = new Map<number, RewindLayoutNode[]>();
  for (const node of layoutNodes) {
    const list = byBranch.get(node.branch) ?? [];
    list.push(node);
    byBranch.set(node.branch, list);
  }

  for (const [branchId, list] of byBranch.entries()) {
    list.sort((a, b) => a.x - b.x);
    for (let i = 1; i < list.length; i++) {
      const prev = list[i - 1];
      const curr = list[i];
      edges.push({
        id: `e_${prev.id}_${curr.id}`,
        fromId: prev.id,
        toId: curr.id,
        branch: branchId,
        isForkEdge: false,
        isActiveBranch: curr.isActiveBranch,
        pathD: bezierPath(prev.x, prev.y, curr.x, curr.y),
      });
    }

    const meta = branchMap.get(branchId);
    if (meta && meta.parentBranch !== branchId && list.length > 0) {
      const childHead = list[0];
      const parentNodes = (byBranch.get(meta.parentBranch) ?? layoutNodes.filter((n) => n.x < childHead.x))
        .slice()
        .sort((a, b) => a.x - b.x);
      const anchor =
        parentNodes.filter((p) => p.round <= meta.forkRound && p.x <= childHead.x).pop() ??
        parentNodes.filter((p) => p.x < childHead.x).pop();
      if (anchor) {
        edges.push({
          id: `fork_${anchor.id}_${childHead.id}`,
          fromId: anchor.id,
          toId: childHead.id,
          branch: branchId,
          isForkEdge: true,
          isActiveBranch: childHead.isActiveBranch,
          pathD: bezierPath(anchor.x, anchor.y, childHead.x, childHead.y),
        });
      }
    }
  }

  const maxX = layoutNodes.reduce((acc, n) => Math.max(acc, n.x + n.pillWidth * 0.6), 420);
  const width = Math.max(680, Math.round(maxX + 64));
  const height = Math.max(190, TOP_PAD * 2 + Math.max(0, branchList.length - 1) * LANE_STEP);

  const branchLanes = branchList.map((b, laneIndex) => ({
    ...b,
    laneIndex,
    y: TOP_PAD + laneIndex * LANE_STEP,
  }));

  return {
    width,
    height,
    laneCount: branchList.length,
    nodes: layoutNodes,
    edges,
    branchLanes,
  };
}
