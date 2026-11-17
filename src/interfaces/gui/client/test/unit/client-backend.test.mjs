import assert from "node:assert/strict";
import { createMockWsClass } from "../helpers/mock-ws.mjs";
import { createBackendHandler } from "../helpers/mock-backend-ws.mjs";
import {
  BuildEventKind,
  ErrorCode,
  Kind,
  RA8RpcClient,
  RpcCallError,
  TargetAction,
  Topic,
  WorkspaceChangeState,
  WorkspaceEntryKind,
  encodeEvent,
  encodeFrame,
  encodeSlice,
  encodeWorkspaceVersion,
} from "../../dist/index.js";

function buildWorkspaceChangeEventPayload(id, state, pathText) {
  const pathSlice = encodeSlice(new TextEncoder().encode(pathText));
  const verSlice = encodeSlice(encodeWorkspaceVersion({
    kind: WorkspaceEntryKind.File, size: 5n, modifiedNs: 2n, identity: 9n,
  }));
  const buf = new Uint8Array(5 + pathSlice.length + verSlice.length);
  new DataView(buf.buffer).setUint32(0, id, true);
  buf[4] = state;
  buf.set(pathSlice, 5);
  buf.set(verSlice, 5 + pathSlice.length);
  return buf;
}

function buildBuildEventPayload(id, seq, kind, line) {
  const slice = encodeSlice(new TextEncoder().encode(line));
  const buf = new Uint8Array(17 + slice.length);
  const v = new DataView(buf.buffer);
  v.setBigUint64(0, id, true);
  v.setBigUint64(8, seq, true);
  buf[16] = kind;
  buf.set(slice, 17);
  return buf;
}

function buildBuildStatusPayload(id, done, resultJson) {
  const slice = encodeSlice(new TextEncoder().encode(resultJson));
  const buf = new Uint8Array(9 + slice.length);
  const v = new DataView(buf.buffer);
  v.setBigUint64(0, id, true);
  buf[8] = done ? 1 : 0;
  buf.set(slice, 9);
  return buf;
}

async function verifyWorkspaceBuildProjectTargets(client) {
  const page = await client.workspaceList({ path: "", offset: 0, limit: 50 });
  assert.equal(page.more, false);
  assert.equal(page.entries.length, 2);
  assert.equal(page.entries[0]?.name, "src");

  const ver = await client.workspaceStat("main.c");
  assert.equal(ver.kind, WorkspaceEntryKind.File);
  assert.equal(ver.modifiedNs, 9_000_000n);
  assert.equal(ver.identity, 77n);

  const rd = await client.workspaceRead({ path: "main.c", offset: 0, length: 64 });
  assert.equal(rd.eof, true);
  assert.equal(new TextDecoder().decode(rd.bytes), "hello");

  const wr = await client.workspaceWrite({ path: "main.c", bytes: new Uint8Array([1, 2]) });
  assert.equal(wr.identity, 77n);

  const watchId = await client.workspaceWatch("src");
  assert.equal(watchId, 9);
  assert.equal(await client.workspaceUnwatch(watchId), true);

  const buildId = await client.buildStart({ step: "build", options: "[]", artifact: "" });
  assert.equal(buildId, 101n);
  const status = await client.buildStatus(buildId);
  assert.equal(status.done, true);
  assert.equal(JSON.parse(status.result).state, "ok");
  assert.equal(await client.buildCancel(buildId), true);

  assert.equal(await client.projectOpen("ra8.project.json"), true);
  const pBuildId = await client.projectBuild("default");
  assert.equal(pBuildId, 101n);
  const prepared = await client.projectPrepare(pBuildId);
  assert.equal(prepared.receipt, "receipt-01");
  assert.equal(await client.projectClose(), true);

  const { targets } = await client.targetsList();
  assert.equal(targets.length, 1);
  assert.equal(targets[0]?.target.model, "EK-RA8D2");
  const sel = { hostId: "h1", probeId: "p1", boardId: "b1", generation: 1n, disambiguation: "" };
  assert.equal(await client.targetsReserve(sel), true);
  assert.equal(await client.targetsPerform({ ...sel, action: TargetAction.Halt }), '{"halted":true}');
  assert.equal(await client.targetsRelease(), true);
}

async function verifyBackendEvents(client, srv) {
  const wsChPromise = new Promise((r) => client.once("workspace_change", r));
  srv.sendToClient(encodeFrame(Kind.Event, encodeEvent(
    Topic.WorkspaceChanged,
    buildWorkspaceChangeEventPayload(9, WorkspaceChangeState.Changed, "main.c")
  )));
  const wsCh = await wsChPromise;
  assert.equal(wsCh.state, WorkspaceChangeState.Changed);
  assert.equal(wsCh.path, "main.c");

  const bEvPromise = new Promise((r) => client.once("build_event", r));
  srv.sendToClient(encodeFrame(Kind.Event, encodeEvent(
    Topic.BuildEvent,
    buildBuildEventPayload(101n, 1n, BuildEventKind.Stdout, "linked app.elf")
  )));
  const bEv = await bEvPromise;
  assert.equal(new TextDecoder().decode(bEv.bytes), "linked app.elf");

  const bDonePromise = new Promise((r) => client.once("build_completed", r));
  srv.sendToClient(encodeFrame(Kind.Event, encodeEvent(
    Topic.BuildCompleted,
    buildBuildStatusPayload(101n, true, '{"exitCode":0}')
  )));
  const bDone = await bDonePromise;
  assert.equal(JSON.parse(bDone.result).exitCode, 0);
}

export async function run(t) {
  t.section("Workspace, Build, Project, & Targets");
  await t.testAsync("workspace, build, project, and target lease calls succeed", async () => {
    const { MockWebSocket, getServer } = createMockWsClass(createBackendHandler());
    const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
    await client.connect();
    await verifyWorkspaceBuildProjectTargets(client);
    await verifyBackendEvents(client, getServer());
    client.disconnect();
  });

  t.section("Artifacts Streaming & Error Codes");
  await t.testAsync("exportArtifact / importArtifact verify SHA-256 and propagate errors", async () => {
    const payload = new TextEncoder().encode("streaming-bundle-payload-check-9876543210");
    const { MockWebSocket } = createMockWsClass(createBackendHandler({ exportPayload: payload }));
    const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
    await client.connect();

    const exported = await client.exportArtifact(true, undefined, 10);
    assert.deepEqual(exported.bytes, payload);
    assert.equal(exported.total, BigInt(payload.length));

    const commit = await client.importArtifact(payload, undefined, 10);
    assert.equal(commit.accepted, true);
    assert.equal(commit.reconnect, true);
    client.disconnect();
  });

  await t.testAsync("corrupt export triggers ArtifactsAbort and RpcCallError on unknown method", async () => {
    const { MockWebSocket, getServer } = createMockWsClass(createBackendHandler({ corruptExport: true }));
    const client = new RA8RpcClient({ WebSocketClass: MockWebSocket });
    await client.connect();

    await assert.rejects(() => client.exportArtifact(false), /SHA-256 checksum mismatch/);
    await assert.rejects(
      () => client.call(0x0199, new Uint8Array(0)),
      (err) => err instanceof RpcCallError && err.code === ErrorCode.UnknownMethod
    );
    assert.ok(getServer().seenMethods.includes(0x0185));
    client.disconnect();
  });
}
