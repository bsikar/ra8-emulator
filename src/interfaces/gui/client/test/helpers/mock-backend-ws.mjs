import {
  Method,
  ErrorCode,
  encodeU64,
  encodeU32,
  encodeWorkspaceVersion,
  WorkspaceEntryKind,
  sha256Bytes,
} from "../../dist/index.js";

function encodeSlice(bytes) {
  const buf = new Uint8Array(4 + bytes.length);
  new DataView(buf.buffer).setUint32(0, bytes.length, true);
  buf.set(bytes, 4);
  return buf;
}

function handleWorkspaceBuildMethod(req, srv, enc) {
  switch (req.method) {
    case Method.WorkspaceList: {
      const json = enc.encode('[{"name":"src","kind":"directory"},{"name":"main.c","kind":"file"}]');
      const buf = new Uint8Array(7 + 4 + json.length);
      const v = new DataView(buf.buffer);
      v.setUint32(0, 0, true);
      v.setUint16(4, 2, true);
      v.setUint8(6, 0);
      buf.set(encodeSlice(json), 7);
      srv.replyOk(req.id, buf);
      return true;
    }
    case Method.WorkspaceStat:
    case Method.WorkspaceWrite:
      srv.replyOk(req.id, encodeWorkspaceVersion({
        kind: WorkspaceEntryKind.File, size: 128n, modifiedNs: 9_000_000n, identity: 77n,
      }));
      return true;
    case Method.WorkspaceRead: {
      const verSlice = encodeSlice(encodeWorkspaceVersion({
        kind: WorkspaceEntryKind.File, size: 5n, modifiedNs: 1n, identity: 2n,
      }));
      const bodySlice = encodeSlice(enc.encode("hello"));
      const buf = new Uint8Array(verSlice.length + 1 + bodySlice.length);
      buf.set(verSlice, 0);
      buf[verSlice.length] = 1;
      buf.set(bodySlice, verSlice.length + 1);
      srv.replyOk(req.id, buf);
      return true;
    }
    case Method.WorkspaceWatch:
      srv.replyOk(req.id, encodeU32(9));
      return true;
    case Method.WorkspaceUnwatch:
    case Method.BuildCancel:
    case Method.ProjectOpen:
    case Method.ProjectClose:
    case Method.TargetsReserve:
    case Method.TargetsRelease:
      srv.replyOk(req.id, new Uint8Array([1]));
      return true;
    case Method.BuildStart:
    case Method.ProjectBuild:
      srv.replyOk(req.id, encodeU64(101n));
      return true;
    case Method.BuildStatus: {
      const slice = encodeSlice(enc.encode('{"state":"ok"}'));
      const buf = new Uint8Array(9 + slice.length);
      const v = new DataView(buf.buffer);
      v.setBigUint64(0, 101n, true);
      v.setUint8(8, 1);
      buf.set(slice, 9);
      srv.replyOk(req.id, buf);
      return true;
    }
    case Method.ProjectPrepare:
      srv.replyOk(req.id, encodeSlice(enc.encode("receipt-01")));
      return true;
    default:
      return false;
  }
}

function handleArtifactTargetMethod(req, srv, enc, state) {
  switch (req.method) {
    case Method.ArtifactsExportBegin:
      sha256Bytes(state.exportPayload).then((digest) => {
        if (state.corruptExport && digest.length > 0) digest[0] ^= 0xff;
        const shaSlice = encodeSlice(digest);
        const buf = new Uint8Array(16 + shaSlice.length);
        const v = new DataView(buf.buffer);
        v.setBigUint64(0, 55n, true);
        v.setBigUint64(8, BigInt(state.exportPayload.length), true);
        buf.set(shaSlice, 16);
        srv.replyOk(req.id, buf);
      });
      return true;
    case Method.ArtifactsExportRead: {
      const v = new DataView(req.args.buffer, req.args.byteOffset, req.args.byteLength);
      const id = v.getBigUint64(0, true);
      const offset = Number(v.getBigUint64(8, true));
      const length = v.getUint32(16, true);
      const chunkSlice = encodeSlice(state.exportPayload.subarray(offset, offset + length));
      const buf = new Uint8Array(16 + chunkSlice.length);
      const rv = new DataView(buf.buffer);
      rv.setBigUint64(0, id, true);
      rv.setBigUint64(8, BigInt(offset), true);
      buf.set(chunkSlice, 16);
      srv.replyOk(req.id, buf);
      return true;
    }
    case Method.ArtifactsImportBegin: {
      const total = Number(new DataView(req.args.buffer, req.args.byteOffset, req.args.byteLength).getBigUint64(0, true));
      state.importBuffer = new Uint8Array(total);
      srv.replyOk(req.id, encodeU64(88n));
      return true;
    }
    case Method.ArtifactsImportWrite: {
      const v = new DataView(req.args.buffer, req.args.byteOffset, req.args.byteLength);
      const offset = Number(v.getBigUint64(8, true));
      const len = v.getUint32(16, true);
      if (state.importBuffer) state.importBuffer.set(req.args.subarray(20, 20 + len), offset);
      srv.replyOk(req.id, new Uint8Array([1]));
      return true;
    }
    case Method.ArtifactsImportEnd:
      srv.replyOk(req.id, new Uint8Array([1, 1]));
      return true;
    case Method.ArtifactsAbort:
      srv.replyOk(req.id, new Uint8Array([1]));
      return true;
    case Method.TargetsList:
      srv.replyOk(req.id, encodeSlice(enc.encode('[{"target":{"host_id":"h1","probe_id":"p1","board_id":"b1","probe_serial":"","board_serial":"","vendor":"Renesas","model":"EK-RA8D2","cores":"cpu0,cpu1","transport":"usb","connection":"connected","disambiguation":"","identity_verified":true,"managed":false,"operations":["halt","step"],"capabilities":{"build":false,"flash":false,"hardware_debug":true,"emulation":true,"npu":false}},"generation":1,"reserved":false}]')));
      return true;
    case Method.TargetsPerform:
      srv.replyOk(req.id, encodeSlice(enc.encode('{"halted":true}')));
      return true;
    default:
      srv.replyErr(req.id, ErrorCode.UnknownMethod);
      return true;
  }
}

export function createBackendHandler(options = {}) {
  const state = {
    exportPayload: options.exportPayload ?? new TextEncoder().encode("bundle-bytes-0123456789"),
    importBuffer: null,
    corruptExport: options.corruptExport ?? false,
  };
  return (req, srv) => {
    const enc = new TextEncoder();
    return handleWorkspaceBuildMethod(req, srv, enc) || handleArtifactTargetMethod(req, srv, enc, state);
  };
}
