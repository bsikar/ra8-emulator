import assert from "node:assert/strict";
import {
  Core,
  ErrorCode,
  Kind,
  Method,
  RA8RpcClient,
  Register,
  decodeRequest,
  decodeU32,
  encodeFault,
  encodeFrame,
  encodeHello,
  encodeReadRegister,
  encodeResponse,
  encodeU32,
  splitFrames,
} from "../../dist/index.js";

class AdversarialMockWebSocketServer {
  constructor() {
    this.client = null;
    this.requests = [];
  }
  attach(clientWs) {
    this.client = clientWs;
  }
  sendToClient(packet) {
    if (this.client && this.client.onmessage) {
      setTimeout(() => {
        const ab = packet.buffer.slice(packet.byteOffset, packet.byteOffset + packet.byteLength);
        this.client.onmessage({ data: ab });
      }, 1);
    }
  }
  handleClientFrame(raw) {
    const { frames } = splitFrames(new Uint8Array(raw));
    for (const frame of frames) {
      if (frame.kind === Kind.Hello) {
        this.sendToClient(encodeFrame(Kind.Hello, encodeHello(0xffff)));
      } else if (frame.kind === Kind.Request) {
        this.requests.push(decodeRequest(frame.payload));
      }
    }
  }
}

class AdversarialMockWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.binaryType = "arraybuffer";
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
    this.server = new AdversarialMockWebSocketServer();
    this.server.attach(this);
    setTimeout(() => {
      this.readyState = 1;
      if (this.onopen) this.onopen({});
    }, 2);
  }
  send(data) {
    if (this.server) {
      setTimeout(() => this.server.handleClientFrame(data), 1);
    }
  }
  close(code = 1000, reason = "Normal closure") {
    this.readyState = 3;
    if (this.onclose) this.onclose({ code, reason });
  }
}

class BadMagicWebSocket extends AdversarialMockWebSocket {
  constructor(url) {
    super(url);
    this.server = null;
    setTimeout(() => {
      const badHello = encodeFrame(Kind.Hello, encodeHello(0xffff, 0xdeadbeef, 1));
      this.onmessage({ data: badHello.buffer });
    }, 5);
  }
}

export async function run(t) {
  t.section("Section 7: Client Recovery, Timeouts & Concurrent Calls");

  await t.testAsync("client.call throws immediately when client is disconnected", async () => {
    const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
    assert.equal(client.isConnected, false);
    await assert.rejects(() => client.call(Method.Step), /RPC client is not connected/);
  });

  await t.testAsync("client handles concurrent calls completed in out-of-order sequence", async () => {
    const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
    await client.connect("ws://127.0.0.1:4567");
    const server = client.ws.server;

    const p1 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Pc));
    const p2 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Sp));
    const p3 = client.call(Method.ReadRegister, encodeReadRegister(Core.Cpu0, Register.Lr));
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(server.requests.length, 3);

    const [req1, req2, req3] = server.requests;
    server.sendToClient(encodeFrame(Kind.Response, encodeResponse(req2.id, true, encodeU32(0x20001000))));
    server.sendToClient(encodeFrame(Kind.Response, encodeResponse(req3.id, true, encodeU32(0x08000555))));
    server.sendToClient(encodeFrame(Kind.Response, encodeResponse(req1.id, true, encodeU32(0x08000123))));

    const [res1, res2, res3] = await Promise.all([p1, p2, p3]);
    assert.equal(decodeU32(res1), 0x08000123);
    assert.equal(decodeU32(res2), 0x20001000);
    assert.equal(decodeU32(res3), 0x08000555);
    client.disconnect();
  });

  await t.testAsync("client times out individual RPC call when server does not reply", async () => {
    const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket, timeoutMs: 1000 });
    await client.connect("ws://127.0.0.1:4567");
    await assert.rejects(() => client.call(Method.Step, undefined, 50), /timed out/);
    client.disconnect();
  });

  await t.testAsync("client cleans up and rejects all pending calls when connection terminates", async () => {
    const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
    await client.connect("ws://127.0.0.1:4567");
    const pendingCall = client.call(Method.Step);
    client.disconnect();
    await assert.rejects(() => pendingCall, /Client disconnected|WebSocket closed/);
  });

  await t.testAsync("client rejects handshake if server sends incompatible magic or version", async () => {
    const client = new RA8RpcClient({ WebSocketClass: BadMagicWebSocket });
    await assert.rejects(() => client.connect("ws://127.0.0.1:4567"), /Incompatible RPC peer: magic 0xdeadbeef/);
  });

  await t.testAsync("client surfaces Fault frames via error event listener", async () => {
    const client = new RA8RpcClient({ WebSocketClass: AdversarialMockWebSocket });
    await client.connect("ws://127.0.0.1:4567");
    const server = client.ws.server;

    let errorReceived = null;
    client.on("error", (err) => {
      errorReceived = err;
    });
    server.sendToClient(encodeFrame(Kind.Fault, encodeFault(ErrorCode.BadArgs)));
    await new Promise((r) => setTimeout(r, 20));
    assert.notEqual(errorReceived, null);
    assert.match(errorReceived.message, /RPC fault code 2/);
    client.disconnect();
  });
}
