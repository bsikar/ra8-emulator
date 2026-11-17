import assert from "node:assert/strict";
import { createMockWsClass } from "../helpers/mock-ws.mjs";
import {
  Core,
  DEFAULT_CLIENT_CAPS,
  DEFAULT_RPC_URL,
  HistoryGap,
  HistoryPhase,
  Kind,
  LineOrder,
  Method,
  RA8RpcClient,
  Register,
  SetVarScope,
  SetVarStatus,
  StopReason,
  Topic,
  dirtyRectToRgba,
  encodeDirtyRect,
  encodeEvent,
  encodeFrame,
} from "../../dist/index.js";

async function checkSessionControl(client) {
  assert.equal(await client.step(Core.Cpu0), true);
  assert.equal(await client.run(Core.Cpu0), true);
  assert.equal(await client.pause(Core.Cpu0), true);
  assert.equal(await client.setRunBudget(Core.Cpu0, 50_000n), true);
  assert.equal(await client.setCameraSource("test://bars", false), true);

  const stopped = await client.interrupt(Core.Cpu0);
  assert.equal(stopped.reason, StopReason.HaltRequested);
  assert.equal(stopped.address, 0x0200_0120);

  const rtc = await client.getRtc(Core.Cpu0);
  assert.equal(rtc.valid, true);
  assert.equal(rtc.year, 2026);
  assert.equal(rtc.month, 11);

  const queued = await client.advanceAsync(Core.Cpu0, 50_000n);
  assert.equal(queued.core, Core.Cpu0);
  assert.equal(queued.fromNs, 1000n);
  assert.equal(queued.targetNs, 50_000n);
}

async function checkRegistersAndDebug(client) {
  const common = await client.readRegisters(Core.Cpu0);
  assert.equal(Object.keys(common).length, 19);
  assert.equal(common.r0, 0x1000_0000 + Register.R0);

  const sys = await client.readSysRegisters(Core.Cpu0);
  assert.equal(Object.keys(sys).length, 6);
  assert.equal(sys.primask, 0x1000_0000 + Register.Primask);
  assert.equal(sys.psplim, 0x1000_0000 + Register.Psplim);

  const fpu = await client.readFpuRegisters(Core.Cpu0);
  assert.equal(Object.keys(fpu).length, 34);
  assert.equal(fpu.fpscr, 0x1000_0000 + Register.Fpscr);
  assert.equal(fpu.vpr, 0x1000_0000 + Register.Vpr);
  assert.equal(fpu.s31, 0x1000_0000 + Register.S31);

  const ext = await client.readExtendedRegisters(Core.Cpu0);
  assert.equal(Object.keys(ext).length, 59);

  assert.equal(await client.getPeriph(Core.Cpu0, "riic1", false), "riic1\n");
  const parsedPeriph = await client.getPeriphJson(Core.Cpu0, "riic1");
  assert.equal(parsedPeriph.block, "riic1");

  const varReply = await client.setVar({ core: Core.Cpu0, frame: 0, name: "count", value: "99" });
  assert.equal(varReply.status, SetVarStatus.Ok);
  assert.equal(varReply.scope, SetVarScope.Local);
  assert.equal(varReply.message, "updated");
  assert.equal(await client.undoWrite(Core.Cpu0), true);
  assert.equal(await client.resetImage(Core.Cpu0), true);
}

async function checkHistoryLoadAndEvents(client, srv) {
  const nav = await client.setMarker("irq-entry", "now");
  assert.equal(nav.found, true);
  assert.equal(nav.branch, 2);
  assert.equal(nav.r, 912n);
  assert.equal(nav.phase, HistoryPhase.Cpu0);
  assert.equal(nav.gap, HistoryGap.Retired);
  assert.equal(nav.virtualNs, 1_824_000n);

  const diff = await client.getDiff("a", "b");
  assert.equal(diff.frames, 12);
  assert.equal(diff.a.r, 100n);
  assert.equal(diff.b.phase, HistoryPhase.Cpu1);
  assert.equal(diff.b.gap, HistoryGap.Polled);
  assert.equal(diff.order, LineOrder.Lt);
  assert.equal(diff.regs[0]?.name, "r0");
  assert.equal(diff.pages[0]?.address, 0x2200_1000);
  assert.equal(diff.periphs[0]?.unit, "riic1");

  assert.equal(await client.loadElf(Core.Cpu0, new Uint8Array(128)), true);
  let lastLoaded = 0;
  assert.equal(await client.loadElf(Core.Cpu0, new Uint8Array(70_000), (n) => { lastLoaded = n; }), true);
  assert.equal(lastLoaded, 70_000);
  assert.ok(srv.seenMethods.includes(Method.LoadBegin));
  assert.ok(srv.seenMethods.includes(Method.LoadChunk));
  assert.ok(srv.seenMethods.includes(Method.LoadEnd));

  assert.equal(await client.plug("lsm6dso@i2c:riic@0x6a", Core.Cpu0), true);
  assert.equal(await client.setFault("lsm6dso@i2c:riic@0x6a=nack:2", Core.Cpu0), true);
  assert.equal(await client.setFault("@i2c:riic@0x6a=disconnected", Core.Cpu0), true);
  assert.equal(await client.clearFault("i2c:riic@0x6a", Core.Cpu0), true);
  assert.equal(await client.unplug("i2c:riic@0x6a", Core.Cpu0), true);
  assert.equal(await client.snapshot("boot"), true);
  assert.equal(await client.restore("boot"), true);

  const dirtyPromise = new Promise((resolve) => client.once("lcd_dirty", resolve));
  const rgb565 = new Uint8Array([0x00, 0xf8]);
  srv.sendToClient(encodeFrame(Kind.Event, encodeEvent(Topic.LcdDirty, encodeDirtyRect({
    core: Core.Cpu0, x: 0, y: 0, width: 1, height: 1, virtualNs: 1n, pixels: rgb565,
  }))));
  const dirty = await dirtyPromise;
  assert.equal(dirty.width, 1);
  assert.deepEqual([...dirtyRectToRgba(dirty)], [255, 0, 0, 255]);
}

export async function run(t) {
  const { MockWebSocket, getServer } = createMockWsClass();

  t.section("Defaults & Handshake");
  await t.testAsync("connects with DEFAULT_CLIENT_CAPS and exposes DEFAULT_RPC_URL", async () => {
    assert.equal(DEFAULT_RPC_URL, "ws://127.0.0.1:4567");
    assert.equal(DEFAULT_CLIENT_CAPS, 0x003f_ffff);

    const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
    const hello = await client.connect();
    assert.equal(client.isConnected, true);
    assert.equal(client.connectTimer, null);
    assert.equal(hello.caps, 0x003f_ffff);
    assert.equal(client.serverCaps, 0x003f_ffff);
    client.disconnect();
    assert.equal(client.isConnected, false);
  });

  t.section("Session Control, Registers, & Time-Travel");
  await t.testAsync("session RPC calls, batched registers, setMarker 43B, getDiff 45B", async () => {
    const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
    await client.connect(DEFAULT_RPC_URL);
    await checkSessionControl(client);
    await checkRegistersAndDebug(client);
    await checkHistoryLoadAndEvents(client, getServer());
    client.disconnect();
  });
}
