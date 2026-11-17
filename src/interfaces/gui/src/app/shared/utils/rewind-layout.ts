export type RewindLayoutMode = 'spine' | 'waterfall';

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
  mode: RewindLayoutMode;
  width: number;
  height: number;
  laneCount: number;
  spineY: number;
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
  return `M ${Math.round(x1)} ${Math.round(y1)} C ${Math.round(x1 + dx)} ${Math.round(y1)}, ${Math.round(x2 - dx)} ${Math.round(y2)}, ${Math.round(x2)} ${Math.round(y2)}`;
}

function assignLanePositions(
  branches: readonly RewindTreeBranchInput[],
  mode: RewindLayoutMode
): { laneByBranch: Map<number, number>; yByBranch: Map<number, number>; spineY: number } {
  const laneByBranch = new Map<number, number>();
  const yByBranch = new Map<number, number>();
  if (mode === 'waterfall') {
    branches.forEach((b, idx) => {
      laneByBranch.set(b.branch, idx);
      yByBranch.set(b.branch, TOP_PAD + idx * LANE_STEP);
    });
    return { laneByBranch, yByBranch, spineY: TOP_PAD };
  }

  const active = branches.find((b) => b.isActive) ?? branches[0];
  const others = branches.filter((b) => b.branch !== active?.branch);
  const offsets = new Map<number, number>();
  if (active) offsets.set(active.branch, 0);
  others.forEach((b, idx) => {
    const mag = Math.floor(idx / 2) + 1;
    offsets.set(b.branch, idx % 2 === 0 ? -mag : mag);
  });

  let minOff = 0;
  for (const off of offsets.values()) minOff = Math.min(minOff, off);
  const spineY = TOP_PAD + Math.abs(minOff) * LANE_STEP;
  branches.forEach((b, idx) => {
    laneByBranch.set(b.branch, idx);
    yByBranch.set(b.branch, spineY + (offsets.get(b.branch) ?? 0) * LANE_STEP);
  });
  return { laneByBranch, yByBranch, spineY };
}

function makeEdge(from: RewindLayoutNode, to: RewindLayoutNode, branch: number, isForkEdge: boolean): RewindLayoutEdge {
  return {
    id: `${isForkEdge ? 'fork' : 'e'}_${from.id}_${to.id}`,
    fromId: from.id,
    toId: to.id,
    branch,
    isForkEdge,
    isActiveBranch: to.isActiveBranch,
    pathD: bezierPath(from.x, from.y, to.x, to.y),
  };
}

function buildEdges(
  layoutNodes: readonly RewindLayoutNode[],
  branchMap: ReadonlyMap<number, RewindTreeBranchInput>
): RewindLayoutEdge[] {
  const edges: RewindLayoutEdge[] = [];
  const byBranch = new Map<number, RewindLayoutNode[]>();
  for (const node of layoutNodes) {
    const list = byBranch.get(node.branch) ?? [];
    list.push(node);
    byBranch.set(node.branch, list);
  }
  for (const [branchId, list] of byBranch.entries()) {
    list.sort((a, b) => a.x - b.x);
    for (let i = 1; i < list.length; i++) edges.push(makeEdge(list[i - 1]!, list[i]!, branchId, false));
    const meta = branchMap.get(branchId);
    const childHead = list[0];
    if (meta && childHead && meta.parentBranch !== branchId) {
      const parentNodes = (byBranch.get(meta.parentBranch) ?? layoutNodes.filter((n) => n.x < childHead.x))
        .slice()
        .sort((a, b) => a.x - b.x);
      const anchor =
        parentNodes.filter((p) => p.round <= meta.forkRound && p.x <= childHead.x).pop() ??
        parentNodes.filter((p) => p.x < childHead.x).pop();
      if (anchor) edges.push(makeEdge(anchor, childHead, branchId, true));
    }
  }
  return edges;
}

export function buildSidewaysRewindLayout(
  branches: readonly RewindTreeBranchInput[],
  nodes: readonly RewindTreeNodeInput[],
  mode: RewindLayoutMode = 'spine'
): RewindTreeLayout {
  const branchList = branches.length > 0
    ? [...branches].sort((a, b) => a.branch - b.branch)
    : [{ branch: 0, parentBranch: 0, forkRound: 0, name: 'Branch 0', actor: 'human', reasonBadge: 'BASE', isActive: true }];

  const branchMap = new Map<number, RewindTreeBranchInput>();
  branchList.forEach((b) => branchMap.set(b.branch, b));
  const { laneByBranch, yByBranch, spineY } = assignLanePositions(branchList, mode);

  const sortedNodes = [...nodes].sort(
    (a, b) => a.round - b.round || a.timeSec - b.timeSec || a.branch - b.branch || a.id.localeCompare(b.id)
  );
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
    const branchMeta = branchMap.get(n.branch);
    return {
      ...n,
      x: LEFT_PAD + (colIndexById.get(n.id) ?? 0) * COL_STEP,
      y: yByBranch.get(n.branch) ?? TOP_PAD,
      laneIndex: laneByBranch.get(n.branch) ?? 0,
      branchName: branchMeta?.name ?? `Branch ${n.branch}`,
      actor: branchMeta?.actor ?? 'human',
      reasonBadge: branchMeta?.reasonBadge ?? 'BASE',
      isActiveBranch: Boolean(branchMeta?.isActive),
      pillWidth: Math.min(184, Math.max(128, n.label.length * 7 + 34)),
    };
  });

  const maxX = layoutNodes.reduce((acc, n) => Math.max(acc, n.x + n.pillWidth * 0.6), 420);
  const maxY = Array.from(yByBranch.values()).reduce((acc, y) => Math.max(acc, y), TOP_PAD);
  return {
    mode,
    width: Math.max(680, Math.round(maxX + 64)),
    height: Math.max(190, Math.round(maxY + TOP_PAD)),
    laneCount: branchList.length,
    spineY,
    nodes: layoutNodes,
    edges: buildEdges(layoutNodes, branchMap),
    branchLanes: branchList.map((b, laneIndex) => ({ ...b, laneIndex, y: yByBranch.get(b.branch) ?? TOP_PAD })),
  };
}
