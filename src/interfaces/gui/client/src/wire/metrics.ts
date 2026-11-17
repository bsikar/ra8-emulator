/**
 * Host/guest metrics, stack watermarks, folded profiler, and RTOS trace codecs
 * matching `src/interfaces/rpc/session/{metrics_wire,rpc,trace_wire}.zig`.
 */

import { decodeUtf8, readSlice } from "../transport/envelope.js";
import { Core, EventKind, METRICS_REPORT_BYTES } from "./types.js";

export interface MetricsReport {
  hostCpuPercent: number;
  hostRssMb: number;
  hostThreads: number;
  cpu0LoadPercent: number;
  cpu0Pinned: number;
  cpu0RamUsedBytes: number;
  cpu0RamTotalBytes: number;
  cpu1LoadPercent: number;
  cpu1Pinned: number;
  cpu1RamUsedBytes: number;
  cpu1RamTotalBytes: number;
}

export interface StackReport {
  core: Core;
  msp: number;
  psp: number;
  lowMsp: number;
  lowPsp: number;
  hasStack: boolean;
  base: number;
  size: number;
  overflow: number;
}

export interface TraceEvent {
  core: Core;
  kind: EventKind;
  virtualNs: bigint;
  thread: number;
  exception: number;
  name: string;
}

export function decodeMetricsReport(data: Uint8Array): MetricsReport {
  if (data.length < METRICS_REPORT_BYTES) {
    throw new Error(`Truncated MetricsReport: requires ${METRICS_REPORT_BYTES} bytes`);
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    hostCpuPercent: view.getUint32(0, true),
    hostRssMb: view.getUint32(4, true),
    hostThreads: view.getUint32(8, true),
    cpu0LoadPercent: view.getUint8(12),
    cpu0Pinned: view.getUint8(13),
    cpu0RamUsedBytes: view.getUint32(14, true),
    cpu0RamTotalBytes: view.getUint32(18, true),
    cpu1LoadPercent: view.getUint8(22),
    cpu1Pinned: view.getUint8(23),
    cpu1RamUsedBytes: view.getUint32(24, true),
    cpu1RamTotalBytes: view.getUint32(28, true),
  };
}

export function encodeMetricsReport(report: MetricsReport): Uint8Array {
  const buf = new Uint8Array(METRICS_REPORT_BYTES);
  const view = new DataView(buf.buffer);
  view.setUint32(0, report.hostCpuPercent, true);
  view.setUint32(4, report.hostRssMb, true);
  view.setUint32(8, report.hostThreads, true);
  view.setUint8(12, report.cpu0LoadPercent);
  view.setUint8(13, report.cpu0Pinned);
  view.setUint32(14, report.cpu0RamUsedBytes, true);
  view.setUint32(18, report.cpu0RamTotalBytes, true);
  view.setUint8(22, report.cpu1LoadPercent);
  view.setUint8(23, report.cpu1Pinned);
  view.setUint32(24, report.cpu1RamUsedBytes, true);
  view.setUint32(28, report.cpu1RamTotalBytes, true);
  return buf;
}

export function decodeStackReport(data: Uint8Array): StackReport {
  if (data.length < 30) throw new Error("Truncated StackReport: requires 30 bytes");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    msp: view.getUint32(1, true),
    psp: view.getUint32(5, true),
    lowMsp: view.getUint32(9, true),
    lowPsp: view.getUint32(13, true),
    hasStack: view.getUint8(17) !== 0,
    base: view.getUint32(18, true),
    size: view.getUint32(22, true),
    overflow: view.getUint32(26, true),
  };
}

export function encodeFoldedAsk(
  core: Core,
  thread = 0xffffffff,
  fromNs = 0n,
  toNs = 0xffffffffffffffffn
): Uint8Array {
  const buf = new Uint8Array(21);
  const view = new DataView(buf.buffer);
  view.setUint8(0, core);
  view.setUint32(1, thread >>> 0, true);
  view.setBigUint64(5, fromNs, true);
  view.setBigUint64(13, toNs, true);
  return buf;
}

export function decodeTraceEvent(data: Uint8Array): TraceEvent {
  if (data.length < 20) throw new Error("Truncated TraceEvent");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    core: view.getUint8(0) as Core,
    kind: view.getUint8(1) as EventKind,
    virtualNs: view.getBigUint64(2, true),
    thread: view.getUint32(10, true),
    exception: view.getUint16(14, true),
    name: decodeUtf8(readSlice(data, { val: 16 })),
  };
}
