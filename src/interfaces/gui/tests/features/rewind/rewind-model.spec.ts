import { ForkReason } from 'ra8-rpc-client';
import { normalizeSeekTarget } from '../../../src/app/core/stores/rewind-helpers';
import {
  buildDagLayoutFromBranches,
  forkReasonLabel,
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
    expect(normalizeSeekTarget('   ')).toBeNull();

    expect(validateBareSnapshotName('ckpt.ra8snap')).toBe('ckpt.ra8snap');
    expect(validateBareSnapshotName('../bad.ra8snap')).toBeNull();
    expect(validateBareSnapshotName('dir/file.ra8snap')).toBeNull();
  });

  it('builds spine and waterfall DAG layouts from live branches and hit-tests nodes', () => {
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
    const first = spine.nodes[0]!;
    expect(hitTestRewindNode(spine, first.x, first.y)?.id).toBe(first.id);
    expect(hitTestRewindNode(spine, -500, -500)).toBeNull();
  });
});
