import { Injectable, OnDestroy, computed, signal } from '@angular/core';
import { Subject } from 'rxjs';
import {
  CAP_ARTIFACTS,
  CAP_BUILD,
  CAP_PROJECT,
  CAP_RECOVERY,
  CAP_TARGETS,
  CAP_TRANSPORT,
  CAP_WORKSPACE,
  Core,
  DEFAULT_RPC_URL,
  DirtyRect,
  ErrorCode,
  Hello,
  RA8RpcClient,
  RpcCallError,
  SessionEvent,
  Stopped,
  Topic,
  TraceEvent,
  TransportEvent,
  UartEvent,
} from 'ra8-rpc-client';

const EXPECTED_REFUSAL_CODES = new Set<number>([
  ErrorCode.UnknownMethod,
  ErrorCode.AppRefused,
  ErrorCode.AppNoCore,
  ErrorCode.AppHistory,
]);

export function isExpectedRefusal(err: unknown): boolean {
  if (err instanceof RpcCallError) {
    return EXPECTED_REFUSAL_CODES.has(err.code);
  }
  const msg = err instanceof Error ? err.message : String(err);
  if (/\bcode (1|256|257|259)\b/.test(msg)) return true;
  const lower = msg.toLowerCase();
  return (
    lower.includes('unknownmethod') ||
    lower.includes('apprefused') ||
    lower.includes('appnocore') ||
    lower.includes('apphistory')
  );
}

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';

export interface ToastItem {
  id: number;
  message: string;
  tone: 'neutral' | 'fault';
}

export function resolveWsUrlFromSearch(search: string): string | null {
  const raw = new URLSearchParams(search).get('ws')?.trim();
  if (!raw) return null;
  if (!/^wss?:\/\/\S+$/i.test(raw)) return null;
  return raw;
}

@Injectable({ providedIn: 'root' })
export class RpcConnectionStore implements OnDestroy {
  private client: RA8RpcClient | null = null;
  private reconnectTimer: ReturnType<typeof setInterval> | null = null;
  private manualDisconnect = true;
  private sessionEverConnected = false;
  private nextToastId = 1;

  public readonly connectionState = signal<ConnectionState>('disconnected');
  public readonly serverUrl = signal<string>(DEFAULT_RPC_URL);
  public readonly errorMessage = signal<string | null>(null);
  public readonly serverCaps = signal<number>(0);
  public readonly toasts = signal<ToastItem[]>([]);

  public readonly connected$ = new Subject<Hello>();
  public readonly disconnected$ = new Subject<void>();
  public readonly stop$ = new Subject<Stopped>();
  public readonly uart$ = new Subject<UartEvent>();
  public readonly lcdDirty$ = new Subject<DirtyRect>();
  public readonly trace$ = new Subject<TraceEvent>();
  public readonly session$ = new Subject<SessionEvent>();
  public readonly transport$ = new Subject<TransportEvent>();

  public readonly isConnected = computed(() => this.connectionState() === 'connected');
  public readonly capabilitiesSummary = computed<string>(() => {
    const flags: string[] = [];
    if (this.hasCapability(CAP_TRANSPORT)) flags.push('TRANSPORT');
    if (this.hasCapability(CAP_WORKSPACE)) flags.push('WORKSPACE');
    if (this.hasCapability(CAP_BUILD)) flags.push('BUILD');
    if (this.hasCapability(CAP_PROJECT)) flags.push('PROJECT');
    if (this.hasCapability(CAP_RECOVERY)) flags.push('RECOVERY');
    if (this.hasCapability(CAP_ARTIFACTS)) flags.push('ARTIFACTS');
    if (this.hasCapability(CAP_TARGETS)) flags.push('TARGETS');
    return flags.length > 0 ? flags.join(' · ') : 'SESSION';
  });

  public get activeClient(): RA8RpcClient | null {
    return this.connectionState() === 'connected' ? this.client : null;
  }

  public hasCapability(flag: number): boolean {
    return (this.serverCaps() & flag) !== 0;
  }

  public pushToast(message: string, tone: 'neutral' | 'fault' = 'neutral', ttlMs = 3200): void {
    const id = this.nextToastId++;
    this.toasts.update((items) => [...items.slice(-3), { id, message, tone }]);
    setTimeout(() => this.dismissToast(id), ttlMs);
  }

  public dismissToast(id: number): void {
    this.toasts.update((items) => items.filter((item) => item.id !== id));
  }

  public noteOptionalError(err: unknown, context?: string): void {
    if (isExpectedRefusal(err)) return;
    const detail = err instanceof Error ? err.message : String(err);
    this.errorMessage.set(context ? `${context}: ${detail}` : detail);
  }

  public reportError(context: string, err: unknown): void {
    const detail = err instanceof Error ? err.message : String(err);
    const msg = `${context}: ${detail}`;
    this.errorMessage.set(msg);
    this.pushToast(msg, 'fault', 4500);
  }

  public async connect(url = this.serverUrl(), silent = false): Promise<boolean> {
    this.cleanupClient();
    this.manualDisconnect = false;
    this.serverUrl.set(url.trim());
    if (!silent) {
      this.connectionState.set('connecting');
      this.errorMessage.set(null);
    }

    const client = new RA8RpcClient({ timeoutMs: silent ? 2500 : 5000 });
    this.client = client;
    this.wireClientEvents(client, silent);

    try {
      const hello = await client.connect(this.serverUrl());
      this.serverCaps.set(hello.caps);
      this.connectionState.set('connected');
      this.errorMessage.set(null);
      this.sessionEverConnected = true;
      await this.subscribeCoreTopics(client, Core.Cpu0);
      this.ensureReconnectLoop();
      this.connected$.next(hello);
      return true;
    } catch (err) {
      this.cleanupClient();
      if (!silent) {
        this.connectionState.set('error');
        this.errorMessage.set(`Backend unreachable at ${this.serverUrl()}: ${err instanceof Error ? err.message : String(err)}`);
      }
      return false;
    }
  }

  public async subscribeCoreTopics(client: RA8RpcClient, core: Core): Promise<void> {
    await client.subscribe(core, Topic.Stop);
    await client.subscribe(core, Topic.Uart);
    await client.subscribe(core, Topic.Session);
    if (core === Core.Cpu0) {
      await this.trySubscribe(client, core, Topic.LcdDirty, 60);
      await this.trySubscribe(client, core, Topic.Transport);
    }
    await this.trySubscribe(client, core, Topic.Trace);
  }

  public disconnect(manual = true): void {
    this.manualDisconnect = manual;
    if (manual) {
      this.stopReconnectLoop();
      this.sessionEverConnected = false;
    }
    this.cleanupClient();
    this.connectionState.set('disconnected');
    this.serverCaps.set(0);
    this.disconnected$.next();
  }

  public ngOnDestroy(): void {
    this.stopReconnectLoop();
    this.disconnect(true);
  }

  private async trySubscribe(client: RA8RpcClient, core: Core, topic: Topic, rate = 0): Promise<void> {
    try {
      await client.subscribe(core, topic, rate);
    } catch (err) {
      this.noteOptionalError(err, `Optional topic 0x${topic.toString(16)} unavailable`);
    }
  }

  private wireClientEvents(client: RA8RpcClient, silent: boolean): void {
    client.on('error', (err: Error) => {
      if (!silent) this.errorMessage.set(err.message);
    });
    client.on('close', () => {
      if (this.client !== client) return;
      this.client = null;
      this.connectionState.set('disconnected');
      this.disconnected$.next();
    });
    client.on('stop', (evt) => this.stop$.next(evt));
    client.on('uart', (evt) => this.uart$.next(evt));
    client.on('lcd_dirty', (evt) => this.lcdDirty$.next(evt));
    client.on('trace', (evt) => this.trace$.next(evt));
    client.on('session', (evt) => this.session$.next(evt));
    client.on('transport', (evt) => this.transport$.next(evt));
  }

  private cleanupClient(): void {
    if (!this.client) return;
    const prev = this.client;
    this.client = null;
    try {
      prev.disconnect();
    } catch (err) {
      this.errorMessage.set(err instanceof Error ? err.message : String(err));
    }
  }

  private ensureReconnectLoop(): void {
    if (this.reconnectTimer || typeof window === 'undefined') return;
    this.reconnectTimer = setInterval(() => {
      if (
        this.sessionEverConnected &&
        !this.manualDisconnect &&
        this.connectionState() === 'disconnected'
      ) {
        void this.connect(this.serverUrl(), true);
      }
    }, 3000);
  }

  private stopReconnectLoop(): void {
    if (this.reconnectTimer) {
      clearInterval(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }
}
