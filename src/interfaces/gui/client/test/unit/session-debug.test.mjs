import assert from "node:assert/strict";
import {
  Access,
  Core,
  LocalWhereKind,
  METRICS_REPORT_BYTES,
  Register,
  SetVarScope,
  SetVarStatus,
  decodeAdvanced,
  decodeAdvanceQueued,
  decodeBacktrace,
  decodeBoardParts,
  decodeDirtyRect,
  decodeDisasmReply,
  decodeLocals,
  decodeMetricsReport,
  decodeNamedPoint,
  decodeRtcReport,
  decodeSessionEvent,
  decodeSetVarReply,
  decodeSourceLine,
  decodeStackReport,
  detectPixelFormat,
  dirtyRectToRgba,
  encodeAdvance,
  encodeCameraSource,
  encodeConsoleInput,
  encodeCoreFrame,
  encodeDirtyRect,
  encodeDisasmAsk,
  encodeLoad,
  encodeLoadBegin,
  encodeLoadChunk,
  encodeMapAsk,
  encodeMetricsReport,
  encodeNamedBreak,
  encodePartSpec,
  encodePeriphAsk,
  encodeRunBudget,
  encodeScheduleInput,
  encodeSetSpeed,
  encodeSetVarArgs,
  encodeStatePath,
  encodeWatchpoint,
} from "../../dist/index.js";

function registerSessionCodecTests(suite) {
  suite.section("Session, Debug, Metrics & Framebuffer Codecs");

  suite.test("Register enum includes Sys (Primask..Psplim) and MVE/FPU (Fpscr, Vpr, S0..S31)", () => {
    assert.equal(Register.Primask, 9);
    assert.equal(Register.Basepri, 20);
    assert.equal(Register.Faultmask, 21);
    assert.equal(Register.Control, 22);
    assert.equal(Register.Fpscr, 23);
    assert.equal(Register.Msplim, 24);
    assert.equal(Register.Psplim, 25);
    assert.equal(Register.S0, 26);
    assert.equal(Register.S31, 57);
    assert.equal(Register.Vpr, 58);
  });

  suite.test("Session scalar & control codecs encode exact Zig layouts", () => {
    const speed = encodeSetSpeed(Core.Cpu0, 100n);
    assert.equal(new DataView(speed.buffer).getBigUint64(1, true), 100n);

    const budget = encodeRunBudget(Core.Cpu1, 50_000n);
    assert.equal(budget[0], Core.Cpu1);
    assert.equal(new DataView(budget.buffer).getBigUint64(1, true), 50_000n);

    const cam = encodeCameraSource("gradient", true);
    assert.equal(new DataView(cam.buffer).getUint32(0, true), 8);
    assert.equal(cam[12], 1);

    const rtcBuf = new Uint8Array(9);
    const rv = new DataView(rtcBuf.buffer);
    rv.setUint8(0, 1); rv.setUint8(1, 1); rv.setUint16(2, 2026, true);
    rtcBuf[4] = 11; rtcBuf[5] = 16; rtcBuf[6] = 14; rtcBuf[7] = 30; rtcBuf[8] = 45;
    const rtc = decodeRtcReport(rtcBuf);
    assert.equal(rtc.running, true);
    assert.equal(rtc.year, 2026);
    assert.equal(rtc.second, 45);

    const qBuf = new Uint8Array(17);
    const qv = new DataView(qBuf.buffer);
    qv.setUint8(0, Core.Cpu1);
    qv.setBigUint64(1, 500n, true);
    qv.setBigUint64(9, 25_000n, true);
    const aq = decodeAdvanceQueued(qBuf);
    assert.equal(aq.core, Core.Cpu1);
    assert.equal(aq.targetNs, 25_000n);

    assert.equal(encodeAdvance(Core.Cpu0, 1000n).length, 9);
    assert.equal(encodeScheduleInput({ core: Core.Cpu0, kind: 1, x: 250, y: 150 }).length, 27);
    assert.equal(encodeConsoleInput(Core.Cpu0, new Uint8Array([65, 66])).length, 7);
    assert.equal(decodeSessionEvent(new Uint8Array([0, 15, 0, 0x10, 0, 0])).kind, 15);
  });
}

function registerDebugCodecTests(suite) {
  suite.test("SetVar, Disasm, Locals, SourceLine, BoardParts, PartSpec, StatePath codecs", () => {
    const svArgs = encodeSetVarArgs({ core: Core.Cpu0, frame: 2, name: "count", value: "42" });
    const svView = new DataView(svArgs.buffer);
    assert.equal(svArgs[0], Core.Cpu0);
    assert.equal(svView.getUint32(1, true), 2);
    assert.equal(svView.getUint32(5, true), 5);

    const msgBytes = new TextEncoder().encode("ok");
    const svReply = new Uint8Array(15 + msgBytes.length);
    const srv = new DataView(svReply.buffer);
    srv.setUint8(0, SetVarStatus.Ok);
    srv.setUint8(1, SetVarScope.Local);
    srv.setUint32(2, 0x2200_0100, true);
    srv.setUint8(6, 0xff);
    srv.setUint32(7, 4, true);
    srv.setUint32(11, msgBytes.length, true);
    svReply.set(msgBytes, 15);
    const decodedSv = decodeSetVarReply(svReply);
    assert.equal(decodedSv.status, SetVarStatus.Ok);
    assert.equal(decodedSv.scope, SetVarScope.Local);
    assert.equal(decodedSv.message, "ok");

    assert.deepEqual(Array.from(encodeMapAsk(Core.Cpu0, true)), [0, 1]);
    assert.deepEqual(Array.from(encodePeriphAsk(Core.Cpu0, "riic1", true).slice(0, 6)), [0, 1, 5, 0, 0, 0]);
    assert.equal(encodeLoad(Core.Cpu0, new Uint8Array([1, 2])).length, 7);
    assert.equal(encodeLoadBegin(Core.Cpu1, 1000, 0x1234).length, 13);
    assert.equal(encodeLoadChunk(Core.Cpu0, 0, new Uint8Array(4)).length, 17);
    assert.equal(encodeNamedBreak(Core.Cpu0, "main").length, 9);
    assert.equal(encodeWatchpoint(Core.Cpu0, 0x2200_0000, 0x2200_0003, Access.Write).length, 10);
    assert.equal(encodeCoreFrame(Core.Cpu0, 1).length, 5);
    assert.equal(encodePartSpec("lsm6dso@i2c:riic@0x6a").length, 26);
    assert.throws(() => encodeStatePath("../bad"), /bare/i);

    const disAsk = encodeDisasmAsk({ core: Core.Cpu0, address: 0x0200_0100, count: 16, usePc: true });
    assert.equal(disAsk.length, 7);
    const tBytes = new TextEncoder().encode("nop");
    const sBytes = new TextEncoder().encode("fn");
    const rowLen = 4 + 1 + 1 + 4 + 1 + tBytes.length + 1 + sBytes.length;
    const dReply = new Uint8Array(10 + rowLen);
    const dv = new DataView(dReply.buffer);
    dv.setUint32(1, 0x0200_0100, true); dv.setUint8(5, 1); dv.setUint32(6, rowLen, true);
    dv.setUint32(10, 0x0200_0100, true); dv.setUint8(14, 2); dv.setUint8(15, 1);
    dv.setUint8(20, tBytes.length); dReply.set(tBytes, 21);
    dv.setUint8(21 + tBytes.length, sBytes.length); dReply.set(sBytes, 22 + tBytes.length);
    assert.equal(decodeDisasmReply(dReply).rows[0]?.text, "nop");

    const np = new Uint8Array(9);
    new DataView(np.buffer).setUint32(0, 5, true);
    assert.equal(decodeNamedPoint(np).id, 5);

    const sl = new Uint8Array(15);
    new DataView(sl.buffer).setUint8(0, 1);
    new DataView(sl.buffer).setUint32(9, 2, true);
    sl.set([0x61, 0x2e], 13);
    assert.equal(decodeSourceLine(sl).path, "a.");

    assert.equal(decodeBacktrace(new Uint8Array([0, 0, 0, 0, 0, 0])).count, 0);
    assert.equal(decodeLocals(new Uint8Array([0, 0, 0, 0, 0, 0])).count, 0);
    assert.equal(decodeBoardParts(new Uint8Array(24)).panelWidth, 0);
    assert.equal(decodeAdvanced(new Uint8Array(22)).fromNs, 0n);
  });
}

function registerMetricsCodecTests(suite) {
  suite.test("MetricsReport (32B), StackReport (30B), DirtyRect, and RGB565 helpers", () => {
    const report = {
      hostCpuPercent: 45, hostRssMb: 128, hostThreads: 8,
      cpu0LoadPercent: 72, cpu0Pinned: 1, cpu0RamUsedBytes: 0x40000, cpu0RamTotalBytes: 0x200000,
      cpu1LoadPercent: 15, cpu1Pinned: 0, cpu1RamUsedBytes: 0x10000, cpu1RamTotalBytes: 0x100000,
    };
    const encoded = encodeMetricsReport(report);
    assert.equal(encoded.length, METRICS_REPORT_BYTES);
    assert.deepEqual(decodeMetricsReport(encoded), report);

    const srBuf = new Uint8Array(30);
    new DataView(srBuf.buffer).setUint8(17, 1);
    new DataView(srBuf.buffer).setUint32(22, 0x1000, true);
    assert.equal(decodeStackReport(srBuf).hasStack, true);

    const rect = decodeDirtyRect(encodeDirtyRect({
      core: Core.Cpu0, x: 1, y: 2, width: 1, height: 1, virtualNs: 99n, pixels: new Uint8Array([0x00, 0xf8]),
    }));
    assert.equal(detectPixelFormat(rect), "rgb565");
    assert.deepEqual(Array.from(dirtyRectToRgba(rect)), [255, 0, 0, 255]);
    assert.equal(LocalWhereKind.Frame, 1);
  });
}

export function run(suite) {
  registerSessionCodecTests(suite);
  registerDebugCodecTests(suite);
  registerMetricsCodecTests(suite);
}
