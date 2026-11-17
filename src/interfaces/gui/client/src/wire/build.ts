/**
 * Backend build RPC codecs (`0x0160..0x0162`, topics `0x0181..0x0182`)
 * matching `src/interfaces/rpc/build_wire.zig` and `src/host/build/queue.zig`.
 */

import {
  decodeU64,
  decodeUtf8,
  encodeText,
  encodeU64,
  readSlice,
} from "../transport/envelope.js";

export enum BuildEventKind {
  Stdout = 0,
  Stderr = 1,
  Diagnostic = 2,
}

export interface BuildStartArgs {
  step: string;
  options?: string;
  artifact?: string;
  timeoutMs?: number;
}

export interface BuildStatus {
  id: bigint;
  done: boolean;
  result: string;
}

export interface BuildEvent {
  id: bigint;
  sequence: bigint;
  kind: BuildEventKind;
  bytes: Uint8Array;
}

export function encodeBuildStart(args: BuildStartArgs): Uint8Array {
  const stepSlice = encodeText(args.step, 64, "Build step");
  const optionsSlice = encodeText(args.options ?? "[]", 4096, "Build options");
  const artifactSlice = encodeText(args.artifact ?? "", 512, "Build artifact");
  const total = stepSlice.length + optionsSlice.length + artifactSlice.length;
  const buf = new Uint8Array(total + 4);
  buf.set(stepSlice, 0);
  buf.set(optionsSlice, stepSlice.length);
  buf.set(artifactSlice, stepSlice.length + optionsSlice.length);
  new DataView(buf.buffer).setUint32(total, (args.timeoutMs ?? 30_000) >>> 0, true);
  return buf;
}

export function encodeBuildId(id: bigint | number): Uint8Array {
  return encodeU64(id);
}

export function decodeBuildId(data: Uint8Array): bigint {
  return decodeU64(data);
}

export function decodeBuildStatus(data: Uint8Array): BuildStatus {
  if (data.length < 13) throw new Error("Truncated BuildStatus");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    id: view.getBigUint64(0, true),
    done: view.getUint8(8) !== 0,
    result: decodeUtf8(readSlice(data, { val: 9 })),
  };
}

export function decodeBuildEvent(data: Uint8Array): BuildEvent {
  if (data.length < 21) throw new Error("Truncated BuildEvent");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    id: view.getBigUint64(0, true),
    sequence: view.getBigUint64(8, true),
    kind: view.getUint8(16) as BuildEventKind,
    bytes: readSlice(data, { val: 17 }),
  };
}
