/**
 * Binary frame headers, RPC envelopes, and shared primitive wire codecs.
 */

import {
  Ack,
  Core,
  ErrorCode,
  Fault,
  HEADER_BYTES,
  Hello,
  Kind,
  MAX_PAYLOAD,
  Method,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION,
  RpcEventEnvelope,
  RpcHeader,
  RpcRequestEnvelope,
  RpcResponseEnvelope,
  Topic,
} from "../wire/types.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Encode the 6-byte frame header. */
export function encodeHeader(length: number, kind: Kind | number): Uint8Array {
  const buf = new Uint8Array(HEADER_BYTES);
  const view = new DataView(buf.buffer);
  view.setUint32(0, length, true);
  view.setUint16(4, kind, true);
  return buf;
}

/** Decode the 6-byte frame header. */
export function decodeHeader(data: Uint8Array): RpcHeader {
  if (data.length < HEADER_BYTES) {
    throw new Error("Truncated frame header: requires 6 bytes");
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return {
    length: view.getUint32(0, true),
    kind: view.getUint16(4, true) as Kind,
  };
}

/** Wrap a payload into a framed binary packet with the 6-byte header. */
export function encodeFrame(kind: Kind | number, payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(HEADER_BYTES + payload.length);
  const view = new DataView(frame.buffer);
  view.setUint32(0, payload.length, true);
  view.setUint16(4, kind, true);
  frame.set(payload, HEADER_BYTES);
  return frame;
}

export interface SplitResult {
  frames: Array<{ kind: Kind; payload: Uint8Array }>;
  remainder: Uint8Array;
}

/** Parse and split contiguous frames from an incoming stream buffer. */
export function splitFrames(buffer: Uint8Array, maxPayload = MAX_PAYLOAD): SplitResult {
  const frames: Array<{ kind: Kind; payload: Uint8Array }> = [];
  let offset = 0;

  while (buffer.length - offset >= HEADER_BYTES) {
    const view = new DataView(buffer.buffer, buffer.byteOffset + offset, HEADER_BYTES);
    const length = view.getUint32(0, true);
    const kind = view.getUint16(4, true) as Kind;

    if (length > maxPayload) {
      throw new Error(`Frame payload oversize: ${length} > max ${maxPayload}`);
    }

    const totalFrameBytes = HEADER_BYTES + length;
    if (buffer.length - offset < totalFrameBytes) {
      break;
    }

    const payload = buffer.subarray(offset + HEADER_BYTES, offset + totalFrameBytes);
    frames.push({ kind, payload });
    offset += totalFrameBytes;
  }

  const remainder = offset < buffer.length ? buffer.subarray(offset) : new Uint8Array(0);
  return { frames, remainder };
}

/** Encode Hello payload (10 bytes: magic u32, version u16, caps u32). */
export function encodeHello(
  caps: number,
  magic = PROTOCOL_MAGIC,
  version = PROTOCOL_VERSION
): Uint8Array {
  const buf = new Uint8Array(10);
  const view = new DataView(buf.buffer);
  view.setUint32(0, magic, true);
  view.setUint16(4, version, true);
  view.setUint32(6, caps, true);
  return buf;
}

/** Decode Hello payload. */
export function decodeHello(payload: Uint8Array): Hello {
  if (payload.length < 10) {
    throw new Error("Truncated Hello frame: requires 10 bytes");
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return {
    magic: view.getUint32(0, true),
    version: view.getUint16(4, true),
    caps: view.getUint32(6, true),
  };
}

/** Encode Fault payload (4 bytes: code u16, version u16). */
export function encodeFault(code: ErrorCode | number, version = PROTOCOL_VERSION): Uint8Array {
  const buf = new Uint8Array(4);
  const view = new DataView(buf.buffer);
  view.setUint16(0, code, true);
  view.setUint16(2, version, true);
  return buf;
}

/** Decode Fault payload. */
export function decodeFault(payload: Uint8Array): Fault {
  if (payload.length < 4) {
    throw new Error("Truncated Fault frame: requires 4 bytes");
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  return {
    code: view.getUint16(0, true),
    version: view.getUint16(2, true),
  };
}

/** Encode Request envelope. */
export function encodeRequest(
  id: number,
  method: Method | number,
  args?: Uint8Array
): Uint8Array {
  const argsLen = args ? args.length : 0;
  const buf = new Uint8Array(10 + argsLen);
  const view = new DataView(buf.buffer);
  view.setUint32(0, id, true);
  view.setUint16(4, method, true);
  view.setUint32(6, argsLen, true);
  if (args && argsLen > 0) {
    buf.set(args, 10);
  }
  return buf;
}

/** Decode Request envelope. */
export function decodeRequest(payload: Uint8Array): RpcRequestEnvelope {
  if (payload.length < 10) {
    throw new Error("Truncated Request envelope: requires at least 10 bytes");
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const id = view.getUint32(0, true);
  const method = view.getUint16(4, true);
  const argsLen = view.getUint32(6, true);
  if (payload.length < 10 + argsLen) {
    throw new Error("Truncated Request envelope args");
  }
  return { id, method, args: payload.subarray(10, 10 + argsLen) };
}

/** Encode Response envelope. */
export function encodeResponse(
  id: number,
  ok: boolean,
  payloadOrCode: Uint8Array | number
): Uint8Array {
  if (ok) {
    const bytes = payloadOrCode instanceof Uint8Array ? payloadOrCode : new Uint8Array(0);
    const buf = new Uint8Array(9 + bytes.length);
    const view = new DataView(buf.buffer);
    view.setUint32(0, id, true);
    view.setUint8(4, 0);
    view.setUint32(5, bytes.length, true);
    buf.set(bytes, 9);
    return buf;
  }
  const code = typeof payloadOrCode === "number" ? payloadOrCode : ErrorCode.Failed;
  const buf = new Uint8Array(7);
  const view = new DataView(buf.buffer);
  view.setUint32(0, id, true);
  view.setUint8(4, 1);
  view.setUint16(5, code, true);
  return buf;
}

/** Decode Response envelope. */
export function decodeResponse(payload: Uint8Array): RpcResponseEnvelope {
  if (payload.length < 5) {
    throw new Error("Truncated Response envelope: requires at least 5 bytes");
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const id = view.getUint32(0, true);
  const tag = view.getUint8(4);

  if (tag === 0) {
    if (payload.length < 9) {
      throw new Error("Truncated Response payload length header");
    }
    const len = view.getUint32(5, true);
    if (payload.length < 9 + len) {
      throw new Error("Truncated Response payload body");
    }
    return { id, ok: true, payload: payload.subarray(9, 9 + len) };
  }
  if (tag === 1) {
    if (payload.length < 7) {
      throw new Error("Truncated Response error code");
    }
    return { id, ok: false, code: view.getUint16(5, true), payload: new Uint8Array(0) };
  }
  throw new Error(`Invalid Response result tag: ${tag}`);
}

/** Encode Event envelope. */
export function encodeEvent(topic: Topic | number, payload: Uint8Array): Uint8Array {
  const buf = new Uint8Array(6 + payload.length);
  const view = new DataView(buf.buffer);
  view.setUint16(0, topic, true);
  view.setUint32(2, payload.length, true);
  buf.set(payload, 6);
  return buf;
}

/** Decode Event envelope. */
export function decodeEvent(payload: Uint8Array): RpcEventEnvelope {
  if (payload.length < 6) {
    throw new Error("Truncated Event envelope: requires at least 6 bytes");
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const topic = view.getUint16(0, true);
  const len = view.getUint32(2, true);
  if (payload.length < 6 + len) {
    throw new Error("Truncated Event payload body");
  }
  return { topic, payload: payload.subarray(6, 6 + len) };
}

/** Read a u32-LE length-prefixed byte slice from `data` advancing `offset.val`. */
export function readSlice(data: Uint8Array, offset: { val: number }): Uint8Array {
  if (offset.val + 4 > data.length) throw new Error("Truncated slice length");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const len = view.getUint32(offset.val, true);
  offset.val += 4;
  if (offset.val + len > data.length) throw new Error("Truncated slice data");
  const slice = data.subarray(offset.val, offset.val + len);
  offset.val += len;
  return slice;
}

/** Encode a byte slice as u32-LE length prefix + bytes. */
export function encodeSlice(bytes: Uint8Array): Uint8Array {
  const buf = new Uint8Array(4 + bytes.length);
  new DataView(buf.buffer).setUint32(0, bytes.length, true);
  buf.set(bytes, 4);
  return buf;
}

/** Encode a UTF-8 string with u32-LE length prefix, validating optional max byte length. */
export function encodeText(text: string, maxBytes?: number, label = "string"): Uint8Array {
  const bytes = encoder.encode(text);
  if (maxBytes !== undefined && bytes.length > maxBytes) {
    throw new Error(`${label} exceeds max ${maxBytes} UTF-8 bytes`);
  }
  return encodeSlice(bytes);
}

/** Decode a single UTF-8 slice reply (PartList, PeriphText, MapText, FoldedText). */
export function decodeTextSlice(data: Uint8Array): string {
  return decoder.decode(readSlice(data, { val: 0 }));
}

export function decodeUtf8(bytes: Uint8Array): string {
  return decoder.decode(bytes);
}

export function encodeUtf8(text: string): Uint8Array {
  return encoder.encode(text);
}

/** Encode CoreOnly argument (1 byte). */
export function encodeCoreOnly(core: Core): Uint8Array {
  return new Uint8Array([core]);
}

/** Decode CoreOnly argument. */
export function decodeCoreOnly(data: Uint8Array): Core {
  if (data.length < 1) throw new Error("Truncated CoreOnly");
  return data[0] as Core;
}

/** Decode Ack result (1 byte). */
export function decodeAck(data: Uint8Array): Ack {
  if (data.length < 1) throw new Error("Truncated Ack");
  return { accepted: data[0] ?? 0 };
}

/** Decode U32 result (4 bytes LE). */
export function decodeU32(data: Uint8Array): number {
  if (data.length < 4) throw new Error("Truncated U32");
  return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(0, true);
}

/** Encode U32 (4 bytes LE). */
export function encodeU32(value: number): Uint8Array {
  const buf = new Uint8Array(4);
  new DataView(buf.buffer).setUint32(0, value >>> 0, true);
  return buf;
}

/** Decode U64 result (8 bytes LE). */
export function decodeU64(data: Uint8Array): bigint {
  if (data.length < 8) throw new Error("Truncated U64");
  return new DataView(data.buffer, data.byteOffset, data.byteLength).getBigUint64(0, true);
}

/** Encode U64 (8 bytes LE). */
export function encodeU64(value: bigint | number): Uint8Array {
  const buf = new Uint8Array(8);
  new DataView(buf.buffer).setBigUint64(0, BigInt(value), true);
  return buf;
}
