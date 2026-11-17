/**
 * Strictly typed WebSocket transport, handshake, and frame multiplexing.
 */

import {
  DEFAULT_CLIENT_CAPS,
  ErrorCode,
  Hello,
  Kind,
  Method,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION,
} from "../wire/types.js";
import { dispatchTopicEvent } from "./dispatch.js";
import { TypedEventEmitter } from "./emitter.js";
import {
  decodeAck,
  decodeEvent,
  decodeFault,
  decodeHello,
  decodeResponse,
  encodeFrame,
  encodeHello,
  encodeRequest,
  splitFrames,
} from "./envelope.js";

export const DEFAULT_RPC_URL = "ws://127.0.0.1:4567";

export interface RpcMessageEvent {
  data: unknown;
}

export interface RpcCloseEvent {
  code: number;
  reason: string;
}

export interface RpcWebSocket {
  readonly readyState: number;
  binaryType: "blob" | "arraybuffer";
  onopen: ((ev: unknown) => void) | null;
  onmessage: ((ev: RpcMessageEvent) => void) | null;
  onclose: ((ev: RpcCloseEvent) => void) | null;
  onerror: ((ev: unknown) => void) | null;
  send(data: Uint8Array): void;
  close(code?: number, reason?: string): void;
}

export type RpcWebSocketConstructor = new (url: string) => RpcWebSocket;

export interface ClientOptions {
  timeoutMs?: number;
  caps?: number;
  WebSocketClass?: RpcWebSocketConstructor;
}

export class RpcCallError extends Error {
  constructor(
    public readonly code: number,
    public readonly method: number,
    public readonly requestId: number
  ) {
    super(`RPC error code ${code} for call id ${requestId}`);
    this.name = "RpcCallError";
  }
}

interface PendingCall {
  method: number;
  resolve: (payload: Uint8Array) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

function toBytes(raw: unknown): Uint8Array {
  if (raw instanceof ArrayBuffer) return new Uint8Array(raw);
  if (ArrayBuffer.isView(raw)) {
    return new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
  }
  throw new Error("Expected binary WebSocket frame payload");
}

function resolveWebSocketClass(custom?: RpcWebSocketConstructor): RpcWebSocketConstructor {
  if (custom) return custom;
  const globalHolder = globalThis as { WebSocket?: RpcWebSocketConstructor };
  const ctor =
    typeof WebSocket !== "undefined"
      ? (WebSocket as unknown as RpcWebSocketConstructor)
      : globalHolder.WebSocket;
  if (!ctor) {
    throw new Error(
      "WebSocket implementation not found. In older Node.js, pass WebSocketClass in options."
    );
  }
  return ctor;
}

/** Core RPC connection and request/response multiplexer over WebSocket. */
export class WsTransport extends TypedEventEmitter {
  protected ws: RpcWebSocket | null = null;
  protected connectTimer: ReturnType<typeof setTimeout> | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, PendingCall>();
  private rxBuffer: Uint8Array = new Uint8Array(0);
  private handshakePromise: {
    resolve: (hello: Hello) => void;
    reject: (err: Error) => void;
  } | null = null;
  private serverHello: Hello | null = null;

  public readonly defaultTimeoutMs: number;
  public readonly clientCaps: number;
  private readonly wsClass: RpcWebSocketConstructor;

  constructor(options: ClientOptions = {}) {
    super();
    this.defaultTimeoutMs = options.timeoutMs ?? 10000;
    this.clientCaps = options.caps ?? DEFAULT_CLIENT_CAPS;
    this.wsClass = resolveWebSocketClass(options.WebSocketClass);
  }

  public get isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === 1 && this.serverHello !== null;
  }

  public get serverCaps(): number | null {
    return this.serverHello ? this.serverHello.caps : null;
  }

  public async connect(url = DEFAULT_RPC_URL): Promise<Hello> {
    if (this.isConnected && this.serverHello) {
      return this.serverHello;
    }
    return new Promise<Hello>((resolve, reject) => {
      try {
        const socket = new this.wsClass(url);
        socket.binaryType = "arraybuffer";
        this.ws = socket;
      } catch (err) {
        reject(err instanceof Error ? err : new Error(String(err)));
        return;
      }
      this.handshakePromise = { resolve, reject };
      this.startConnectTimeout();
      this.attachSocketHandlers(this.ws);
    });
  }

  private startConnectTimeout(): void {
    if (this.connectTimer) clearTimeout(this.connectTimer);
    this.connectTimer = setTimeout(() => {
      this.connectTimer = null;
      if (this.handshakePromise) {
        this.handshakePromise.reject(
          new Error(`Connection handshake timed out after ${this.defaultTimeoutMs}ms`)
        );
        this.handshakePromise = null;
        this.disconnect();
      }
    }, this.defaultTimeoutMs);
  }

  private attachSocketHandlers(socket: RpcWebSocket): void {
    socket.onopen = () => {
      this.sendRaw(encodeFrame(Kind.Hello, encodeHello(this.clientCaps)));
      this.emit("open", undefined);
    };
    socket.onmessage = (event) => {
      this.onData(toBytes(event.data));
    };
    socket.onclose = (event) => {
      if (this.connectTimer) {
        clearTimeout(this.connectTimer);
        this.connectTimer = null;
      }
      this.serverHello = null;
      this.cleanupPending(new Error(`WebSocket closed (${event.code}): ${event.reason}`));
      if (this.handshakePromise) {
        this.handshakePromise.reject(
          new Error(`WebSocket closed before handshake: ${event.code} ${event.reason}`)
        );
        this.handshakePromise = null;
      }
      this.emit("close", { code: event.code, reason: event.reason });
    };
    socket.onerror = (err) => {
      if (this.connectTimer) {
        clearTimeout(this.connectTimer);
        this.connectTimer = null;
      }
      const error = err instanceof Error ? err : new Error(`WebSocket error: ${String(err)}`);
      this.emit("error", error);
      if (this.handshakePromise) {
        this.handshakePromise.reject(error);
        this.handshakePromise = null;
      }
    };
  }

  public disconnect(): void {
    if (this.connectTimer) {
      clearTimeout(this.connectTimer);
      this.connectTimer = null;
    }
    const socket = this.ws;
    this.ws = null;
    if (socket) {
      try {
        socket.close();
      } catch (err) {
        this.emit("error", err instanceof Error ? err : new Error(String(err)));
      }
    }
    this.serverHello = null;
    this.cleanupPending(new Error("Client disconnected"));
  }

  public async call(
    method: Method | number,
    args?: Uint8Array,
    timeoutMs = this.defaultTimeoutMs
  ): Promise<Uint8Array> {
    if (!this.isConnected) {
      throw new Error("RPC client is not connected");
    }
    const id = this.nextId++;
    const frame = encodeFrame(Kind.Request, encodeRequest(id, method, args));

    return new Promise<Uint8Array>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC call method 0x${method.toString(16)} (id ${id}) timed out`));
      }, timeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      this.sendRaw(frame);
    });
  }

  protected async ack(
    method: Method | number,
    args?: Uint8Array,
    timeoutMs = this.defaultTimeoutMs
  ): Promise<boolean> {
    return decodeAck(await this.call(method, args, timeoutMs)).accepted !== 0;
  }

  private sendRaw(data: Uint8Array): void {
    if (!this.ws || this.ws.readyState !== 1) {
      throw new Error("Cannot send frame: WebSocket is not open");
    }
    this.ws.send(data);
  }

  private onData(chunk: Uint8Array): void {
    if (this.rxBuffer.length === 0) {
      this.rxBuffer = chunk;
    } else {
      const merged = new Uint8Array(this.rxBuffer.length + chunk.length);
      merged.set(this.rxBuffer, 0);
      merged.set(chunk, this.rxBuffer.length);
      this.rxBuffer = merged;
    }
    const { frames, remainder } = splitFrames(this.rxBuffer);
    this.rxBuffer = remainder;
    for (const frame of frames) {
      this.processFrame(frame.kind, frame.payload);
    }
  }

  private processFrame(kind: Kind, payload: Uint8Array): void {
    if (kind === Kind.Hello) {
      this.handleHelloFrame(payload);
    } else if (kind === Kind.Fault) {
      const fault = decodeFault(payload);
      this.emit("error", new Error(`RPC fault code ${fault.code} (version ${fault.version})`));
    } else if (kind === Kind.Response) {
      this.handleResponseFrame(payload);
    } else if (kind === Kind.Event) {
      const event = decodeEvent(payload);
      this.emit("event", event);
      dispatchTopicEvent(this, event.topic, event.payload);
    } else {
      console.warn(`Unrecognized frame kind: ${kind}`);
    }
  }

  private handleHelloFrame(payload: Uint8Array): void {
    if (this.connectTimer) {
      clearTimeout(this.connectTimer);
      this.connectTimer = null;
    }
    const hello = decodeHello(payload);
    if (hello.magic !== PROTOCOL_MAGIC || hello.version !== PROTOCOL_VERSION) {
      const err = new Error(
        `Incompatible RPC peer: magic 0x${hello.magic.toString(16)}, version ${hello.version}`
      );
      if (this.handshakePromise) {
        this.handshakePromise.reject(err);
        this.handshakePromise = null;
      }
      this.disconnect();
      return;
    }
    this.serverHello = hello;
    if (this.handshakePromise) {
      this.handshakePromise.resolve(hello);
      this.handshakePromise = null;
    }
    this.emit("hello", hello);
  }

  private handleResponseFrame(payload: Uint8Array): void {
    const resp = decodeResponse(payload);
    const pending = this.pending.get(resp.id);
    if (!pending) return;
    this.pending.delete(resp.id);
    clearTimeout(pending.timer);
    if (resp.ok) {
      pending.resolve(resp.payload);
    } else {
      pending.reject(
        new RpcCallError(resp.code ?? ErrorCode.Failed, pending.method, resp.id)
      );
    }
  }

  private cleanupPending(err: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(err);
    }
    this.pending.clear();
  }
}
