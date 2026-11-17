import assert from "node:assert/strict";
import {
  HEADER_BYTES,
  Kind,
  MAX_PAYLOAD,
  Method,
  Topic,
  decodeAck,
  decodeCoreOnly,
  decodeDirtyRect,
  decodeEvent,
  decodeFault,
  decodeHeader,
  decodeHello,
  decodeMemory,
  decodeMetricsReport,
  decodeRequest,
  decodeResponse,
  decodeStopped,
  decodeU32,
  decodeUart,
  encodeFrame,
  encodeHeader,
  splitFrames,
} from "../../dist/index.js";

function registerEnvelopeTruncationTests(t) {
  t.test("decodeHeader rejects truncated inputs (< 6 bytes)", () => {
    for (let len = 0; len < 6; len++) {
      assert.throws(() => decodeHeader(new Uint8Array(len)), /Truncated frame header/);
    }
  });

  t.test("decodeHello rejects truncated inputs (< 10 bytes)", () => {
    for (let len = 0; len < 10; len++) {
      assert.throws(() => decodeHello(new Uint8Array(len)), /Truncated Hello frame/);
    }
  });

  t.test("decodeFault rejects truncated inputs (< 4 bytes)", () => {
    for (let len = 0; len < 4; len++) {
      assert.throws(() => decodeFault(new Uint8Array(len)), /Truncated Fault frame/);
    }
  });

  t.test("decodeRequest rejects truncated header (< 10 bytes)", () => {
    for (let len = 0; len < 10; len++) {
      assert.throws(() => decodeRequest(new Uint8Array(len)), /Truncated Request envelope/);
    }
  });

  t.test("decodeRequest rejects truncated args body when length is less than declared", () => {
    const buf = new Uint8Array(14);
    const view = new DataView(buf.buffer);
    view.setUint32(0, 1, true);
    view.setUint16(4, Method.Step, true);
    view.setUint32(6, 10, true);
    assert.throws(() => decodeRequest(buf), /Truncated Request envelope args/);
  });

  t.test("decodeResponse rejects truncated header (< 5 bytes)", () => {
    for (let len = 0; len < 5; len++) {
      assert.throws(() => decodeResponse(new Uint8Array(len)), /Truncated Response envelope/);
    }
  });

  t.test("decodeResponse rejects truncated Ok payload length (< 9 bytes)", () => {
    for (let len = 5; len < 9; len++) {
      const buf = new Uint8Array(len);
      buf[4] = 0;
      assert.throws(() => decodeResponse(buf), /Truncated Response payload length header/);
    }
  });

  t.test("decodeResponse rejects truncated Ok payload body", () => {
    const buf = new Uint8Array(12);
    const view = new DataView(buf.buffer);
    view.setUint32(0, 1, true);
    view.setUint8(4, 0);
    view.setUint32(5, 50, true);
    assert.throws(() => decodeResponse(buf), /Truncated Response payload body/);
  });

  t.test("decodeResponse rejects truncated Err code (< 7 bytes)", () => {
    for (let len = 5; len < 7; len++) {
      const buf = new Uint8Array(len);
      buf[4] = 1;
      assert.throws(() => decodeResponse(buf), /Truncated Response error code/);
    }
  });
}

function registerPayloadTruncationTests(t) {
  t.test("decodeEvent rejects truncated header (< 6 bytes) and body", () => {
    for (let len = 0; len < 6; len++) {
      assert.throws(() => decodeEvent(new Uint8Array(len)), /Truncated Event envelope/);
    }
    const buf = new Uint8Array(8);
    const view = new DataView(buf.buffer);
    view.setUint16(0, Topic.Stop, true);
    view.setUint32(2, 20, true);
    assert.throws(() => decodeEvent(buf), /Truncated Event payload body/);
  });

  t.test("decodeMetricsReport rejects truncated inputs (< 32 bytes)", () => {
    for (const len of [0, 1, 10, 20, 31]) {
      assert.throws(() => decodeMetricsReport(new Uint8Array(len)), /Truncated MetricsReport: requires 32 bytes/);
    }
  });

  t.test("decodeDirtyRect rejects truncated header (< 21 bytes) and truncated pixels", () => {
    for (let len = 0; len < 21; len++) {
      assert.throws(() => decodeDirtyRect(new Uint8Array(len)), /Truncated DirtyRect/);
    }
    const buf = new Uint8Array(25);
    const view = new DataView(buf.buffer);
    view.setUint16(5, 10, true);
    view.setUint16(7, 10, true);
    view.setUint32(17, 100, true);
    assert.throws(() => decodeDirtyRect(buf), /Truncated DirtyRect pixel buffer/);
  });

  t.test("decodeCoreOnly, decodeU32, decodeAck, decodeStopped, decodeUart reject truncation", () => {
    assert.throws(() => decodeCoreOnly(new Uint8Array(0)), /Truncated CoreOnly/);
    assert.throws(() => decodeU32(new Uint8Array(3)), /Truncated U32/);
    assert.throws(() => decodeAck(new Uint8Array(0)), /Truncated Ack/);
    assert.throws(() => decodeStopped(new Uint8Array(9)), /Truncated Stopped/);
    assert.throws(() => decodeUart(new Uint8Array(13)), /Truncated Uart/);
    const uartBuf = new Uint8Array(16);
    new DataView(uartBuf.buffer).setUint32(10, 10, true);
    assert.throws(() => decodeUart(uartBuf), /Truncated Uart bytes/);
  });
}

function registerBoundaryLengthTests(t) {
  t.test("splitFrames throws on length exceeding maxPayload", () => {
    const buf = encodeHeader(MAX_PAYLOAD + 1, Kind.Request);
    assert.throws(() => splitFrames(buf, MAX_PAYLOAD), /Frame payload oversize: 1048577 > max 1048576/);
  });

  t.test("splitFrames throws on maximum u32 length (0xFFFFFFFF = 4294967295)", () => {
    const buf = encodeHeader(0xffffffff, Kind.Request);
    assert.throws(() => splitFrames(buf), /Frame payload oversize: 4294967295 > max 1048576/);
  });

  t.test("splitFrames handles exact maxPayload boundary correctly when payload present", () => {
    const buf = encodeFrame(Kind.Event, new Uint8Array(1024));
    const res = splitFrames(buf, 1024);
    assert.equal(res.frames.length, 1);
    assert.equal(res.frames[0].payload.length, 1024);
  });

  t.test("splitFrames handles 0-byte payload frame correctly without hanging or infinite loop", () => {
    const zeroFrame = encodeFrame(Kind.Event, new Uint8Array(0));
    assert.equal(zeroFrame.length, HEADER_BYTES);
    const res = splitFrames(zeroFrame);
    assert.equal(res.frames.length, 1);
    assert.equal(res.frames[0].payload.length, 0);
    assert.equal(res.remainder.length, 0);
  });

  t.test("decodeRequest, decodeResponse, decodeEvent handle 0xFFFFFFFF declared lengths safely", () => {
    const reqBuf = new Uint8Array(10);
    const reqView = new DataView(reqBuf.buffer);
    reqView.setUint32(0, 1, true);
    reqView.setUint16(4, Method.Step, true);
    reqView.setUint32(6, 0xffffffff, true);
    assert.throws(() => decodeRequest(reqBuf), /Truncated Request envelope args/);

    const respBuf = new Uint8Array(9);
    const respView = new DataView(respBuf.buffer);
    respView.setUint32(0, 1, true);
    respView.setUint8(4, 0);
    respView.setUint32(5, 0xffffffff, true);
    assert.throws(() => decodeResponse(respBuf), /Truncated Response payload body/);

    const evtBuf = new Uint8Array(6);
    const evtView = new DataView(evtBuf.buffer);
    evtView.setUint16(0, Topic.Stop, true);
    evtView.setUint32(2, 0xffffffff, true);
    assert.throws(() => decodeEvent(evtBuf), /Truncated Event payload body/);

    const memBuf = new Uint8Array(4);
    new DataView(memBuf.buffer).setUint32(0, 0xffffffff, true);
    assert.throws(() => decodeMemory(memBuf), /Truncated Memory bytes/);
  });
}

export function run(t) {
  t.section("Section 1: Truncated Buffers & Insufficient Lengths");
  registerEnvelopeTruncationTests(t);
  registerPayloadTruncationTests(t);
  t.section("Section 2: Oversized Length Prefixes & Boundaries");
  registerBoundaryLengthTests(t);
}
