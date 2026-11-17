/**
 * Session-level wire event decoders and front-panel `BoardParts`
 * matching `src/interfaces/rpc/session/rpc.zig`.
 */

import { decodeUtf8, readSlice } from "../transport/envelope.js";
import { Core, EventKind, StopReason } from "./types.js";

export interface BoardParts {
  panel: string;
  panelWidth: number;
  panelHeight: number;
  ledNames: string[];
  ledColors: number[];
  switchNames: string[];
}

export interface Stopped {
  core: Core;
  reason: StopReason;
  address: number;
  detail: number;
}

export interface UartEvent {
  core: Core;
  channel: number;
  virtualNs: bigint;
  bytes: Uint8Array;
}

export interface SessionEvent {
  core: Core;
  kind: EventKind;
  address: number;
}

export interface DirtyRect {
  core: Core;
  x: number;
  y: number;
  width: number;
  height: number;
  virtualNs: bigint;
  pixels: Uint8Array;
}

export interface TransportEvent {
  epoch: bigint;
  phase: number;
  targetNs: bigint;
  reachedNs: bigint;
  slices: bigint;
  finished: number;
  core: Core;
  fromNs: bigint;
  toNs: bigint;
  reason: StopReason;
  address: number;
}

export function decodeStopped(data: Uint8Array): Stopped {
  if (data.length < 10) throw new Error("Truncated Stopped event");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    reason: view.getUint8(1) as StopReason,
    address: view.getUint32(2, true),
    detail: view.getUint32(6, true),
  };
}

export function decodeUart(data: Uint8Array): UartEvent {
  if (data.length < 14) throw new Error("Truncated Uart event header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const core = view.getUint8(0) as Core;
  const channel = view.getUint8(1);
  const virtualNs = view.getBigUint64(2, true);
  const len = view.getUint32(10, true);
  if (data.length < 14 + len) throw new Error("Truncated Uart bytes");
  return { core, channel, virtualNs, bytes: data.subarray(14, 14 + len) };
}

export function decodeSessionEvent(data: Uint8Array): SessionEvent {
  if (data.length < 6) throw new Error("Truncated SessionEvent");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    kind: view.getUint8(1) as EventKind,
    address: view.getUint32(2, true),
  };
}

export function decodeDirtyRect(data: Uint8Array): DirtyRect {
  if (data.length < 21) throw new Error("Truncated DirtyRect: requires at least 21 bytes header");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const core = view.getUint8(0) as Core;
  const x = view.getUint16(1, true);
  const y = view.getUint16(3, true);
  const width = view.getUint16(5, true);
  const height = view.getUint16(7, true);
  const virtualNs = view.getBigUint64(9, true);
  const pixelLen = view.getUint32(17, true);
  if (data.length < 21 + pixelLen) throw new Error("Truncated DirtyRect pixel buffer");
  return { core, x, y, width, height, virtualNs, pixels: data.subarray(21, 21 + pixelLen) };
}

export function encodeDirtyRect(rect: DirtyRect): Uint8Array {
  const pixelLen = rect.pixels.length;
  const buf = new Uint8Array(21 + pixelLen);
  const view = new DataView(buf.buffer);
  view.setUint8(0, rect.core);
  view.setUint16(1, rect.x, true);
  view.setUint16(3, rect.y, true);
  view.setUint16(5, rect.width, true);
  view.setUint16(7, rect.height, true);
  view.setBigUint64(9, rect.virtualNs, true);
  view.setUint32(17, pixelLen, true);
  buf.set(rect.pixels, 21);
  return buf;
}

export function decodeBoardParts(data: Uint8Array): BoardParts {
  const offset = { val: 0 };
  const panel = decodeUtf8(readSlice(data, offset));
  if (offset.val + 8 > data.length) throw new Error("Truncated BoardParts dims");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const panelWidth = view.getUint32(offset.val, true);
  const panelHeight = view.getUint32(offset.val + 4, true);
  offset.val += 8;
  const ledNamesRaw = decodeUtf8(readSlice(data, offset));
  const ledNames = ledNamesRaw.length > 0 ? ledNamesRaw.split("\n") : [];
  const ledColorsRaw = readSlice(data, offset);
  const ledColors: number[] = [];
  const colorView = new DataView(ledColorsRaw.buffer, ledColorsRaw.byteOffset, ledColorsRaw.byteLength);
  for (let i = 0; i + 1 < ledColorsRaw.length; i += 2) {
    ledColors.push(colorView.getUint16(i, true));
  }
  const switchNamesRaw = decodeUtf8(readSlice(data, offset));
  const switchNames = switchNamesRaw.length > 0 ? switchNamesRaw.split("\n") : [];
  return { panel, panelWidth, panelHeight, ledNames, ledColors, switchNames };
}

export function decodeTransportEvent(data: Uint8Array): TransportEvent {
  if (data.length < 56) throw new Error("Truncated TransportEvent: requires 56 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    epoch: view.getBigUint64(0, true),
    phase: view.getUint8(8),
    targetNs: view.getBigUint64(9, true),
    reachedNs: view.getBigUint64(17, true),
    slices: view.getBigUint64(25, true),
    finished: view.getUint8(33),
    core: view.getUint8(34) as Core,
    fromNs: view.getBigUint64(35, true),
    toNs: view.getBigUint64(43, true),
    reason: view.getUint8(51) as StopReason,
    address: view.getUint32(52, true),
  };
}
