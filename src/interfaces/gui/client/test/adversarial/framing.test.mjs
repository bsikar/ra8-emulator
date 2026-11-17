import assert from "node:assert/strict";
import {
  Core,
  Kind,
  METRICS_REPORT_BYTES,
  Method,
  Register,
  RunMode,
  Topic,
  decodeMetricsReport,
  decodeResponse,
  detectPixelFormat,
  dirtyRectToRgba,
  encodeAdvance,
  encodeEvent,
  encodeFrame,
  encodeHello,
  encodeMetricsReport,
  encodeRequest,
  encodeResponse,
  encodeRun,
  encodeWriteRegister,
  splitFrames,
} from "../../dist/index.js";

function registerInvalidTagAndNumericTests(t) {
  t.section("Section 3: Invalid Opcodes & Corrupt Tags");
  t.test("decodeResponse rejects invalid result tags (not 0 and not 1)", () => {
    for (const invalidTag of [2, 3, 42, 255]) {
      const buf = new Uint8Array(10);
      const view = new DataView(buf.buffer);
      view.setUint32(0, 1, true);
      view.setUint8(4, invalidTag);
      assert.throws(() => decodeResponse(buf), new RegExp(`Invalid Response result tag: ${invalidTag}`));
    }
  });

  t.test("splitFrames ignores unknown frame kinds without throwing (preserves raw kind)", () => {
    const unknownKind = 0x9999;
    const frame = encodeFrame(unknownKind, new Uint8Array([1, 2, 3, 4]));
    const res = splitFrames(frame);
    assert.equal(res.frames.length, 1);
    assert.equal(res.frames[0].kind, unknownKind);
    assert.deepEqual(Array.from(res.frames[0].payload), [1, 2, 3, 4]);
  });

  t.section("Section 4: Negative, NaN, Float & Extreme Numbers");
  t.test("encodeMetricsReport with negative, NaN, float and overflow values converts safely", () => {
    const bytes = encodeMetricsReport({
      hostCpuPercent: NaN,
      hostRssMb: -1,
      hostThreads: 12.85,
      cpu0LoadPercent: -1,
      cpu0Pinned: 300,
      cpu0RamUsedBytes: 0,
      cpu0RamTotalBytes: 0xffffffff,
      cpu1LoadPercent: NaN,
      cpu1Pinned: 0,
      cpu1RamUsedBytes: 0x1000,
      cpu1RamTotalBytes: 0x8000,
    });
    assert.equal(bytes.length, METRICS_REPORT_BYTES);
    const decoded = decodeMetricsReport(bytes);
    assert.equal(decoded.hostCpuPercent, 0);
    assert.equal(decoded.hostRssMb, 0xffffffff);
    assert.equal(decoded.hostThreads, 12);
    assert.equal(decoded.cpu0LoadPercent, 255);
    assert.equal(decoded.cpu0Pinned, 44);
    assert.equal(decoded.cpu1LoadPercent, 0);
  });

  t.test("encodeWriteRegister with negative 32-bit value (-1) wraps to 0xFFFFFFFF", () => {
    const bytes = encodeWriteRegister(Core.Cpu0, Register.R0, -1);
    assert.equal(bytes.length, 6);
    assert.equal(new DataView(bytes.buffer).getUint32(2, true), 0xffffffff);
  });

  t.test("encodeRun and encodeAdvance with negative BigInt wraps to 64-bit uint correctly", () => {
    const runBytes = encodeRun(Core.Cpu0, RunMode.Run, -1n);
    assert.equal(new DataView(runBytes.buffer).getBigUint64(2, true), 0xffffffffffffffffn);
    const advBytes = encodeAdvance(Core.Cpu1, -5n);
    assert.equal(new DataView(advBytes.buffer).getBigUint64(1, true), 0xfffffffffffffffbn);
  });
}

function registerFragmentationTests(t) {
  t.section("Section 5: Extreme Stream Fragmentation & Reassembly");
  t.test("splitFrames reassembles frames fed 1 byte at a time", () => {
    const req1 = encodeFrame(Kind.Request, encodeRequest(1, Method.Step));
    const resp1 = encodeFrame(Kind.Response, encodeResponse(1, true, new Uint8Array([1])));
    const evt1 = encodeFrame(Kind.Event, encodeEvent(Topic.Stop, new Uint8Array([0, 1, 2, 3])));
    const combined = new Uint8Array(req1.length + resp1.length + evt1.length);
    combined.set(req1, 0);
    combined.set(resp1, req1.length);
    combined.set(evt1, req1.length + resp1.length);

    let accumulated = new Uint8Array(0);
    const gathered = [];
    for (let i = 0; i < combined.length; i++) {
      const next = new Uint8Array(accumulated.length + 1);
      next.set(accumulated, 0);
      next.set(combined.subarray(i, i + 1), accumulated.length);
      const { frames, remainder } = splitFrames(next);
      accumulated = remainder;
      gathered.push(...frames);
    }
    assert.equal(accumulated.length, 0);
    assert.deepEqual(gathered.map((f) => f.kind), [Kind.Request, Kind.Response, Kind.Event]);
  });

  t.test("splitFrames handles random chunk boundaries across iterations", () => {
    const frames = [
      encodeFrame(Kind.Hello, encodeHello(0x1234)),
      encodeFrame(Kind.Request, encodeRequest(10, Method.Pause)),
      encodeFrame(Kind.Response, encodeResponse(10, true, new Uint8Array([1, 2, 3, 4, 5]))),
      encodeFrame(Kind.Event, encodeEvent(Topic.Speed, new Uint8Array([7, 8]))),
    ];
    const fullStream = new Uint8Array(frames.reduce((sum, f) => sum + f.length, 0));
    let writeOffset = 0;
    for (const f of frames) {
      fullStream.set(f, writeOffset);
      writeOffset += f.length;
    }
    const chunkSizes = [1, 3, 2, 7, 1, 4, 2, 5, 3, 1, 6, 2, 1, 3, 4, 2, 5, 8, 2, 1, 10];
    let streamOffset = 0;
    let chunkIdx = 0;
    let buffer = new Uint8Array(0);
    const parsed = [];
    while (streamOffset < fullStream.length) {
      const end = Math.min(streamOffset + chunkSizes[chunkIdx++ % chunkSizes.length], fullStream.length);
      const chunk = fullStream.subarray(streamOffset, end);
      streamOffset = end;
      const merged = new Uint8Array(buffer.length + chunk.length);
      merged.set(buffer, 0);
      merged.set(chunk, buffer.length);
      const res = splitFrames(merged);
      buffer = res.remainder;
      parsed.push(...res.frames);
    }
    assert.equal(buffer.length, 0);
    assert.deepEqual(parsed.map((f) => f.kind), [Kind.Hello, Kind.Request, Kind.Response, Kind.Event]);
  });
}

function registerFramebufferTests(t) {
  t.section("Section 6: DirtyRect & Framebuffer Robustness");
  t.test("dirtyRectToRgba handles 0x0 empty rectangles without throwing", () => {
    const rect = { core: Core.Cpu0, x: 0, y: 0, width: 0, height: 0, virtualNs: 0n, pixels: new Uint8Array(0) };
    assert.equal(detectPixelFormat(rect), "grayscale");
    assert.equal(dirtyRectToRgba(rect).length, 0);
  });

  t.test("dirtyRectToRgba handles truncated pixel buffers by zero-filling missing channels", () => {
    const rect = { core: Core.Cpu0, x: 0, y: 0, width: 2, height: 2, virtualNs: 0n, pixels: new Uint8Array([200, 100]) };
    const rgba = dirtyRectToRgba(rect, undefined, "grayscale");
    assert.equal(rgba.length, 16);
    assert.equal(rgba[0], 200);
    assert.equal(rgba[4], 100);
    assert.equal(rgba[8], 0);
    assert.equal(rgba[11], 255);
    assert.equal(rgba[12], 0);
    assert.equal(rgba[15], 255);
  });

  t.test("dirtyRectToRgba converts all supported formats: rgb24, argb32, rgba32", () => {
    const rgb24 = { core: Core.Cpu0, x: 0, y: 0, width: 1, height: 1, virtualNs: 0n, pixels: new Uint8Array([10, 20, 30]) };
    assert.equal(detectPixelFormat(rgb24), "rgb24");
    assert.deepEqual(Array.from(dirtyRectToRgba(rgb24)), [10, 20, 30, 255]);

    const argb = { core: Core.Cpu0, x: 0, y: 0, width: 1, height: 1, virtualNs: 0n, pixels: new Uint8Array([200, 11, 22, 33]) };
    assert.deepEqual(Array.from(dirtyRectToRgba(argb, undefined, "argb32")), [11, 22, 33, 200]);

    const rgba = { core: Core.Cpu0, x: 0, y: 0, width: 1, height: 1, virtualNs: 0n, pixels: new Uint8Array([55, 66, 77, 88]) };
    assert.equal(detectPixelFormat(rgba), "rgba32");
    assert.deepEqual(Array.from(dirtyRectToRgba(rgba)), [55, 66, 77, 88]);
  });
}

export function run(t) {
  registerInvalidTagAndNumericTests(t);
  registerFragmentationTests(t);
  registerFramebufferTests(t);
}
