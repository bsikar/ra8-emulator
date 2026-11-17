import assert from "node:assert/strict";
import {
  BuildEventKind,
  EMPTY_WORKSPACE_VERSION,
  TargetAction,
  WORKSPACE_VERSION_BYTES,
  WorkspaceChangeState,
  WorkspaceEntryKind,
  decodeArtifactChunk,
  decodeArtifactCommit,
  decodeArtifactDescriptor,
  decodeArtifactId,
  decodeBuildEvent,
  decodeBuildId,
  decodeBuildStatus,
  decodeProjectPrepared,
  decodeTargetsList,
  decodeWorkspaceChange,
  decodeWorkspaceContents,
  decodeWorkspacePage,
  decodeWorkspaceVersion,
  encodeArtifactBegin,
  encodeArtifactChunk,
  encodeArtifactExport,
  encodeArtifactId,
  encodeArtifactRead,
  encodeBuildId,
  encodeBuildStart,
  encodeProjectBuild,
  encodeProjectOpen,
  encodeTargetPerform,
  encodeTargetSelection,
  encodeWorkspaceList,
  encodeWorkspacePath,
  encodeWorkspaceRead,
  encodeWorkspaceVersion,
  encodeWorkspaceWrite,
} from "../../dist/index.js";

function slice(bytes) {
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, bytes.length, true);
  out.set(bytes, 4);
  return out;
}

function registerWorkspaceAndBuildTests(suite) {
  suite.section("Backend RPC Codecs (0x0140..0x0193)");

  suite.test("Workspace version (25B signed modifiedNs), list, read, write, change codecs", () => {
    const ver = {
      kind: WorkspaceEntryKind.File,
      size: 23n,
      modifiedNs: -45n,
      identity: 67n,
    };
    const verBytes = encodeWorkspaceVersion(ver);
    assert.equal(verBytes.length, WORKSPACE_VERSION_BYTES);
    assert.deepEqual(decodeWorkspaceVersion(verBytes), ver);

    assert.equal(encodeWorkspacePath("src/main.c").length, 14);
    const listArgs = encodeWorkspaceList({ path: "src", offset: 10, limit: 32 });
    assert.equal(new DataView(listArgs.buffer).getUint32(7, true), 10);
    assert.equal(new DataView(listArgs.buffer).getUint16(11, true), 32);

    const pageJson = new TextEncoder().encode('[{"name":"a.c","kind":"file"}]');
    const pageBuf = new Uint8Array(7 + 4 + pageJson.length);
    new DataView(pageBuf.buffer).setUint16(4, 1, true);
    new DataView(pageBuf.buffer).setUint8(6, 1);
    pageBuf.set(slice(pageJson), 7);
    const page = decodeWorkspacePage(pageBuf);
    assert.equal(page.more, true);
    assert.equal(page.entries[0]?.name, "a.c");

    assert.equal(encodeWorkspaceRead({ path: "a.c", offset: 4n, length: 128 }).length, 19);
    const wr = encodeWorkspaceWrite({ path: "a.c", expected: EMPTY_WORKSPACE_VERSION, bytes: new Uint8Array([1, 2]) });
    assert.ok(wr.length > 25);

    const verSlice = slice(verBytes);
    const bodySlice = slice(new TextEncoder().encode("hi"));
    const contents = new Uint8Array(verSlice.length + 1 + bodySlice.length);
    contents.set(verSlice, 0);
    contents[verSlice.length] = 1;
    contents.set(bodySlice, verSlice.length + 1);
    const decodedContents = decodeWorkspaceContents(contents);
    assert.equal(decodedContents.eof, true);
    assert.equal(decodedContents.version.modifiedNs, -45n);

    const pathSlice = slice(new TextEncoder().encode("src/a.c"));
    const change = new Uint8Array(5 + pathSlice.length + verSlice.length);
    new DataView(change.buffer).setUint32(0, 7, true);
    change[4] = WorkspaceChangeState.Changed;
    change.set(pathSlice, 5);
    change.set(verSlice, 5 + pathSlice.length);
    const decodedChange = decodeWorkspaceChange(change);
    assert.equal(decodedChange.id, 7);
    assert.equal(decodedChange.state, WorkspaceChangeState.Changed);
    assert.equal(decodedChange.path, "src/a.c");
  });
}

function registerBuildArtifactsTargetsTests(suite) {
  suite.test("Build (0x0160..0x0162) and Project (0x0170..0x0173) codecs", () => {
    const bs = encodeBuildStart({ step: "firmware", options: "[]", artifact: "out.elf", timeoutMs: 5000 });
    assert.ok(bs.length > 16);
    assert.equal(encodeBuildId(99n).length, 8);
    assert.equal(decodeBuildId(encodeBuildId(99n)), 99n);

    const resSlice = slice(new TextEncoder().encode('{"state":"ok"}'));
    const st = new Uint8Array(9 + resSlice.length);
    new DataView(st.buffer).setBigUint64(0, 99n, true);
    st[8] = 1;
    st.set(resSlice, 9);
    const decodedSt = decodeBuildStatus(st);
    assert.equal(decodedSt.id, 99n);
    assert.equal(decodedSt.done, true);

    const lineSlice = slice(new TextEncoder().encode("compiling"));
    const ev = new Uint8Array(17 + lineSlice.length);
    const evView = new DataView(ev.buffer);
    evView.setBigUint64(0, 99n, true);
    evView.setBigUint64(8, 3n, true);
    evView.setUint8(16, BuildEventKind.Stdout);
    ev.set(lineSlice, 17);
    assert.equal(decodeBuildEvent(ev).sequence, 3n);

    assert.equal(encodeProjectOpen("project.json").length, 16);
    assert.equal(encodeProjectBuild("debug").length, 9);
    assert.equal(decodeProjectPrepared(slice(new TextEncoder().encode("done"))).receipt, "done");
  });

  suite.test("Artifacts (0x0180..0x0185) and Targets (0x0190..0x0193) codecs", () => {
    assert.deepEqual(Array.from(encodeArtifactExport(true)), [1]);
    const sha = new Uint8Array(32).fill(0x55);
    const beg = encodeArtifactBegin(1024n, sha);
    assert.equal(beg.length, 8 + 4 + 32);
    assert.equal(encodeArtifactRead(1n, 0n, 4096).length, 20);
    assert.equal(encodeArtifactChunk(1n, 0n, new Uint8Array(10)).length, 16 + 4 + 10);
    assert.equal(encodeArtifactId(1n).length, 8);
    assert.equal(decodeArtifactId(encodeArtifactId(7n)), 7n);

    const desc = new Uint8Array(16 + 4 + 32);
    new DataView(desc.buffer).setBigUint64(0, 3n, true);
    new DataView(desc.buffer).setBigUint64(8, 512n, true);
    desc.set(slice(sha), 16);
    assert.equal(decodeArtifactDescriptor(desc).total, 512n);

    const chk = new Uint8Array(16 + 4 + 3);
    new DataView(chk.buffer).setBigUint64(0, 3n, true);
    chk.set(slice(new Uint8Array([1, 2, 3])), 16);
    assert.equal(decodeArtifactChunk(chk).bytes.length, 3);
    assert.equal(decodeArtifactCommit(new Uint8Array([1, 1])).reconnect, true);

    const sel = {
      hostId: "host",
      probeId: "probe",
      boardId: "board",
      generation: 0xffff_ffff_ffff_fffen,
      disambiguation: "physical-binding",
    };
    const perf = encodeTargetPerform({ ...sel, action: TargetAction.Step });
    assert.equal(perf[perf.length - 1], TargetAction.Step);
    assert.equal(encodeTargetSelection(sel).length + 1, perf.length);
    const list = decodeTargetsList(slice(new TextEncoder().encode('[{"generation":1,"reserved":false,"target":{"host_id":"h","probe_id":"p","board_id":"b","probe_serial":"","board_serial":"","vendor":"","model":"","cores":"","transport":"usb","connection":"connected","disambiguation":"","identity_verified":true,"managed":false,"operations":[],"capabilities":{"build":false,"flash":false,"hardware_debug":false,"emulation":true,"npu":false}}}]')));
    assert.equal(list.targets.length, 1);
  });
}

export function run(suite) {
  registerWorkspaceAndBuildTests(suite);
  registerBuildArtifactsTargetsTests(suite);
}
