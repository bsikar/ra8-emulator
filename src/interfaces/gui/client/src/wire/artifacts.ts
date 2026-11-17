/**
 * Artifact streaming transfer RPC codecs (`0x0180..0x0185`)
 * matching `src/interfaces/rpc/artifacts/wire.zig`.
 */

import {
  decodeAck,
  decodeU64,
  encodeSlice,
  encodeU64,
  readSlice,
} from "../transport/envelope.js";
import { Method } from "./types.js";

export const ARTIFACTS_MAX_CHUNK = 65_536;
export const ARTIFACTS_MAX_BUNDLE = 4 * 1024 * 1024 * 1024;

export interface ArtifactDescriptor {
  id: bigint;
  total: bigint;
  sha256: Uint8Array;
}

export interface ArtifactChunk {
  id: bigint;
  offset: bigint;
  bytes: Uint8Array;
}

export interface ArtifactCommit {
  accepted: boolean;
  reconnect: boolean;
}

export interface ArtifactExportResult {
  bytes: Uint8Array;
  sha256: Uint8Array;
  total: bigint;
}

export function encodeArtifactExport(recording = false): Uint8Array {
  return new Uint8Array([recording ? 1 : 0]);
}

export function decodeArtifactDescriptor(data: Uint8Array): ArtifactDescriptor {
  if (data.length < 20) throw new Error("Truncated ArtifactDescriptor");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const sha256 = readSlice(data, { val: 16 });
  return {
    id: view.getBigUint64(0, true),
    total: view.getBigUint64(8, true),
    sha256,
  };
}

export function encodeArtifactRead(id: bigint | number, offset: bigint | number, length: number): Uint8Array {
  const buf = new Uint8Array(20);
  const view = new DataView(buf.buffer);
  view.setBigUint64(0, BigInt(id), true);
  view.setBigUint64(8, BigInt(offset), true);
  view.setUint32(16, length >>> 0, true);
  return buf;
}

export function encodeArtifactBegin(total: bigint | number, sha256: Uint8Array): Uint8Array {
  if (sha256.length !== 32) {
    throw new Error(`Artifact SHA-256 must be 32 bytes, got ${sha256.length}`);
  }
  const shaSlice = encodeSlice(sha256);
  const buf = new Uint8Array(8 + shaSlice.length);
  new DataView(buf.buffer).setBigUint64(0, BigInt(total), true);
  buf.set(shaSlice, 8);
  return buf;
}

export function encodeArtifactChunk(
  id: bigint | number,
  offset: bigint | number,
  bytes: Uint8Array
): Uint8Array {
  if (bytes.length > ARTIFACTS_MAX_CHUNK) {
    throw new Error(`Artifact chunk exceeds ${ARTIFACTS_MAX_CHUNK} bytes`);
  }
  const dataSlice = encodeSlice(bytes);
  const buf = new Uint8Array(16 + dataSlice.length);
  const view = new DataView(buf.buffer);
  view.setBigUint64(0, BigInt(id), true);
  view.setBigUint64(8, BigInt(offset), true);
  buf.set(dataSlice, 16);
  return buf;
}

export function decodeArtifactChunk(data: Uint8Array): ArtifactChunk {
  if (data.length < 20) throw new Error("Truncated ArtifactChunk");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    id: view.getBigUint64(0, true),
    offset: view.getBigUint64(8, true),
    bytes: readSlice(data, { val: 16 }),
  };
}

export function encodeArtifactId(id: bigint | number): Uint8Array {
  return encodeU64(id);
}

export function decodeArtifactId(data: Uint8Array): bigint {
  return decodeU64(data);
}

export function decodeArtifactCommit(data: Uint8Array): ArtifactCommit {
  if (data.length < 2) throw new Error("Truncated ArtifactCommit");
  return {
    accepted: (data[0] ?? 0) !== 0,
    reconnect: (data[1] ?? 0) !== 0,
  };
}

/** Compute SHA-256 digest using standard WebCrypto (browser & Node >= 20). */
export async function sha256Bytes(bytes: Uint8Array): Promise<Uint8Array> {
  if (typeof globalThis.crypto?.subtle?.digest !== "function") {
    throw new Error("WebCrypto crypto.subtle.digest is unavailable for artifact SHA-256");
  }
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", copy);
  return new Uint8Array(digest);
}

function digestsEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/** Stream an exported session or recording bundle over `0x0180..0x0181` (aborting on error). */
export async function streamArtifactExport(
  call: (method: Method, args: Uint8Array, timeoutMs?: number) => Promise<Uint8Array>,
  recording = false,
  onProgress?: (readBytes: number, totalBytes: number) => void,
  chunkSize = ARTIFACTS_MAX_CHUNK
): Promise<ArtifactExportResult> {
  const safeChunk = Math.max(1, Math.min(ARTIFACTS_MAX_CHUNK, chunkSize));
  const desc = decodeArtifactDescriptor(
    await call(Method.ArtifactsExportBegin, encodeArtifactExport(recording), 30_000)
  );
  const totalNum = Number(desc.total);
  const out = new Uint8Array(totalNum);
  let offset = 0;
  onProgress?.(0, totalNum);

  try {
    while (offset < totalNum) {
      const length = Math.min(safeChunk, totalNum - offset);
      const chunk = decodeArtifactChunk(
        await call(Method.ArtifactsExportRead, encodeArtifactRead(desc.id, offset, length), 30_000)
      );
      if (Number(chunk.offset) !== offset || chunk.bytes.length === 0) {
        throw new Error(`Unexpected export chunk offset ${chunk.offset} (expected ${offset})`);
      }
      out.set(chunk.bytes, offset);
      offset += chunk.bytes.length;
      onProgress?.(offset, totalNum);
    }
    const actualSha = await sha256Bytes(out);
    if (!digestsEqual(actualSha, desc.sha256)) {
      throw new Error("Exported artifact SHA-256 checksum mismatch");
    }
    return { bytes: out, sha256: desc.sha256, total: desc.total };
  } catch (err) {
    try {
      await call(Method.ArtifactsAbort, encodeArtifactId(desc.id), 5_000);
    } catch (abortErr) {
      console.warn("Artifact export abort failed during cleanup:", abortErr);
    }
    throw err;
  }
}

/** Stream a staged bundle into the server over `0x0182..0x0184` (aborting on error). */
export async function streamArtifactImport(
  call: (method: Method, args: Uint8Array, timeoutMs?: number) => Promise<Uint8Array>,
  bytes: Uint8Array,
  onProgress?: (sentBytes: number, totalBytes: number) => void,
  chunkSize = ARTIFACTS_MAX_CHUNK
): Promise<ArtifactCommit> {
  if (bytes.length === 0 || bytes.length > ARTIFACTS_MAX_BUNDLE) {
    throw new Error(`Artifact bundle length ${bytes.length} out of valid range`);
  }
  const safeChunk = Math.max(1, Math.min(ARTIFACTS_MAX_CHUNK, chunkSize));
  const sha256 = await sha256Bytes(bytes);
  const transferId = decodeArtifactId(
    await call(Method.ArtifactsImportBegin, encodeArtifactBegin(bytes.length, sha256), 30_000)
  );
  onProgress?.(0, bytes.length);

  try {
    for (let offset = 0; offset < bytes.length; offset += safeChunk) {
      const end = Math.min(offset + safeChunk, bytes.length);
      const ack = decodeAck(
        await call(
          Method.ArtifactsImportWrite,
          encodeArtifactChunk(transferId, offset, bytes.subarray(offset, end)),
          30_000
        )
      );
      if (ack.accepted === 0) throw new Error(`Artifact chunk rejected at offset ${offset}`);
      onProgress?.(end, bytes.length);
    }
    return decodeArtifactCommit(
      await call(Method.ArtifactsImportEnd, encodeArtifactId(transferId), 30_000)
    );
  } catch (err) {
    try {
      await call(Method.ArtifactsAbort, encodeArtifactId(transferId), 5_000);
    } catch (abortErr) {
      console.warn("Artifact import abort failed during cleanup:", abortErr);
    }
    throw err;
  }
}
