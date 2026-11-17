/**
 * Sandboxed Blob Web Worker bridge communicating strictly via JSON-RPC `postMessage`
 * with timeout enforcement, clean worker termination, and headless fallback handling.
 */

import type { ExtensionManifest } from './extension-manifest';
import { buildWorkerBootstrapScript } from './worker-bootstrap';

export { buildWorkerBootstrapScript };

export interface ExtensionExecutionSnapshot {
  connected: boolean;
  executionStatus: string;
  activeCore: number;
  cpu1Attached: boolean;
  virtualTimeNs: string;
}

export interface ExtensionHostAdapter {
  onRegisterCommand?: (command: string) => void;
  onExecuteCommand?: (command: string, args: unknown[]) => Promise<unknown> | unknown;
  showInformationMessage?: (message: string) => Promise<void> | void;
  showWarningMessage?: (message: string) => Promise<void> | void;
  getExecutionState?: () => Promise<ExtensionExecutionSnapshot> | ExtensionExecutionSnapshot;
  readRegisters?: (core: number) => Promise<Record<string, number>> | Record<string, number>;
  readMemory?: (core: number, address: number, length: number) => Promise<number[]> | number[];
  postPanelState?: (panelId: string, state: unknown) => Promise<void> | void;
  onRuntimeError?: (message: string) => void;
}

export interface WorkerMessageEventLike {
  data: unknown;
}

export interface WorkerErrorEventLike {
  message?: string;
}

export interface WorkerLike {
  onmessage: ((event: WorkerMessageEventLike) => void) | null;
  onerror: ((event: WorkerErrorEventLike) => void) | null;
  postMessage(message: unknown): void;
  terminate(): void;
}

export type WorkerFactory = (scriptUrl: string, manifest: ExtensionManifest) => WorkerLike;

export interface ExtensionWorkerBridgeOptions {
  manifest: ExtensionManifest;
  adapter: ExtensionHostAdapter;
  workerFactory?: WorkerFactory;
  timeoutMs?: number;
}

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: unknown;
  error?: { code: number; message: string };
}

interface PendingRpc {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

const DEFAULT_RPC_TIMEOUT_MS = 3000;
const MAX_READ_MEMORY_LEN = 4096;

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

function asString(val: unknown, fallback = ''): string {
  return typeof val === 'string' ? val : fallback;
}

function asNumber(val: unknown, fallback = 0): number {
  return typeof val === 'number' && Number.isFinite(val) ? val : fallback;
}

/** Manages one isolated Web Worker lifecycle and bidirectional JSON-RPC channel. */
export class ExtensionWorkerBridge {
  private readonly manifest: ExtensionManifest;
  private readonly adapter: ExtensionHostAdapter;
  private readonly workerFactory?: WorkerFactory;
  private readonly timeoutMs: number;

  private worker: WorkerLike | null = null;
  private blobUrl: string | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRpc>();
  private terminated = false;

  constructor(options: ExtensionWorkerBridgeOptions) {
    this.manifest = options.manifest;
    this.adapter = options.adapter;
    this.workerFactory = options.workerFactory;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_RPC_TIMEOUT_MS;
  }

  /** Spawns the Blob Web Worker (or factory worker) and activates the extension. */
  public async start(): Promise<string[]> {
    this.terminated = false;
    const worker = this.createWorker();
    this.worker = worker;
    worker.onmessage = (event) => this.handleMessage(event.data);
    worker.onerror = (event) => {
      const msg = event.message || `Worker runtime error in ${this.manifest.id}`;
      this.adapter.onRuntimeError?.(msg);
      this.rejectAllPending(new Error(msg));
    };

    try {
      const reply = (await this.sendRequest('ra8.activate', {})) as { registeredCommands?: unknown };
      this.revokeBlobUrl();
      return Array.isArray(reply?.registeredCommands)
        ? reply.registeredCommands.filter((c): c is string => typeof c === 'string')
        : [];
    } catch (err) {
      this.terminate();
      throw err;
    }
  }

  /** Invokes a command handler registered inside this extension's Web Worker. */
  public invokeCommand(command: string, args: unknown[] = []): Promise<unknown> {
    return this.sendRequest('ra8.command.invoke', { command, args });
  }

  /** Terminates the Web Worker immediately and rejects all pending RPC calls. */
  public terminate(): void {
    this.terminated = true;
    this.rejectAllPending(new Error(`Extension host terminated (${this.manifest.id})`));
    if (this.worker) {
      this.worker.onmessage = null;
      this.worker.onerror = null;
      this.worker.terminate();
      this.worker = null;
    }
    this.revokeBlobUrl();
  }

  private createWorker(): WorkerLike {
    if (this.workerFactory) {
      return this.workerFactory(`blob:mock/${this.manifest.id}`, this.manifest);
    }
    const canSpawnBlobWorker =
      typeof Worker !== 'undefined' &&
      typeof Blob !== 'undefined' &&
      typeof URL !== 'undefined' &&
      typeof URL.createObjectURL === 'function';
    if (!canSpawnBlobWorker) {
      throw new Error('Web Worker runtime unavailable in this environment');
    }
    const script = buildWorkerBootstrapScript(this.manifest);
    const blob = new Blob([script], { type: 'application/javascript' });
    this.blobUrl = URL.createObjectURL(blob);
    return new Worker(this.blobUrl, { name: this.manifest.id }) as unknown as WorkerLike;
  }

  private revokeBlobUrl(): void {
    if (this.blobUrl && typeof URL !== 'undefined' && typeof URL.revokeObjectURL === 'function') {
      URL.revokeObjectURL(this.blobUrl);
    }
    this.blobUrl = null;
  }

  private sendRequest(method: string, params: Record<string, unknown>): Promise<unknown> {
    if (this.terminated || !this.worker) {
      return Promise.reject(new Error(`Extension worker not running (${this.manifest.id})`));
    }
    const id = this.nextId++;
    const payload: JsonRpcRequest = { jsonrpc: '2.0', id, method, params };
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Extension RPC "${method}" timed out after ${this.timeoutMs}ms`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.worker?.postMessage(payload);
    });
  }

  private handleMessage(raw: unknown): void {
    if (!isRecord(raw) || raw['jsonrpc'] !== '2.0') return;
    const id = raw['id'];
    if (typeof id !== 'number') return;

    const method = raw['method'];
    if (typeof method === 'string') {
      const params = isRecord(raw['params']) ? raw['params'] : {};
      void this.dispatchWorkerCall(id, method, params);
      return;
    }

    const wait = this.pending.get(id);
    if (!wait) return;
    this.pending.delete(id);
    clearTimeout(wait.timer);

    const err = raw['error'];
    if (isRecord(err)) {
      wait.reject(new Error(asString(err['message'], 'Extension worker error')));
    } else {
      wait.resolve(raw['result']);
    }
  }

  private async dispatchWorkerCall(id: number, method: string, params: Record<string, unknown>): Promise<void> {
    try {
      const result = await this.routeAdapterMethod(method, params);
      this.postResponse({ jsonrpc: '2.0', id, result });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.postResponse({ jsonrpc: '2.0', id, error: { code: -32000, message } });
    }
  }

  private async routeAdapterMethod(method: string, params: Record<string, unknown>): Promise<unknown> {
    switch (method) {
      case 'ra8.commands.registerCommand': {
        const command = asString(params['command']);
        if (!command) throw new Error('Command id required');
        this.adapter.onRegisterCommand?.(command);
        return { ok: true };
      }
      case 'ra8.commands.executeCommand': {
        const command = asString(params['command']);
        const args = Array.isArray(params['args']) ? params['args'] : [];
        return this.adapter.onExecuteCommand ? await this.adapter.onExecuteCommand(command, args) : null;
      }
      case 'ra8.window.showInformationMessage':
        await this.adapter.showInformationMessage?.(asString(params['message']));
        return null;
      case 'ra8.window.showWarningMessage':
        await this.adapter.showWarningMessage?.(asString(params['message']));
        return null;
      case 'ra8.debug.getExecutionState':
        return this.adapter.getExecutionState?.() ?? {
          connected: false,
          executionStatus: 'stopped',
          activeCore: 0,
          cpu1Attached: false,
          virtualTimeNs: '0',
        };
      case 'ra8.debug.readRegisters':
        return this.adapter.readRegisters?.(asNumber(params['core'], 0)) ?? {};
      case 'ra8.debug.readMemory': {
        const core = asNumber(params['core'], 0);
        const address = asNumber(params['address'], 0) >>> 0;
        const length = Math.max(1, Math.min(MAX_READ_MEMORY_LEN, Math.trunc(asNumber(params['length'], 64))));
        return this.adapter.readMemory?.(core, address, length) ?? [];
      }
      case 'ra8.views.postPanelState': {
        const panelId = asString(params['panelId']);
        if (!panelId) throw new Error('Panel id required');
        await this.adapter.postPanelState?.(panelId, params['state']);
        return null;
      }
      default:
        throw new Error(`Unsupported host RPC method: ${method}`);
    }
  }

  private postResponse(reply: JsonRpcResponse): void {
    if (!this.terminated && this.worker) {
      this.worker.postMessage(reply);
    }
  }

  private rejectAllPending(err: Error): void {
    for (const [id, wait] of this.pending.entries()) {
      clearTimeout(wait.timer);
      wait.reject(err);
      this.pending.delete(id);
    }
  }
}
