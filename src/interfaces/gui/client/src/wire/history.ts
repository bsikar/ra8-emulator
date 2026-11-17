/**
 * Time-travel branch DAG, playback, navigation, and marker codecs
 * matching `src/interfaces/rpc/session/{branch_wire,nav_wire}.zig`.
 */

import { encodeText, encodeU32, readSlice } from "../transport/envelope.js";

export * from "./diff.js";

export enum ForkReason {
  Base = 0,
  Writes = 1,
  Taps = 2,
  Buttons = 3,
  Keystrokes = 4,
  PlugUnplugFault = 5,
  CameraChange = 6,
  SkipBkpt = 7,
  Load = 8,
}

export interface BranchItem {
  id: number;
  parent: number;
  forkR: bigint;
  recordedEndR: bigint;
  childCount: number;
  reason: ForkReason;
  flags: number;
  isLive: boolean;
  isKept: boolean;
  isPinned: boolean;
}

export interface ForkStatus {
  pending: boolean;
  reason: ForkReason;
  branch: number;
  r: bigint;
}

export enum Direction {
  Fwd = 0,
  Back = 1,
}

export interface PlayArgs {
  dir: Direction;
  speedMilli?: bigint;
}

export enum NavQueryKind {
  Frame = 0,
  Iteration = 1,
  Marker = 2,
  Rtos = 3,
  Isr = 4,
}

export interface NavQueryArgs {
  kind: NavQueryKind;
  index?: bigint;
  name?: string;
}

export interface NavQueryResult {
  found: boolean;
  branch: number;
  r: bigint;
  phase: number;
  o: number;
  gap: number;
  count: bigint;
  slots: bigint;
  virtualNs: bigint;
}

export interface FrameStatusResult {
  ramBytes: bigint;
  diskBytes: bigint;
  queueBytes: bigint;
  frames: bigint;
  decodedSegments: bigint;
}

const BRANCH_ITEM_BYTES = 30;

export function decodeBranchList(data: Uint8Array): BranchItem[] {
  if (data.length < 8) throw new Error("Truncated BranchList header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const count = view.getUint32(0, true);
  const bytes = readSlice(data, { val: 4 });
  const items: BranchItem[] = [];
  const available = Math.min(count, Math.floor(bytes.length / BRANCH_ITEM_BYTES));
  for (let i = 0; i < available; i++) {
    const base = i * BRANCH_ITEM_BYTES;
    const iView = new DataView(bytes.buffer, bytes.byteOffset + base, BRANCH_ITEM_BYTES);
    const flags = iView.getUint8(29);
    items.push({
      id: iView.getUint32(0, true),
      parent: iView.getUint32(4, true),
      forkR: iView.getBigUint64(8, true),
      recordedEndR: iView.getBigUint64(16, true),
      childCount: iView.getUint32(24, true),
      reason: iView.getUint8(28) as ForkReason,
      flags,
      isLive: (flags & 1) !== 0,
      isKept: (flags & 2) !== 0,
      isPinned: (flags & 4) !== 0,
    });
  }
  return items;
}

export function encodeBranchSwitch(branch: number): Uint8Array {
  return encodeU32(branch);
}

export function encodeBranchDelete(branch: number, confirm = false): Uint8Array {
  const buf = new Uint8Array(5);
  new DataView(buf.buffer).setUint32(0, branch >>> 0, true);
  buf[4] = confirm ? 1 : 0;
  return buf;
}

export function encodeBranchConfirmFork(confirm = true): Uint8Array {
  return new Uint8Array([confirm ? 1 : 0]);
}

export function decodeForkStatus(data: Uint8Array): ForkStatus {
  if (data.length < 14) throw new Error("Truncated ForkStatus: requires 14 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    pending: view.getUint8(0) !== 0,
    reason: view.getUint8(1) as ForkReason,
    branch: view.getUint32(2, true),
    r: view.getBigUint64(6, true),
  };
}

export function encodePlayArgs(args: PlayArgs): Uint8Array {
  const buf = new Uint8Array(9);
  const view = new DataView(buf.buffer);
  view.setUint8(0, args.dir);
  view.setBigUint64(1, BigInt(args.speedMilli ?? 0n), true);
  return buf;
}

export function encodeNavQueryArgs(args: NavQueryArgs): Uint8Array {
  const nameSlice = encodeText(args.name ?? "", 256, "NavQuery name");
  const buf = new Uint8Array(9 + nameSlice.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, args.kind);
  view.setBigUint64(1, BigInt(args.index ?? 0n), true);
  buf.set(nameSlice, 9);
  return buf;
}

export function decodeNavQueryResult(data: Uint8Array): NavQueryResult {
  if (data.length < 43) throw new Error("Truncated NavQueryResult: requires 43 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    found: view.getUint8(0) !== 0,
    branch: view.getUint32(1, true),
    r: view.getBigUint64(5, true),
    phase: view.getUint8(13),
    o: view.getUint32(14, true),
    gap: view.getUint8(18),
    count: view.getBigUint64(19, true),
    slots: view.getBigUint64(27, true),
    virtualNs: view.getBigUint64(35, true),
  };
}

export function encodeMarkerSetArgs(name: string, place: string): Uint8Array {
  const first = encodeText(name, 256, "MarkerSet name");
  const second = encodeText(place, 256, "MarkerSet place");
  const buf = new Uint8Array(first.length + second.length);
  buf.set(first, 0);
  buf.set(second, first.length);
  return buf;
}

export function decodeFrameStatusResult(data: Uint8Array): FrameStatusResult {
  if (data.length < 40) throw new Error("Truncated FrameStatusResult: requires 40 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    ramBytes: view.getBigUint64(0, true),
    diskBytes: view.getBigUint64(8, true),
    queueBytes: view.getBigUint64(16, true),
    frames: view.getBigUint64(24, true),
    decodedSegments: view.getBigUint64(32, true),
  };
}
