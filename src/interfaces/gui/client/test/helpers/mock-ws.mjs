import {
  Core,
  ErrorCode,
  Kind,
  Method,
  StopReason,
  decodeRequest,
  encodeEvent,
  encodeFrame,
  encodeHello,
  encodeMetricsReport,
  encodeResponse,
  encodeU32,
  encodeU64,
  splitFrames,
} from "../../dist/index.js";

function encodeSlice(bytes) {
  const buf = new Uint8Array(4 + bytes.length);
  new DataView(buf.buffer).setUint32(0, bytes.length, true);
  buf.set(bytes, 4);
  return buf;
}

function buildNavResultPayload() {
  const buf = new Uint8Array(43);
  const v = new DataView(buf.buffer);
  v.setUint8(0, 1); // found
  v.setUint32(1, 2, true); // branch
  v.setBigUint64(5, 912n, true); // r
  v.setUint8(13, 0); // phase cpu0
  v.setUint32(14, 14, true); // o
  v.setUint8(18, 0); // gap retired
  v.setBigUint64(19, 3n, true); // count
  v.setBigUint64(27, 64n, true); // slots
  v.setBigUint64(35, 1_824_000n, true); // virtualNs
  return buf;
}

export function buildDiff45Payload() {
  const unit = new TextEncoder().encode("riic1");
  const regName = new TextEncoder().encode("r0");
  // 45B header + 1 reg (2 + 2 + 8 = 12B) + 1 page (43B) + 1 periph (1 + 5 + 16 = 22B)
  const body = new Uint8Array(45 + 12 + 43 + 22);
  const v = new DataView(body.buffer);
  v.setUint16(0, 1, true); // regCount
  v.setUint16(2, 1, true); // pageCount
  v.setUint16(4, 1, true); // periphCount
  v.setUint16(6, 12, true); // frames
  // Side A (18B at offset 8)
  v.setUint32(8, 0, true);
  v.setBigUint64(12, 100n, true);
  v.setUint8(20, 0);
  v.setUint32(21, 4, true);
  v.setUint8(25, 0);
  // Side B (18B at offset 26)
  v.setUint32(26, 1, true);
  v.setBigUint64(30, 200n, true);
  v.setUint8(38, 1);
  v.setUint32(39, 9, true);
  v.setUint8(43, 1);
  // LineOrder (1B at offset 44)
  v.setUint8(44, 0); // lt
  let at = 45;
  body[at++] = Core.Cpu0;
  body[at++] = regName.length;
  body.set(regName, at); at += regName.length;
  v.setUint32(at, 0x10, true); at += 4;
  v.setUint32(at, 0x42, true); at += 4;
  body[at++] = 1; // space
  v.setUint32(at, 5, true); at += 4;
  v.setUint32(at, 0x2200_1000, true); at += 4;
  body[at++] = 1;
  body.fill(0xaa, at, at + 16); at += 16;
  body[at++] = 1;
  body.fill(0xbb, at, at + 16); at += 16;
  body[at++] = unit.length;
  body.set(unit, at); at += unit.length;
  v.setUint32(at, 0x18, true); at += 4;
  v.setUint32(at, 0x0001, true); at += 4;
  v.setUint32(at, 0x0003, true); at += 4;
  v.setUint32(at, 1, true);
  return encodeSlice(body);
}

function buildSetVarReplyPayload() {
  const msg = new TextEncoder().encode("updated");
  const buf = new Uint8Array(15 + msg.length);
  const v = new DataView(buf.buffer);
  v.setUint8(0, 0); // Ok
  v.setUint8(1, 2); // Local
  v.setUint32(2, 0x2200_0400, true);
  v.setUint8(6, 0xff);
  v.setUint32(7, 4, true);
  v.setUint32(11, msg.length, true);
  buf.set(msg, 15);
  return buf;
}

export class MockRpcServer {
  constructor(extraHandler) {
    this.client = null;
    this.seenMethods = [];
    this.seenRegisterReads = [];
    this.extraHandler = extraHandler;
  }

  attach(clientWs) {
    this.client = clientWs;
  }

  sendToClient(packet) {
    if (this.client && this.client.onmessage) {
      setTimeout(() => {
        const ab = packet.buffer.slice(packet.byteOffset, packet.byteOffset + packet.byteLength);
        this.client.onmessage({ data: ab });
      }, 2);
    }
  }

  emitEvent(topic, payload) {
    this.sendToClient(encodeFrame(Kind.Event, encodeEvent(topic, payload)));
  }

  replyOk(id, payload) {
    this.sendToClient(encodeFrame(Kind.Response, encodeResponse(id, true, payload)));
  }

  replyErr(id, code) {
    this.sendToClient(encodeFrame(Kind.Response, encodeResponse(id, false, code)));
  }

  handleClientFrame(rawBuffer) {
    const { frames } = splitFrames(new Uint8Array(rawBuffer));
    for (const frame of frames) {
      if (frame.kind === Kind.Hello) {
        this.sendToClient(encodeFrame(Kind.Hello, encodeHello(0x003f_ffff)));
      } else if (frame.kind === Kind.Request) {
        const req = decodeRequest(frame.payload);
        this.seenMethods.push(req.method);
        if (!this.handleSessionMethod(req)) {
          if (!this.extraHandler || !this.extraHandler(req, this)) {
            this.replyErr(req.id, ErrorCode.UnknownMethod);
          }
        }
      }
    }
  }

  handleSessionMethod(req) {
    switch (req.method) {
      case Method.Step:
      case Method.Run:
      case Method.Pause:
      case Method.SetRunBudget:
      case Method.WriteMemory:
      case Method.WriteRegister:
      case Method.Subscribe:
      case Method.Unsubscribe:
      case Method.ClearBreakpoint:
      case Method.ClearWatchpoint:
      case Method.SetSpeed:
      case Method.SetCameraSource:
      case Method.Input:
      case Method.ConsoleInput:
      case Method.Load:
      case Method.LoadBegin:
      case Method.LoadChunk:
      case Method.LoadEnd:
      case Method.SkipBkpt:
      case Method.UndoWrite:
      case Method.ResetImage:
      case Method.Plug:
      case Method.Unplug:
      case Method.SetFault:
      case Method.ClearFault:
      case Method.Snapshot:
      case Method.Restore:
        this.replyOk(req.id, new Uint8Array([1]));
        return true;

      case Method.Interrupt: {
        const buf = new Uint8Array(10);
        const v = new DataView(buf.buffer);
        v.setUint8(0, Core.Cpu0);
        v.setUint8(1, StopReason.HaltRequested);
        v.setUint32(2, 0x0200_0120, true);
        v.setUint32(6, 0, true);
        this.replyOk(req.id, buf);
        return true;
      }

      case Method.ReadRegister: {
        const regId = req.args[1] ?? 0;
        this.seenRegisterReads.push(regId);
        this.replyOk(req.id, encodeU32(0x1000_0000 + regId));
        return true;
      }

      case Method.ReadMemory:
        this.replyOk(req.id, encodeSlice(new Uint8Array([0xde, 0xad, 0xbe, 0xef])));
        return true;

      case Method.Metrics:
        this.replyOk(req.id, encodeMetricsReport({
          hostCpuPercent: 25, hostRssMb: 64, hostThreads: 4,
          cpu0LoadPercent: 88, cpu0Pinned: 1, cpu0RamUsedBytes: 0x2000, cpu0RamTotalBytes: 0x10000,
          cpu1LoadPercent: 5, cpu1Pinned: 0, cpu1RamUsedBytes: 0x1000, cpu1RamTotalBytes: 0x8000,
        }));
        return true;

      default:
        return this.handleDebugHistoryMethod(req);
    }
  }

  handleDebugHistoryMethod(req) {
    switch (req.method) {
      case Method.SetBreakpoint:
      case Method.SetWatchpoint:
        this.replyOk(req.id, encodeU32(3));
        return true;

      case Method.SetBreakpointName: {
        const np = new Uint8Array(9);
        const v = new DataView(np.buffer);
        v.setUint32(0, 7, true);
        v.setUint32(4, 0x0200_0140, true);
        this.replyOk(req.id, np);
        return true;
      }

      case Method.Rtc: {
        const rtc = new Uint8Array(9);
        const v = new DataView(rtc.buffer);
        v.setUint8(0, 1); v.setUint8(1, 1); v.setUint16(2, 2026, true);
        rtc[4] = 11; rtc[5] = 16; rtc[6] = 21; rtc[7] = 5; rtc[8] = 9;
        this.replyOk(req.id, rtc);
        return true;
      }

      case Method.Advance: {
        const adv = new Uint8Array(22);
        const v = new DataView(adv.buffer);
        v.setUint8(0, Core.Cpu0);
        v.setBigUint64(1, 1000n, true);
        v.setBigUint64(9, 1_001_000n, true);
        v.setUint8(17, StopReason.Count);
        v.setUint32(18, 0x0200_0180, true);
        this.replyOk(req.id, adv);
        return true;
      }

      case Method.AdvanceAsync: {
        const q = new Uint8Array(17);
        const v = new DataView(q.buffer);
        v.setUint8(0, Core.Cpu0);
        v.setBigUint64(1, 1000n, true);
        v.setBigUint64(9, 50_000n, true);
        this.replyOk(req.id, q);
        return true;
      }

      case Method.Periph: {
        const json = req.args[1] === 1;
        const text = json ? '{"block":"riic1","regs":[{"name":"ICCR1","val":192}]}' : "riic1\n";
        this.replyOk(req.id, encodeSlice(new TextEncoder().encode(text)));
        return true;
      }

      case Method.MarkerSet:
        this.replyOk(req.id, buildNavResultPayload());
        return true;
      case Method.Diff:
        this.replyOk(req.id, buildDiff45Payload());
        return true;
      case Method.SetVar:
        this.replyOk(req.id, buildSetVarReplyPayload());
        return true;
      case Method.Now:
        this.replyOk(req.id, encodeU64(42_000n));
        return true;
      default:
        return false;
    }
  }
}

export function createMockWsClass(extraHandler) {
  let latestServer = null;
  class MockWebSocket {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.binaryType = "arraybuffer";
      this.onopen = null;
      this.onmessage = null;
      this.onclose = null;
      this.onerror = null;
      this.server = new MockRpcServer(extraHandler);
      this.server.attach(this);
      latestServer = this.server;
      setTimeout(() => {
        this.readyState = 1;
        if (this.onopen) this.onopen({});
      }, 3);
    }
    send(data) {
      setTimeout(() => this.server.handleClientFrame(data), 1);
    }
    close(code = 1000, reason = "Normal closure") {
      this.readyState = 3;
      if (this.onclose) this.onclose({ code, reason });
    }
  }
  return { MockWebSocket, getServer: () => latestServer };
}
