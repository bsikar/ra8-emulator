/**
 * DWARF source location, local variable inspection, and `set_var` codecs
 * matching `src/interfaces/rpc/session/{rpc,locals_wire,set_var_wire}.zig`.
 */

import { decodeUtf8, encodeText, readSlice } from "../transport/envelope.js";
import { Core } from "./types.js";

export interface SourceLineResult {
  found: boolean;
  pc: number;
  line: number;
  path: string;
}

export enum LocalWhereKind {
  None = 0,
  Frame = 1,
  RegisterIndirect = 2,
  InRegister = 3,
  Address = 4,
}

export interface LocalVariable {
  name: string;
  typeName: string;
  size: number;
  whereKind: LocalWhereKind;
  whereA: bigint;
  whereB: bigint;
}

export interface LocalsResult {
  core: Core;
  count: number;
  locals: LocalVariable[];
}

export enum SetVarStatus {
  Ok = 0,
  UnknownVariable = 1,
  NoDwarf = 2,
  ReadOnly = 3,
  InvalidValue = 4,
  Overflow = 5,
  UnsupportedType = 6,
  FrameUnavailable = 7,
  WriteFailed = 8,
}

export enum SetVarScope {
  None = 0,
  Global = 1,
  Local = 2,
}

export interface SetVarArgs {
  core: Core;
  frame: number;
  name: string;
  value: string;
}

export interface SetVarReply {
  status: SetVarStatus;
  scope: SetVarScope;
  address: number;
  inRegister: number;
  size: number;
  message: string;
}

export function decodeSourceLine(data: Uint8Array): SourceLineResult {
  if (data.length < 13) throw new Error("Truncated SourceLine: requires at least 13 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    found: view.getUint8(0) !== 0,
    pc: view.getUint32(1, true),
    line: view.getUint32(5, true),
    path: decodeUtf8(readSlice(data, { val: 9 })),
  };
}

export function encodeCoreFrame(core: Core, frame: number): Uint8Array {
  const buf = new Uint8Array(5);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, frame >>> 0, true);
  return buf;
}

export function decodeLocals(data: Uint8Array): LocalsResult {
  if (data.length < 6) throw new Error("Truncated Locals header: requires at least 6 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const core = view.getUint8(0) as Core;
  const count = view.getUint8(1);
  const rowsBytes = readSlice(data, { val: 2 });
  const locals: LocalVariable[] = [];
  let at = 0;
  for (let i = 0; i < count && at < rowsBytes.length; i++) {
    const rowLen = rowsBytes[at];
    if (rowLen === undefined || at + 1 + rowLen > rowsBytes.length) {
      throw new Error("Truncated LocalRow packet");
    }
    const rData = rowsBytes.subarray(at + 1, at + 1 + rowLen);
    at += 1 + rowLen;
    const rOff = { val: 0 };
    const name = decodeUtf8(readSlice(rData, rOff));
    const typeName = decodeUtf8(readSlice(rData, rOff));
    if (rOff.val + 21 > rData.length) throw new Error("Truncated LocalRow fixed fields");
    const rView = new DataView(rData.buffer, rData.byteOffset + rOff.val, rData.length - rOff.val);
    const whereKind = rView.getUint8(4) as LocalWhereKind;
    locals.push({
      name,
      typeName,
      size: rView.getUint32(0, true),
      whereKind,
      whereA: whereKind === LocalWhereKind.Frame ? rView.getBigInt64(5, true) : rView.getBigUint64(5, true),
      whereB: whereKind === LocalWhereKind.RegisterIndirect ? rView.getBigInt64(13, true) : rView.getBigUint64(13, true),
    });
  }
  return { core, count, locals };
}

export function encodeSetVarArgs(args: SetVarArgs): Uint8Array {
  const nameSlice = encodeText(args.name, 256, "SetVar name");
  const valSlice = encodeText(args.value, 256, "SetVar value");
  const buf = new Uint8Array(5 + nameSlice.length + valSlice.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, args.core);
  view.setUint32(1, args.frame >>> 0, true);
  buf.set(nameSlice, 5);
  buf.set(valSlice, 5 + nameSlice.length);
  return buf;
}

export function decodeSetVarReply(data: Uint8Array): SetVarReply {
  if (data.length < 15) throw new Error("Truncated SetVarReply: requires at least 15 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    status: view.getUint8(0) as SetVarStatus,
    scope: view.getUint8(1) as SetVarScope,
    address: view.getUint32(2, true),
    inRegister: view.getUint8(6),
    size: view.getUint32(7, true),
    message: decodeUtf8(readSlice(data, { val: 11 })),
  };
}
