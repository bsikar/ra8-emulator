/**
 * Session lifecycle, execution control, camera, RTC, input, and ELF upload codecs
 * matching `src/interfaces/rpc/session/{rpc,camera,rtc,advance,intervene}.zig`.
 */

import { crc32 } from "../binary/crc32.js";
import {
  decodeAck,
  encodeCoreOnly,
  encodeText,
  encodeUtf8,
} from "../transport/envelope.js";
import { Core, InputKind, Method, RunMode, StopReason, Topic } from "./types.js";

export * from "./session-events.js";

export interface CoreOnlyArgs {
  core: Core;
}

export interface RunArgs {
  core: Core;
  mode: RunMode;
  budget: bigint;
}

export interface SubscriptionArgs {
  core: Core;
  topic: Topic;
  rate?: number;
}

export interface AdvanceArgs {
  core: Core;
  ns: bigint;
}

export interface AdvanceQueued {
  core: Core;
  fromNs: bigint;
  targetNs: bigint;
}

export interface AdvancedResult {
  core: Core;
  fromNs: bigint;
  toNs: bigint;
  reason: StopReason;
  address: number;
}

export interface SeekArgs {
  target: string;
}

export interface PartSpecArgs {
  core: Core;
  text: string;
}

export interface CameraSourceArgs {
  text: string;
  allowWebcam?: boolean;
}

export interface RtcReport {
  running: boolean;
  valid: boolean;
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

export interface ScheduleInputArgs {
  core: Core;
  atNs?: bigint;
  kind: InputKind;
  x?: number;
  y?: number;
  toX?: number;
  toY?: number;
  durationNs?: bigint;
  button?: number;
}

export function encodeRun(core: Core, mode: RunMode, budget = 0n): Uint8Array {
  const buf = new Uint8Array(10);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint8(1, mode);
  view.setBigUint64(2, budget, true);
  return buf;
}

export function encodeRunBudget(core: Core, instructions: bigint | number): Uint8Array {
  const buf = new Uint8Array(9);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setBigUint64(1, BigInt(instructions), true);
  return buf;
}

export function encodeSetSpeed(core: Core, milli: bigint | number): Uint8Array {
  const buf = new Uint8Array(9);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setBigUint64(1, BigInt(milli), true);
  return buf;
}

export function encodeSubscription(core: Core, topic: Topic, rate = 0): Uint8Array {
  const buf = new Uint8Array(5);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint16(1, topic, true);
  view.setUint16(3, rate, true);
  return buf;
}

export function encodeAdvance(core: Core, ns: bigint): Uint8Array {
  const buf = new Uint8Array(9);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setBigUint64(1, ns, true);
  return buf;
}

export function decodeAdvanceQueued(data: Uint8Array): AdvanceQueued {
  if (data.length < 17) throw new Error("Truncated AdvanceQueued: requires 17 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    fromNs: view.getBigUint64(1, true),
    targetNs: view.getBigUint64(9, true),
  };
}

export function decodeAdvanced(data: Uint8Array): AdvancedResult {
  if (data.length < 22) throw new Error("Truncated Advanced reply: requires 22 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    fromNs: view.getBigUint64(1, true),
    toNs: view.getBigUint64(9, true),
    reason: view.getUint8(17) as StopReason,
    address: view.getUint32(18, true),
  };
}

export function encodeSeek(target: string): Uint8Array {
  return encodeText(target, 256, "Seek target");
}

export function encodeCameraSource(text: string, allowWebcam = false): Uint8Array {
  const textSlice = encodeText(text, 512, "CameraSource text");
  const buf = new Uint8Array(textSlice.length + 1);
  buf.set(textSlice, 0);
  buf[textSlice.length] = allowWebcam ? 1 : 0;
  return buf;
}

export function decodeRtcReport(data: Uint8Array): RtcReport {
  if (data.length < 9) throw new Error("Truncated RtcReport: requires 9 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    running: view.getUint8(0) !== 0,
    valid: view.getUint8(1) !== 0,
    year: view.getUint16(2, true),
    month: view.getUint8(4),
    day: view.getUint8(5),
    hour: view.getUint8(6),
    minute: view.getUint8(7),
    second: view.getUint8(8),
  };
}

export function encodeScheduleInput(args: ScheduleInputArgs): Uint8Array {
  const buf = new Uint8Array(27);
  const view = new DataView(buf.buffer);
  view.setUint8(0, args.core);
  view.setBigUint64(1, BigInt(args.atNs ?? 0n), true);
  view.setUint8(9, args.kind);
  view.setUint16(10, args.x ?? 0, true);
  view.setUint16(12, args.y ?? 0, true);
  view.setUint16(14, args.toX ?? 0, true);
  view.setUint16(16, args.toY ?? 0, true);
  view.setBigUint64(18, BigInt(args.durationNs ?? 0n), true);
  view.setUint8(26, args.button ?? 0);
  return buf;
}

export function encodeConsoleInput(core: Core, bytes: Uint8Array): Uint8Array {
  const buf = new Uint8Array(5 + bytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, bytes.length, true);
  buf.set(bytes, 5);
  return buf;
}

export function encodePartSpec(spec: string, core: Core = Core.Cpu0): Uint8Array {
  const bytes = encodeUtf8(spec);
  if (bytes.length === 0) throw new Error("PartSpec text must not be empty");
  if (bytes.length > 256) throw new Error("PartSpec text must not exceed 256 UTF-8 bytes");
  const buf = new Uint8Array(5 + bytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, bytes.length, true);
  buf.set(bytes, 5);
  return buf;
}

export function encodeStatePath(bareName: string): Uint8Array {
  if (!bareName) throw new Error("StatePath must not be empty");
  if (
    bareName === "." ||
    bareName === ".." ||
    bareName.includes("/") ||
    bareName.includes("\\") ||
    bareName.includes("\0")
  ) {
    throw new Error("StatePath must be a bare name without directory separators");
  }
  return encodeText(bareName, 4096, "StatePath");
}

export function encodeLoad(core: Core, image: Uint8Array): Uint8Array {
  const buf = new Uint8Array(5 + image.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, image.length, true);
  buf.set(image, 5);
  return buf;
}

export function encodeLoadBegin(core: Core, totalLen: bigint | number, checksum: number): Uint8Array {
  const buf = new Uint8Array(13);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setBigUint64(1, BigInt(totalLen), true);
  view.setUint32(9, checksum >>> 0, true);
  return buf;
}

export function encodeLoadChunk(core: Core, offset: bigint | number, bytes: Uint8Array): Uint8Array {
  const buf = new Uint8Array(13 + bytes.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setBigUint64(1, BigInt(offset), true);
  view.setUint32(9, bytes.length, true);
  buf.set(bytes, 13);
  return buf;
}

/** Upload a firmware ELF image (single-frame <= 64 KiB, CRC32 chunked <= 64 MiB). */
export async function uploadElfImage(
  call: (method: Method, args: Uint8Array, timeoutMs: number) => Promise<Uint8Array>,
  core: Core,
  image: Uint8Array,
  onProgress?: (loadedBytes: number, totalBytes: number) => void
): Promise<boolean> {
  const SINGLE_FRAME_CAP = 65_536;
  const MAX_ELF_BYTES = 64 * 1024 * 1024;
  if (image.length === 0) throw new Error("ELF image is empty");
  if (image.length > MAX_ELF_BYTES) {
    throw new Error(`ELF image exceeds 64 MiB limit (${image.length} bytes)`);
  }

  onProgress?.(0, image.length);
  if (image.length <= SINGLE_FRAME_CAP) {
    const resp = await call(Method.Load, encodeLoad(core, image), 30000);
    const ok = decodeAck(resp).accepted !== 0;
    if (ok) onProgress?.(image.length, image.length);
    return ok;
  }

  const beginResp = await call(Method.LoadBegin, encodeLoadBegin(core, image.length, crc32(image)), 30000);
  if (decodeAck(beginResp).accepted === 0) return false;

  for (let offset = 0; offset < image.length; offset += SINGLE_FRAME_CAP) {
    const end = Math.min(offset + SINGLE_FRAME_CAP, image.length);
    const chunkResp = await call(Method.LoadChunk, encodeLoadChunk(core, offset, image.subarray(offset, end)), 30000);
    if (decodeAck(chunkResp).accepted === 0) return false;
    onProgress?.(end, image.length);
  }

  const endResp = await call(Method.LoadEnd, encodeCoreOnly(core), 30000);
  return decodeAck(endResp).accepted !== 0;
}
