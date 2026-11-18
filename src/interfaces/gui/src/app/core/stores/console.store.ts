import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import { Core, type UartEvent } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { ExecutionStore } from './execution.store';

export const MAX_CONSOLE_ENTRIES = 2000;
export type ConsoleLineEnding = 'lf' | 'crlf' | 'none';

export interface ConsoleEntry {
  id: number;
  core: Core;
  channel: number;
  virtualNs: bigint;
  bytes: Uint8Array;
  text: string;
  isInput: boolean;
}

@Injectable({ providedIn: 'root' })
export class ConsoleStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly decoder = new TextDecoder();
  private readonly encoder = new TextEncoder();
  private readonly subs = new Subscription();
  private nextId = 1;

  public readonly entries = signal<ConsoleEntry[]>([]);
  public readonly selectedChannel = signal<number | 'all'>('all');
  public readonly activeCore = signal<Core>(Core.Cpu0);

  public readonly channels = computed<number[]>(() => {
    const seen = new Set<number>();
    for (const item of this.entries()) seen.add(item.channel);
    return Array.from(seen).sort((a, b) => a - b);
  });

  public readonly filteredEntries = computed<ConsoleEntry[]>(() => {
    const ch = this.selectedChannel();
    const list = this.entries();
    return ch === 'all' ? list : list.filter((e) => e.channel === ch);
  });

  constructor() {
    this.subs.add(this.rpc.uart$.subscribe((evt) => this.pushUartEvent(evt)));
  }

  public pushUartEvent(evt: UartEvent): void {
    const copy = new Uint8Array(evt.bytes);
    const entry: ConsoleEntry = {
      id: this.nextId++,
      core: evt.core,
      channel: evt.channel,
      virtualNs: evt.virtualNs,
      bytes: copy,
      text: this.decoder.decode(copy),
      isInput: false,
    };
    this.appendEntry(entry);
  }

  public async sendInput(
    rawText: string,
    core: Core = this.activeCore(),
    lineEnding: ConsoleLineEnding = 'lf',
    localEcho = true
  ): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const payloadText =
      lineEnding === 'none'
        ? rawText
        : lineEnding === 'crlf'
          ? `${rawText.replace(/\r?\n$/, '')}\r\n`
          : rawText.endsWith('\n')
            ? rawText
            : `${rawText}\n`;
    const bytes = this.encoder.encode(payloadText);
    const channel = this.selectedChannel() === 'all' ? 0 : (this.selectedChannel() as number);
    if (localEcho) {
      this.appendEntry({
        id: this.nextId++,
        core,
        channel,
        virtualNs: this.execution.virtualTimeNs(),
        bytes: new Uint8Array(bytes),
        text: payloadText,
        isInput: true,
      });
    }
    try {
      return await client.sendConsoleInput(core, bytes);
    } catch (err) {
      this.rpc.reportError('Console input failed', err);
      return false;
    }
  }

  public clear(): void {
    this.entries.set([]);
  }

  public exportLogText(): string {
    return this.filteredEntries()
      .map((entry) => {
        const dir = entry.isInput ? 'TX' : 'RX';
        const ns = entry.virtualNs.toString();
        return `[t=${ns}ns CPU${entry.core} CH${entry.channel} ${dir}] ${entry.text}`;
      })
      .join('\n');
  }

  public exportLogBlob(): Blob {
    return new Blob([this.exportLogText()], { type: 'text/plain;charset=utf-8' });
  }

  public ngOnDestroy(): void {
    this.subs.unsubscribe();
  }

  private appendEntry(entry: ConsoleEntry): void {
    this.entries.update((prev) => {
      if (prev.length >= MAX_CONSOLE_ENTRIES) {
        return [...prev.slice(prev.length - MAX_CONSOLE_ENTRIES + 1), entry];
      }
      return [...prev, entry];
    });
  }
}
