/**
 * Architectural state diff (`0x013C`) wire codec matching `src/interfaces/rpc/session/diff_wire.zig`.
 */

import { decodeUtf8, encodeText, readSlice } from "../transport/envelope.js";
import { Core } from "./types.js";

export enum HistoryPhase {
  Cpu0 = 0,
  Cpu1 = 1,
  Board = 2,
}

export enum HistoryGap {
  Retired = 0,
  Polled = 1,
}

export enum LineOrder {
  Lt = 0,
  Eq = 1,
  Gt = 2,
  OtherLine = 3,
}

export interface DiffSide {
  branch: number;
  r: bigint;
  phase: HistoryPhase;
  o: number;
  gap: HistoryGap;
}

export interface DiffRegItem {
  core: Core;
  name: string;
  valA: number;
  valB: number;
}

export interface DiffPageItem {
  space: number;
  pageIndex: number;
  address: number;
  hasA: boolean;
  objA: Uint8Array;
  hasB: boolean;
  objB: Uint8Array;
}

export interface DiffPeriphItem {
  unit: string;
  offset: number;
  oldVal: number;
  newVal: number;
  changedBytes: number;
}

export interface DecodedDiff {
  frames: number;
  a: DiffSide;
  b: DiffSide;
  order: LineOrder;
  regs: DiffRegItem[];
  pages: DiffPageItem[];
  periphs: DiffPeriphItem[];
}

const DIFF_HEADER_BYTES = 45;

export function encodeDiffArgs(a: string, b: string): Uint8Array {
  const first = encodeText(a, 128, "Diff side a");
  const second = encodeText(b, 128, "Diff side b");
  const buf = new Uint8Array(first.length + second.length);
  buf.set(first, 0);
  buf.set(second, first.length);
  return buf;
}

function readHistoryPosition(view: DataView, at: { val: number }): DiffSide {
  const branch = view.getUint32(at.val, true);
  const r = view.getBigUint64(at.val + 4, true);
  const phaseRaw = view.getUint8(at.val + 12);
  const o = view.getUint32(at.val + 13, true);
  const gapRaw = view.getUint8(at.val + 17);
  at.val += 18;
  if (phaseRaw > 2) throw new Error(`Invalid HistoryPosition phase: ${phaseRaw}`);
  if (gapRaw > 1) throw new Error(`Invalid HistoryPosition gap: ${gapRaw}`);
  return { branch, r, phase: phaseRaw as HistoryPhase, o, gap: gapRaw as HistoryGap };
}

function decodeDiffRegs(
  bytes: Uint8Array,
  view: DataView,
  at: { val: number },
  count: number
): DiffRegItem[] {
  const regs: DiffRegItem[] = [];
  for (let i = 0; i < count; i++) {
    if (at.val + 2 > bytes.length) throw new Error("Truncated DiffRegItem header");
    const core = bytes[at.val] as Core;
    const nlen = bytes[at.val + 1] ?? 0;
    at.val += 2;
    if (at.val + nlen + 8 > bytes.length) throw new Error("Truncated DiffRegItem body");
    const name = decodeUtf8(bytes.subarray(at.val, at.val + nlen));
    at.val += nlen;
    const valA = view.getUint32(at.val, true);
    const valB = view.getUint32(at.val + 4, true);
    at.val += 8;
    regs.push({ core, name, valA, valB });
  }
  return regs;
}

function decodeDiffPages(
  bytes: Uint8Array,
  view: DataView,
  at: { val: number },
  count: number
): DiffPageItem[] {
  const pages: DiffPageItem[] = [];
  for (let i = 0; i < count; i++) {
    if (at.val + 43 > bytes.length) throw new Error("Truncated DiffPageItem");
    pages.push({
      space: bytes[at.val] ?? 0,
      pageIndex: view.getUint32(at.val + 1, true),
      address: view.getUint32(at.val + 5, true),
      hasA: (bytes[at.val + 9] ?? 0) !== 0,
      objA: bytes.slice(at.val + 10, at.val + 26),
      hasB: (bytes[at.val + 26] ?? 0) !== 0,
      objB: bytes.slice(at.val + 27, at.val + 43),
    });
    at.val += 43;
  }
  return pages;
}

function decodeDiffPeriphs(
  bytes: Uint8Array,
  view: DataView,
  at: { val: number },
  count: number
): DiffPeriphItem[] {
  const periphs: DiffPeriphItem[] = [];
  for (let i = 0; i < count; i++) {
    if (at.val + 1 > bytes.length) throw new Error("Truncated DiffPeriphItem header");
    const ulen = bytes[at.val] ?? 0;
    at.val += 1;
    if (at.val + ulen + 16 > bytes.length) throw new Error("Truncated DiffPeriphItem body");
    const unit = decodeUtf8(bytes.subarray(at.val, at.val + ulen));
    at.val += ulen;
    periphs.push({
      unit,
      offset: view.getUint32(at.val, true),
      oldVal: view.getUint32(at.val + 4, true),
      newVal: view.getUint32(at.val + 8, true),
      changedBytes: view.getUint32(at.val + 12, true),
    });
    at.val += 16;
  }
  return periphs;
}

/** Decode DiffWire reply (`0x013C`) with exact 45-byte header per `diff_wire.zig`. */
export function decodeDiff(data: Uint8Array): DecodedDiff {
  const bytes = readSlice(data, { val: 0 });
  if (bytes.length < DIFF_HEADER_BYTES) {
    throw new Error(`Truncated DiffWire header: requires ${DIFF_HEADER_BYTES} bytes`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const regCount = view.getUint16(0, true);
  const pageCount = view.getUint16(2, true);
  const periphCount = view.getUint16(4, true);
  const frames = view.getUint16(6, true);
  const at = { val: 8 };
  const a = readHistoryPosition(view, at);
  const b = readHistoryPosition(view, at);
  const orderByte = bytes[at.val] ?? 255;
  at.val += 1;
  if (orderByte > 3) throw new Error(`Invalid DiffWire LineOrder: ${orderByte}`);

  const regs = decodeDiffRegs(bytes, view, at, regCount);
  const pages = decodeDiffPages(bytes, view, at, pageCount);
  const periphs = decodeDiffPeriphs(bytes, view, at, periphCount);
  return { frames, a, b, order: orderByte as LineOrder, regs, pages, periphs };
}
