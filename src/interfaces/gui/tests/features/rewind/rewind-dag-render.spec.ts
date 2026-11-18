import { ForkReason } from 'ra8-rpc-client';
import {
  computeDagTransform,
  hitTestDagCanvasNode,
  renderRewindDagCanvas,
  resolveDagPins,
} from '../../../src/app/features/rewind/rewind-dag-render';
import { type RewindBookmark, buildDagLayoutFromBranches as buildLayout } from '../../../src/app/features/rewind/rewind-model';

const SAMPLE_BRANCHES = [
  {
    id: 0,
    parent: 0,
    forkR: 0n,
    recordedEndR: 24n,
    childCount: 1,
    reason: ForkReason.Base,
    flags: 2,
    isLive: false,
    isKept: true,
    isPinned: false,
  },
  {
    id: 1,
    parent: 0,
    forkR: 12n,
    recordedEndR: 36n,
    childCount: 0,
    reason: ForkReason.Writes,
    flags: 1,
    isLive: true,
    isKept: false,
    isPinned: false,
  },
];

describe('rewind-dag-render', () => {
  it('resolves Point A and Point B pins across start, latest, bookmark, and branch:round specs', () => {
    const bookmarks: RewindBookmark[] = [
      { name: 'irq_hit', place: '0x02000040', branch: 1, r: 20n, virtualNs: 1000n, count: 1n },
    ];
    const layout = buildLayout(SAMPLE_BRANCHES, bookmarks, 'spine');

    const defaultPins = resolveDagPins(layout, '0', 'latest');
    expect(defaultPins.pointANode?.branch).toBe(0);
    expect(defaultPins.pointANode?.round).toBe(0);
    expect(defaultPins.pointBNode?.isCursor).toBe(true);

    const bmPins = resolveDagPins(layout, '0:0:cpu0:0:retired', 'bm irq_hit');
    expect(bmPins.pointBNode?.label).toBe('irq_hit');

    const roundPins = resolveDagPins(layout, '0:12', '1:36');
    expect(roundPins.pointANode?.round).toBe(12);
    expect(roundPins.pointBNode?.round).toBe(36);
  });

  it('scales wide DAG coordinates to canvas width and matches hit-testing under viewport transform', () => {
    const layout = buildLayout(SAMPLE_BRANCHES, [], 'waterfall');
    const tf = computeDagTransform(layout, 480, 260);
    expect(tf.scaleX).toBeLessThanOrEqual(1);
    expect(tf.offsetY).toBeGreaterThanOrEqual(28);

    const target = layout.nodes[1]!;
    const screenX = target.x * tf.scaleX + tf.offsetX;
    const screenY = target.y + tf.offsetY;
    expect(hitTestDagCanvasNode(layout, screenX, screenY, 480, 260)?.id).toBe(target.id);
    expect(hitTestDagCanvasNode(layout, -100, -100, 480, 260)).toBeNull();
  });

  it('draws ruler, diamond checkpoints, and pins onto a 2D canvas context without throwing', () => {
    const layout = buildLayout(SAMPLE_BRANCHES, [], 'spine');
    const ops: string[] = [];
    const stubCtx = {
      save: () => ops.push('save'),
      restore: () => ops.push('restore'),
      setTransform: () => undefined,
      clearRect: () => undefined,
      fillRect: () => undefined,
      strokeRect: () => undefined,
      beginPath: () => undefined,
      closePath: () => undefined,
      moveTo: () => undefined,
      lineTo: () => undefined,
      bezierCurveTo: () => undefined,
      stroke: () => undefined,
      fill: () => undefined,
      fillText: (t: string) => ops.push(`text:${t}`),
      setLineDash: () => undefined,
      fillStyle: '',
      strokeStyle: '',
      lineWidth: 1,
      font: '',
      textAlign: 'left',
      textBaseline: 'top',
    } as unknown as CanvasRenderingContext2D;

    renderRewindDagCanvas(stubCtx, layout, 800, 320, 2, '0', 'latest', []);
    expect(ops).toContain('save');
    expect(ops).toContain('restore');
    expect(ops).toContain('text:A');
    expect(ops).toContain('text:B');
  });
});
