/**
 * Physical / remote target lease RPC codecs (`0x0190..0x0193`)
 * matching `src/interfaces/rpc/targets_wire.zig` and `src/host/targets.zig`.
 */

import { decodeTextSlice, encodeText } from "../transport/envelope.js";

export enum TargetAction {
  Registers = 0,
  Halt = 1,
  Step = 2,
  Resume = 3,
  Flash = 4,
  Reset = 5,
}

export interface TargetSelection {
  hostId: string;
  probeId: string;
  boardId: string;
  generation: bigint;
  disambiguation: string;
}

export interface TargetPerformArgs extends TargetSelection {
  action: TargetAction;
}

export interface TargetCapabilities {
  build: boolean;
  flash: boolean;
  hardware_debug: boolean;
  emulation: boolean;
  npu: boolean;
}

export interface TargetDescriptor {
  host_id: string;
  probe_id: string;
  board_id: string;
  probe_serial: string;
  board_serial: string;
  vendor: string;
  model: string;
  cores: string;
  transport: string;
  connection: "configured" | "connected" | "disconnected";
  disambiguation: string;
  identity_verified: boolean;
  managed: boolean;
  operations: string[];
  capabilities: TargetCapabilities;
}

export interface TargetEntry {
  target: TargetDescriptor;
  generation: number;
  reserved: boolean;
}

export function encodeTargetSelection(selection: TargetSelection): Uint8Array {
  const host = encodeText(selection.hostId, 128, "Target hostId");
  const probe = encodeText(selection.probeId, 128, "Target probeId");
  const board = encodeText(selection.boardId, 128, "Target boardId");
  const disamb = encodeText(selection.disambiguation, 128, "Target disambiguation");
  const buf = new Uint8Array(host.length + probe.length + board.length + 8 + disamb.length);
  let at = 0;
  buf.set(host, at);
  at += host.length;
  buf.set(probe, at);
  at += probe.length;
  buf.set(board, at);
  at += board.length;
  new DataView(buf.buffer).setBigUint64(at, selection.generation, true);
  at += 8;
  buf.set(disamb, at);
  return buf;
}

export function encodeTargetPerform(args: TargetPerformArgs): Uint8Array {
  const base = encodeTargetSelection(args);
  const buf = new Uint8Array(base.length + 1);
  buf.set(base, 0);
  buf[base.length] = args.action;
  return buf;
}

export function decodeTargetText(data: Uint8Array): string {
  return decodeTextSlice(data);
}

export function decodeTargetsList(data: Uint8Array): { json: string; targets: TargetEntry[] } {
  const json = decodeTextSlice(data);
  const targets = json.length > 0 ? (JSON.parse(json) as TargetEntry[]) : [];
  return { json, targets };
}
