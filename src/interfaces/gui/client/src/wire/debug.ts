/**
 * Debugging, disassembly, memory, breakpoints, and backtrace codecs
 * matching `src/interfaces/rpc/session/{rpc,disasm_wire,backtrace_wire}.zig`.
 */

import { decodeUtf8, encodeUtf8, readSlice } from "../transport/envelope.js";
import { Register } from "./registers.js";
import { Access, Core } from "./types.js";

export * from "./registers.js";
export * from "./debug-dwarf.js";

export interface ReadRegisterArgs {
  core: Core;
  register: Register;
}

export interface WriteRegisterArgs {
  core: Core;
  register: Register;
  value: number;
}

export interface ReadMemoryArgs {
  core: Core;
  address: number;
  length: number;
}

export interface WriteMemoryArgs {
  core: Core;
  address: number;
  bytes: Uint8Array;
}

export interface SetBreakpointArgs {
  core: Core;
  address: number;
}

export interface SetNamedBreakpointArgs {
  core: Core;
  name: string;
}

export interface NamedPointResult {
  id: number;
  address: number;
  deferred: boolean;
}

export interface PointIdArgs {
  core: Core;
  id: number;
}

export interface SetWatchpointArgs {
  core: Core;
  first: number;
  last: number;
  access: Access;
}

export interface StackFrame {
  pc: number;
  interrupted: number;
  offset: number;
  line: number;
  name: string;
  file: string;
}

export interface Backtrace {
  core: Core;
  count: number;
  frames: StackFrame[];
}

export interface DisasmAsk {
  core: Core;
  address?: number;
  count?: number;
  usePc?: boolean;
}

export interface DisasmRow {
  address: number;
  size: number;
  decoded: boolean;
  raw: Uint8Array;
  text: string;
  symbol: string;
  pseudo?: string;
}

export interface DisasmReply {
  core: Core;
  pc: number;
  count: number;
  rows: DisasmRow[];
}

export function encodeReadRegister(core: Core, register: Register): Uint8Array {
  return new Uint8Array([core, register]);
}

export function encodeWriteRegister(core: Core, register: Register, value: number): Uint8Array {
  const buf = new Uint8Array(6);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint8(1, register);
  view.setUint32(2, value >>> 0, true);
  return buf;
}

export function encodeReadMemory(core: Core, address: number, length: number): Uint8Array {
  const buf = new Uint8Array(9);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, address >>> 0, true);
  view.setUint32(5, length >>> 0, true);
  return buf;
}

export function decodeMemory(data: Uint8Array): Uint8Array {
  if (data.length < 4) throw new Error("Truncated Memory slice");
  const len = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(0, true);
  if (data.length < 4 + len) throw new Error("Truncated Memory bytes");
  return data.subarray(4, 4 + len);
}

export function encodeWriteMemory(core: Core, address: number, bytes: Uint8Array): Uint8Array {
  const buf = new Uint8Array(9 + bytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, address >>> 0, true);
  view.setUint32(5, bytes.length, true);
  buf.set(bytes, 9);
  return buf;
}

export function encodePoint(core: Core, address: number): Uint8Array {
  const buf = new Uint8Array(5);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, address >>> 0, true);
  return buf;
}

export function encodePointId(core: Core, id: number): Uint8Array {
  return encodePoint(core, id);
}

export function encodeNamedBreak(core: Core, name: string): Uint8Array {
  const nameBytes = encodeUtf8(name);
  const buf = new Uint8Array(5 + nameBytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, nameBytes.length, true);
  buf.set(nameBytes, 5);
  return buf;
}

export function decodeNamedPoint(data: Uint8Array): NamedPointResult {
  if (data.length < 9) throw new Error("Truncated NamedPoint: requires 9 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    id: view.getUint32(0, true),
    address: view.getUint32(4, true),
    deferred: view.getUint8(8) !== 0,
  };
}

export function encodeWatchpoint(core: Core, first: number, last: number, access: Access): Uint8Array {
  const buf = new Uint8Array(10);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, first >>> 0, true);
  view.setUint32(5, last >>> 0, true);
  view.setUint8(9, access);
  return buf;
}

export function encodeMapAsk(core: Core, json = false): Uint8Array {
  return new Uint8Array([core, json ? 1 : 0]);
}

export function encodePeriphAsk(core: Core, block = "", json = false): Uint8Array {
  const blockBytes = encodeUtf8(block);
  const buf = new Uint8Array(6 + blockBytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint8(1, json ? 1 : 0);
  view.setUint32(2, blockBytes.length, true);
  buf.set(blockBytes, 6);
  return buf;
}

export function encodeDisasmAsk(args: DisasmAsk): Uint8Array {
  const buf = new Uint8Array(7);
  const view = new DataView(buf.buffer);
  view.setUint8(0, args.core);
  view.setUint32(1, (args.address ?? 0) >>> 0, true);
  view.setUint8(5, args.count ?? 24);
  view.setUint8(6, args.usePc ? 1 : 0);
  return buf;
}

export function decodeDisasmReply(data: Uint8Array): DisasmReply {
  if (data.length < 10) throw new Error("Truncated DisasmReply header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const core = view.getUint8(0) as Core;
  const pc = view.getUint32(1, true);
  const count = view.getUint8(5);
  const rowsLen = view.getUint32(6, true);
  if (data.length < 10 + rowsLen) throw new Error("Truncated DisasmReply rows");

  const rowsBytes = data.subarray(10, 10 + rowsLen);
  const rows: DisasmRow[] = [];
  let at = 0;
  for (let i = 0; i < count && at < rowsBytes.length; i++) {
    if (at + 13 > rowsBytes.length) throw new Error("Truncated DisasmRow header");
    const rView = new DataView(rowsBytes.buffer, rowsBytes.byteOffset + at, rowsBytes.length - at);
    const tlen = rView.getUint8(10);
    if (at + 11 + tlen + 1 > rowsBytes.length) throw new Error("Truncated DisasmRow text");
    const slen = rowsBytes[at + 11 + tlen] ?? 0;
    const symEnd = 12 + tlen + slen;
    if (at + symEnd + 1 > rowsBytes.length) throw new Error("Truncated DisasmRow symbol");
    const plen = rowsBytes[at + symEnd] ?? 0;
    const total = symEnd + 1 + plen;
    if (at + total > rowsBytes.length) throw new Error("Truncated DisasmRow pseudo");
    rows.push({
      address: rView.getUint32(0, true),
      size: rView.getUint8(4),
      decoded: rView.getUint8(5) !== 0,
      raw: rowsBytes.slice(at + 6, at + 10),
      text: decodeUtf8(rowsBytes.subarray(at + 11, at + 11 + tlen)),
      symbol: decodeUtf8(rowsBytes.subarray(at + 12 + tlen, at + symEnd)),
      pseudo: decodeUtf8(rowsBytes.subarray(at + symEnd + 1, at + total)),
    });
    at += total;
  }
  return { core, pc, count, rows };
}

export function decodeBacktrace(data: Uint8Array): Backtrace {
  if (data.length < 6) throw new Error("Truncated Backtrace header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const core = view.getUint8(0) as Core;
  const count = view.getUint8(1);
  const framesLen = view.getUint32(2, true);
  if (data.length < 6 + framesLen) throw new Error("Truncated Backtrace frames");
  const framesBytes = data.subarray(6, 6 + framesLen);
  const frames: StackFrame[] = [];
  let at = 0;
  for (let i = 0; i < count && at < framesBytes.length; i++) {
    const frameLen = framesBytes[at];
    if (frameLen === undefined) break;
    at += 1;
    if (at + frameLen > framesBytes.length) break;
    const fData = framesBytes.subarray(at, at + frameLen);
    at += frameLen;
    if (fData.length < 13) continue;
    const fView = new DataView(fData.buffer, fData.byteOffset, fData.byteLength);
    const sliceOffset = { val: 13 };
    frames.push({
      pc: fView.getUint32(0, true),
      interrupted: fView.getUint8(4),
      offset: fView.getUint32(5, true),
      line: fView.getUint32(9, true),
      name: decodeUtf8(readSlice(fData, sliceOffset)),
      file: decodeUtf8(readSlice(fData, sliceOffset)),
    });
  }
  return { core, count, frames };
}
