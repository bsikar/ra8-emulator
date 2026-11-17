/**
 * Workspace RPC codecs (`0x0140..0x0145`, topic `0x0180`)
 * matching `src/interfaces/rpc/workspace_wire.zig` and `src/host/workspace/entry.zig`.
 */

import {
  decodeU32,
  decodeUtf8,
  encodeSlice,
  encodeText,
  encodeU32,
  readSlice,
} from "../transport/envelope.js";

export const WORKSPACE_VERSION_BYTES = 25;
export const WORKSPACE_MAX_PATH = 4096;
export const WORKSPACE_MAX_FILE_BYTES = 262_144;

export enum WorkspaceEntryKind {
  Missing = 0,
  File = 1,
  Directory = 2,
  Symlink = 3,
  Other = 4,
}

export interface WorkspaceVersion {
  kind: WorkspaceEntryKind;
  size: bigint;
  modifiedNs: bigint;
  identity: bigint;
}

export const EMPTY_WORKSPACE_VERSION: WorkspaceVersion = {
  kind: WorkspaceEntryKind.Missing,
  size: 0n,
  modifiedNs: 0n,
  identity: 0n,
};

export interface WorkspaceEntry {
  name: string;
  kind: "missing" | "file" | "directory" | "symlink" | "other";
}

export interface WorkspaceListArgs {
  path: string;
  offset?: number;
  limit?: number;
}

export interface WorkspacePage {
  offset: number;
  count: number;
  more: boolean;
  entriesJson: string;
  entries: WorkspaceEntry[];
}

export interface WorkspaceReadArgs {
  path: string;
  offset?: bigint | number;
  length?: number;
}

export interface WorkspaceContents {
  version: WorkspaceVersion;
  versionBytes: Uint8Array;
  eof: boolean;
  bytes: Uint8Array;
}

export interface WorkspaceWriteArgs {
  path: string;
  expected?: WorkspaceVersion;
  bytes: Uint8Array;
}

export enum WorkspaceChangeState {
  Changed = 0,
  Removed = 1,
  Unavailable = 2,
}

export interface WorkspaceChange {
  id: number;
  state: WorkspaceChangeState;
  path: string;
  version: WorkspaceVersion;
  versionBytes: Uint8Array;
}

export function encodeWorkspaceVersion(version: WorkspaceVersion): Uint8Array {
  const buf = new Uint8Array(WORKSPACE_VERSION_BYTES);
  const view = new DataView(buf.buffer);
  view.setUint8(0, version.kind);
  view.setBigUint64(1, version.size, true);
  view.setBigInt64(9, version.modifiedNs, true);
  view.setBigUint64(17, version.identity, true);
  return buf;
}

export function decodeWorkspaceVersion(data: Uint8Array): WorkspaceVersion {
  if (data.length < WORKSPACE_VERSION_BYTES) {
    throw new Error(`Truncated WorkspaceVersion: requires ${WORKSPACE_VERSION_BYTES} bytes`);
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    kind: view.getUint8(0) as WorkspaceEntryKind,
    size: view.getBigUint64(1, true),
    modifiedNs: view.getBigInt64(9, true),
    identity: view.getBigUint64(17, true),
  };
}

export function encodeWorkspacePath(path: string): Uint8Array {
  return encodeText(path, WORKSPACE_MAX_PATH, "Workspace path");
}

export function encodeWorkspaceList(args: WorkspaceListArgs): Uint8Array {
  const pathSlice = encodeWorkspacePath(args.path);
  const buf = new Uint8Array(pathSlice.length + 6);
  buf.set(pathSlice, 0);
  const view = new DataView(buf.buffer);
  view.setUint32(pathSlice.length, (args.offset ?? 0) >>> 0, true);
  view.setUint16(pathSlice.length + 4, args.limit ?? 64, true);
  return buf;
}

export function decodeWorkspacePage(data: Uint8Array): WorkspacePage {
  if (data.length < 11) throw new Error("Truncated WorkspacePage header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const offset = view.getUint32(0, true);
  const count = view.getUint16(4, true);
  const more = view.getUint8(6) !== 0;
  const entriesJson = decodeUtf8(readSlice(data, { val: 7 }));
  const parsed = entriesJson.length > 0 ? (JSON.parse(entriesJson) as WorkspaceEntry[]) : [];
  return { offset, count, more, entriesJson, entries: parsed };
}

export function encodeWorkspaceRead(args: WorkspaceReadArgs): Uint8Array {
  const pathSlice = encodeWorkspacePath(args.path);
  const buf = new Uint8Array(pathSlice.length + 12);
  buf.set(pathSlice, 0);
  const view = new DataView(buf.buffer);
  view.setBigUint64(pathSlice.length, BigInt(args.offset ?? 0), true);
  view.setUint32(pathSlice.length + 8, (args.length ?? WORKSPACE_MAX_FILE_BYTES) >>> 0, true);
  return buf;
}

export function decodeWorkspaceContents(data: Uint8Array): WorkspaceContents {
  const at = { val: 0 };
  const versionBytes = readSlice(data, at);
  if (at.val >= data.length) throw new Error("Truncated WorkspaceContents eof");
  const eof = (data[at.val] ?? 0) !== 0;
  at.val += 1;
  const bytes = readSlice(data, at);
  return {
    version: decodeWorkspaceVersion(versionBytes),
    versionBytes,
    eof,
    bytes,
  };
}

export function encodeWorkspaceWrite(args: WorkspaceWriteArgs): Uint8Array {
  if (args.bytes.length > WORKSPACE_MAX_FILE_BYTES) {
    throw new Error(`WorkspaceWrite exceeds max ${WORKSPACE_MAX_FILE_BYTES} bytes`);
  }
  const pathSlice = encodeWorkspacePath(args.path);
  const expectedSlice = encodeSlice(encodeWorkspaceVersion(args.expected ?? EMPTY_WORKSPACE_VERSION));
  const bytesSlice = encodeSlice(args.bytes);
  const buf = new Uint8Array(pathSlice.length + expectedSlice.length + bytesSlice.length);
  buf.set(pathSlice, 0);
  buf.set(expectedSlice, pathSlice.length);
  buf.set(bytesSlice, pathSlice.length + expectedSlice.length);
  return buf;
}

export function encodeWorkspaceWatch(id: number): Uint8Array {
  return encodeU32(id);
}

export function decodeWorkspaceWatch(data: Uint8Array): number {
  return decodeU32(data);
}

export function decodeWorkspaceChange(data: Uint8Array): WorkspaceChange {
  if (data.length < 13) throw new Error("Truncated WorkspaceChange");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const id = view.getUint32(0, true);
  const state = view.getUint8(4) as WorkspaceChangeState;
  const at = { val: 5 };
  const path = decodeUtf8(readSlice(data, at));
  const versionBytes = readSlice(data, at);
  return {
    id,
    state,
    path,
    version: decodeWorkspaceVersion(versionBytes),
    versionBytes,
  };
}
