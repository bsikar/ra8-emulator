import {
  buildSidewaysRewindLayout,
  type RewindTreeBranchInput,
  type RewindTreeNodeInput,
} from '../../../src/app/shared/utils/rewind-layout';

describe('rewind-layout', () => {
  const branches: RewindTreeBranchInput[] = [
    { branch: 0, parentBranch: 0, forkRound: 0, name: 'Baseline', actor: 'human', reasonBadge: 'BASE' },
    { branch: 1, parentBranch: 0, forkRound: 904, name: 'Active Line', actor: 'agent', reasonBadge: 'W', isActive: true },
    { branch: 2, parentBranch: 1, forkRound: 912, name: 'Retry', actor: 'human', reasonBadge: 'B' },
  ];
  const nodes: RewindTreeNodeInput[] = [
    { id: 'n0', label: 'Reset', round: 0, timeSec: 0, branch: 0 },
    { id: 'n1', label: 'Init', round: 840, timeSec: 0.84, branch: 0 },
    { id: 'n2', label: 'Fork', round: 904, timeSec: 1.8, branch: 1, isJunction: true },
    { id: 'n3', label: 'Fault', round: 912, timeSec: 1.82, branch: 1, isCursor: true },
    { id: 'n4', label: 'Retry', round: 1280, timeSec: 2.56, branch: 2 },
  ];

  it('centers the active spine with +/- Y sibling lanes in spine mode', () => {
    const layout = buildSidewaysRewindLayout(branches, nodes, 'spine');
    const lane0 = layout.branchLanes.find((b) => b.branch === 0)!;
    const lane1 = layout.branchLanes.find((b) => b.branch === 1)!;
    const lane2 = layout.branchLanes.find((b) => b.branch === 2)!;
    expect(lane1.y).toBe(layout.spineY);
    expect(lane0.y).toBeLessThan(lane1.y);
    expect(lane2.y).toBeGreaterThan(lane1.y);
    expect(layout.edges.some((e) => e.isForkEdge && e.fromId === 'n1' && e.toId === 'n2')).toBe(true);
  });

  it('stacks branches monotonically downward in waterfall mode', () => {
    const layout = buildSidewaysRewindLayout(branches, nodes, 'waterfall');
    const ys = layout.branchLanes.map((b) => b.y);
    expect(ys[0]!).toBeLessThan(ys[1]!);
    expect(ys[1]!).toBeLessThan(ys[2]!);
  });
});
