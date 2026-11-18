import assert from "node:assert/strict";
import {
  Core,
  Direction,
  ForkReason,
  HistoryGap,
  HistoryPhase,
  LineOrder,
  NavQueryKind,
  decodeBranchList,
  decodeDiff,
  decodeForkStatus,
  decodeFrameStatusResult,
  decodeNavQueryResult,
  encodeBranchConfirmFork,
  encodeBranchDelete,
  encodeBranchSwitch,
  encodeDiffArgs,
  encodeMarkerSetArgs,
  encodeNavQueryArgs,
  encodePlayArgs,
} from "../../dist/index.js";
import { buildDiff45Payload } from "../helpers/mock-ws.mjs";

function registerBranchAndNavTests(suite) {
  suite.section("History, Navigation, Markers & 45-Byte DiffWire Codecs");

  suite.test("BranchList, ForkStatus, PlayArgs, NavQuery, MarkerSet, FrameStatus codecs", () => {
    const branchBuf = new Uint8Array(8 + 30);
    const bv = new DataView(branchBuf.buffer);
    bv.setUint32(0, 1, true);
    bv.setUint32(4, 30, true);
    bv.setUint32(8, 2, true);
    bv.setUint32(12, 1, true);
    bv.setBigUint64(16, 1200n, true);
    bv.setBigUint64(24, 2400n, true);
    bv.setUint32(32, 0, true);
    bv.setUint8(36, ForkReason.Writes);
    bv.setUint8(37, 0b111);
    const branches = decodeBranchList(branchBuf);
    assert.equal(branches.length, 1);
    assert.equal(branches[0].isLive, true);
    assert.equal(branches[0].isKept, true);
    assert.equal(branches[0].isPinned, true);

    assert.equal(encodeBranchSwitch(2).length, 4);
    assert.equal(encodeBranchDelete(2, true)[4], 1);
    assert.equal(encodeBranchConfirmFork(true)[0], 1);

    const fk = new Uint8Array(14);
    fk[0] = 1;
    fk[1] = ForkReason.Buttons;
    new DataView(fk.buffer).setUint32(2, 1, true);
    new DataView(fk.buffer).setBigUint64(6, 512n, true);
    const status = decodeForkStatus(fk);
    assert.equal(status.pending, true);
    assert.equal(status.r, 512n);

    assert.equal(encodePlayArgs({ dir: Direction.Back, speedMilli: 500n })[0], Direction.Back);
    const nqAsk = encodeNavQueryArgs({ kind: NavQueryKind.Marker, index: 1n, name: "fault" });
    assert.equal(nqAsk[0], NavQueryKind.Marker);

    const nqBuf = new Uint8Array(43);
    const nqv = new DataView(nqBuf.buffer);
    nqv.setUint8(0, 1);
    nqv.setUint32(1, 3, true);
    nqv.setBigUint64(5, 900n, true);
    nqv.setUint8(13, HistoryPhase.Cpu1);
    nqv.setUint32(14, 17, true);
    nqv.setUint8(18, HistoryGap.Polled);
    nqv.setBigUint64(19, 4n, true);
    nqv.setBigUint64(27, 32n, true);
    nqv.setBigUint64(35, 1_500_000n, true);
    const nq = decodeNavQueryResult(nqBuf);
    assert.equal(nq.found, true);
    assert.equal(nq.branch, 3);
    assert.equal(nq.r, 900n);
    assert.equal(nq.phase, HistoryPhase.Cpu1);
    assert.equal(nq.gap, HistoryGap.Polled);
    assert.equal(nq.count, 4n);
    assert.equal(nq.virtualNs, 1_500_000n);

    assert.equal(encodeMarkerSetArgs("loop_start", "0x02000100").length, 8 + 10 + 10);
    assert.equal(encodeDiffArgs("1:100", "1:200").length, 8 + 5 + 5);

    const fsBuf = new Uint8Array(40);
    new DataView(fsBuf.buffer).setBigUint64(24, 128n, true);
    assert.equal(decodeFrameStatusResult(fsBuf).frames, 128n);
  });
}

function registerDiffWireTests(suite) {
  suite.test("decodeDiff decodes exact 45-byte header + regs + pages + periphs per diff_wire.zig", () => {
    const diff = decodeDiff(buildDiff45Payload());
    assert.equal(diff.frames, 12);
    assert.equal(diff.order, LineOrder.Lt);
    assert.equal(diff.a.branch, 0);
    assert.equal(diff.a.r, 100n);
    assert.equal(diff.a.phase, HistoryPhase.Cpu0);
    assert.equal(diff.a.o, 4);
    assert.equal(diff.a.gap, HistoryGap.Retired);
    assert.equal(diff.b.branch, 1);
    assert.equal(diff.b.r, 200n);
    assert.equal(diff.b.phase, HistoryPhase.Cpu1);
    assert.equal(diff.b.o, 9);
    assert.equal(diff.b.gap, HistoryGap.Polled);

    assert.equal(diff.regs.length, 1);
    assert.equal(diff.regs[0].core, Core.Cpu0);
    assert.equal(diff.regs[0].name, "r0");
    assert.equal(diff.regs[0].valA, 0x10);
    assert.equal(diff.regs[0].valB, 0x42);

    assert.equal(diff.pages.length, 1);
    assert.equal(diff.pages[0].space, 1);
    assert.equal(diff.pages[0].pageIndex, 5);
    assert.equal(diff.pages[0].address, 0x2200_1000);
    assert.equal(diff.pages[0].hasA, true);
    assert.equal(diff.pages[0].objA[0], 0xaa);
    assert.equal(diff.pages[0].hasB, true);
    assert.equal(diff.pages[0].objB[0], 0xbb);

    assert.equal(diff.periphs.length, 1);
    assert.equal(diff.periphs[0].unit, "riic1");
    assert.equal(diff.periphs[0].offset, 0x18);
    assert.equal(diff.periphs[0].oldVal, 0x0001);
    assert.equal(diff.periphs[0].newVal, 0x0003);
    assert.equal(diff.periphs[0].changedBytes, 1);
  });

  suite.test("decodeDiff rejects truncated <45-byte headers and invalid phase/gap/order", () => {
    const short = new Uint8Array(4 + 44);
    new DataView(short.buffer).setUint32(0, 44, true);
    assert.throws(() => decodeDiff(short), /45 bytes/);

    const badOrder = buildDiff45Payload();
    badOrder[4 + 44] = 9;
    assert.throws(() => decodeDiff(badOrder), /LineOrder/);
  });
}

export function run(suite) {
  registerBranchAndNavTests(suite);
  registerDiffWireTests(suite);
}
