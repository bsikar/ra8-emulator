import { TestBed } from '@angular/core/testing';
import {
  CAP_ARTIFACTS,
  Core,
  type DecodedDiff,
  ErrorCode,
  EventKind,
  HistoryGap,
  HistoryPhase,
  InputKind,
  LineOrder,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore, decodeLedEvent } from '../../../src/app/core/stores/board.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';
import {
  RewindStore,
  formatSeekPoint,
  isPendingForkError,
  mapDiffRows,
} from '../../../src/app/core/stores/rewind.store';

function buildMinimalBundleTar(manifest: Record<string, unknown>): Uint8Array {
  const payload = new TextEncoder().encode(JSON.stringify(manifest));
  const paddedLen = Math.ceil(payload.length / 512) * 512;
  const tar = new Uint8Array(512 + paddedLen + 1024);
  const enc = new TextEncoder();
  tar.set(enc.encode('manifest.json'), 0);
  tar.set(enc.encode('0000644\0'), 100);
  tar.set(enc.encode('0000000\0'), 108);
  tar.set(enc.encode('0000000\0'), 116);
  tar.set(enc.encode(`${payload.length.toString(8).padStart(11, '0')}\0`), 124);
  tar.set(enc.encode('00000000000\0'), 136);
  tar.fill(0x20, 148, 156);
  tar[156] = 0x30;
  tar.set(enc.encode('ustar\0'), 257);
  tar.set(enc.encode('00'), 263);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += tar[i] ?? 0;
  tar.set(enc.encode(`${sum.toString(8).padStart(6, '0')}\0 `), 148);
  tar.set(payload, 512);
  return tar;
}

describe('BoardStore and RewindStore fixed wire semantics', () => {
  it('decodes EventKind.LedChanged as index (bits 0..7) + level (bit 8) instead of bitmask', () => {
    expect(decodeLedEvent(0x0102)).toEqual({ index: 2, on: true });
    expect(decodeLedEvent(0x0002)).toEqual({ index: 2, on: false });

    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);

    rpc.session$.next({ core: Core.Cpu0, kind: EventKind.LedChanged, address: 0x0101 });
    expect(board.ledStates()[1]).toBe(true);
    expect(board.ledStates()[0]).toBe(false);

    rpc.session$.next({ core: Core.Cpu0, kind: EventKind.LedChanged, address: 0x0001 });
    expect(board.ledStates()[1]).toBe(false);
  });

  it('passes atNs = virtualTimeNs for sendTouch and sendButton instead of 0n', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const board = TestBed.inject(BoardStore);

    const calls: Array<{ atNs: bigint; kind: InputKind }> = [];
    const fakeClient = {
      sendInput: async (args: { atNs: bigint; kind: InputKind }) => {
        calls.push({ atNs: args.atNs, kind: args.kind });
        return true;
      },
    };
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });
    execution.virtualTimeNs.set(42_500_000n);

    await board.sendTouch(InputKind.Tap, 120, 80);
    await board.sendButton(0);

    expect(calls).toEqual([
      { atNs: 42_500_000n, kind: InputKind.Tap },
      { atNs: 42_500_000n, kind: InputKind.Button },
    ]);
  });

  it('parses official board presets, exports `.board` text, and rejects malformed profiles', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);

    const preset = board.selectBoardPreset('ra8p1');
    expect(preset?.silicon).toBe('ra8p1');
    expect(board.selectedPreset()?.partNumber).toBe('RTK7EKA8P1S01001BE');
    const serialized = board.exportBoardProfileText();
    expect(serialized).toContain('version=1');

    expect(board.importBoardProfileText('custom.board', serialized)).toBe(true);
    expect(board.boardProfile()?.version).toBe(1);
    expect(board.importBoardProfileText('broken.board', 'ospi=size:1024\n')).toBe(false);
    expect(rpc.errorMessage()).toContain('Invalid board profile');
  });

  it('formats Seek grammar, detects AppRefused forks, maps diffs, and supports markers/artifacts', async () => {
    expect(formatSeekPoint(2, 912n)).toBe('2:912:cpu0:0:retired');
    expect(isPendingForkError(new Error(`RPC error code ${ErrorCode.AppRefused}`))).toBe(true);
    expect(isPendingForkError(new Error('Other error'))).toBe(false);

    const diff: DecodedDiff = {
      frames: 4,
      a: { branch: 0, r: 10n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      b: { branch: 1, r: 12n, phase: HistoryPhase.Cpu0, o: 0, gap: HistoryGap.Retired },
      order: LineOrder.Lt,
      regs: [{ core: Core.Cpu0, name: 'r0', valA: 0, valB: 1 }],
      pages: [{ space: 0, pageIndex: 1, address: 0x2000_0000, hasA: true, objA: new Uint8Array(16), hasB: true, objB: new Uint8Array(16) }],
      periphs: [{ unit: 'RIIC1', offset: 0x10, oldVal: 0x04, newVal: 0x10, changedBytes: 0x14 }],
    };
    expect(mapDiffRows(diff).map((r) => r.scope)).toEqual(['CPU0', 'Memory', 'Peripheral']);

    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const rewind = TestBed.inject(RewindStore);
    rewind.activeDiff.set(diff);
    expect(rewind.diffRows().length).toBe(3);

    const navReply = { found: true, branch: 0, r: 99n, phase: 0, o: 0, gap: 0, count: 1n, slots: 1n, virtualNs: 500n };
    const fakeClient = {
      setMarker: async () => navReply,
      exportArtifact: async () => ({ bytes: new Uint8Array([1, 2, 3]), sha256: new Uint8Array(32), total: 3n }),
      importArtifact: async () => ({ accepted: true, reconnect: false }),
      now: async () => 500n,
      getBranches: async () => [],
      getForkStatus: async () => ({ pending: false, reason: 0, branch: 0, r: 0n }),
      getFrameStatus: async () => ({ ramBytes: 0n, diskBytes: 0n, queueBytes: 0n, frames: 0n, decodedSegments: 0n }),
    };
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });
    expect((await rewind.setMarker('boot', '0:99:cpu0:0:retired'))?.found).toBe(true);
    expect(await rewind.exportArtifactBundle(false)).toBeNull();

    rpc.serverCaps.set(CAP_ARTIFACTS);
    expect((await rewind.exportArtifactBundle(false))?.total).toBe(3n);
    const preview = await rewind.previewStagedArchive(
      buildMinimalBundleTar({
        format: 'ra8-session-bundle',
        version: 1,
        snapshot_version: 2,
        board: 'ek_ra8d2',
        elf0: { name: 'app.elf', identity: 'abc', size: 1024 },
        elf1: null,
        recording: false,
      })
    );
    expect(preview?.manifest?.board).toBe('ek_ra8d2');
    expect((await rewind.importArtifactBundle(new Uint8Array([9, 9])))?.accepted).toBe(true);
    expect(rewind.stagedBundlePreview()).toBeNull();
  });
});
