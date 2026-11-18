import { Core, ForkReason, HistoryGap, HistoryPhase, LineOrder } from 'ra8-rpc-client';
import { normalizeSeekTarget } from '../../../src/app/core/stores/rewind-helpers';
import {
  buildDagLayoutFromBranches,
  computeDiffSummary,
  forkReasonLabel,
  formatChangedMask,
  formatDiffPageStatus,
  formatHexOffset,
  hitTestRewindNode,
  validateBareSnapshotName,
} from '../../../src/app/features/rewind/rewind-model';

describe('rewind-model and seek normalization', () => {
  it('normalizes user seek inputs into seek_target.zig syntax and validates bare snapshot names', () => {
    expect(normalizeSeekTarget('prev')).toBe('prev');
    expect(normalizeSeekTarget('@100us')).toBe('100us');
    expect(normalizeSeekTarget('frame:5')).toBe('frame 5');
    expect(normalizeSeekTarget('42')).toBe('iter 42');
    expect(normalizeSeekTarget('isr prev')).toBe('isr prev');
    expect(normalizeSeekTarget('rtos next')).toBe('rtos next');
    expect(normalizeSeekTarget('   ')).toBeNull();

    expect(validateBareSnapshotName('ckpt.ra8snap')).toBe('ckpt.ra8snap');
    expect(validateBareSnapshotName('../bad.ra8snap')).toBeNull();
    expect(validateBareSnapshotName('dir/file.ra8snap')).toBeNull();
  });

  it('builds spine and waterfall DAG layouts with intermediate checkpoints and hit-tests nodes', () => {
    const branches = [
      {
        id: 0,
        parent: 0,
        forkR: 0n,
        recordedEndR: 40n,
        childCount: 1,
        reason: ForkReason.Base,
        flags: 0,
        isLive: false,
        isKept: true,
        isPinned: false,
      },
      {
        id: 1,
        parent: 0,
        forkR: 20n,
        recordedEndR: 60n,
        childCount: 0,
        reason: ForkReason.Writes,
        flags: 0,
        isLive: true,
        isKept: false,
        isPinned: false,
      },
    ];
    expect(forkReasonLabel(ForkReason.Writes)).toBe('WRITE');

    const spine = buildDagLayoutFromBranches(branches, [], 'spine');
    expect(spine.edges.some((e) => e.isForkEdge)).toBe(true);
    expect(spine.nodes.some((n) => n.label.startsWith('CP r'))).toBe(true);
    const first = spine.nodes[0]!;
    expect(hitTestRewindNode(spine, first.x, first.y)?.id).toBe(first.id);
    expect(hitTestRewindNode(spine, -500, -500)).toBeNull();
  });

  it('formats diff page statuses, offsets, masks, and summary counts accurately', () => {
    expect(formatHexOffset(0x14)).toBe('0x14');
    expect(formatChangedMask(0x0f)).toBe('0xf');
    expect(
      formatDiffPageStatus({
        space: 0,
        pageIndex: 1,
        address: 0x2000_0000,
        hasA: true,
        objA: new Uint8Array(16),
        hasB: true,
        objB: new Uint8Array(16),
      })
    ).toBe('modified (4 KiB)');
    expect(
      formatDiffPageStatus({
        space: 0,
        pageIndex: 2,
        address: 0x2000_1000,
        hasA: false,
        objA: new Uint8Array(16),
        hasB: true,
        objB: new Uint8Array(16),
      })
    ).toBe('allocated');

    const summary = computeDiffSummary(
      {
        frames: 4,
        a: { branch: 0, r: 0n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
        b: { branch: 0, r: 16n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
        order: LineOrder.Lt,
        regs: [{ core: Core.Cpu0, name: 'pc', valA: 1, valB: 2 }],
        pages: [],
        periphs: [{ unit: 'SCI8', offset: 0, oldVal: 0, newVal: 1, changedBytes: 1 }],
      },
      [
        {
          id: 0,
          parent: 0,
          forkR: 0n,
          recordedEndR: 16n,
          childCount: 0,
          reason: ForkReason.Base,
          flags: 1,
          isLive: true,
          isKept: false,
          isPinned: false,
        },
      ],
      { ramBytes: 4096n, diskBytes: 8192n, queueBytes: 0n, frames: 5n, decodedSegments: 2n }
    );
    expect(summary.totalChanges).toBe(2);
    expect(summary.roundSpan).toBe('+16 rounds');
    expect(summary.hotFrames).toBe('5');
  });
});
