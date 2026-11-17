import { Injectable, OnDestroy, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import { Core, EventKind, type SessionEvent } from 'ra8-rpc-client';
import { formatHexUpper32 } from '../../shared/utils/hex';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export interface ParsedPartSpec {
  model: string;
  endpoint: string;
}

export interface PeriphBlockMeta {
  name: string;
  base: number;
  size: number;
}

export interface HardwarePartSlot {
  spec: string;
  model: string;
  endpoint: string;
  activeFault: string | null;
}

export interface HardwareEventEntry {
  id: number;
  core: Core;
  kind: EventKind;
  label: string;
  detail: string;
}

export function splitFirstAtEndpoint(partSpec: string): ParsedPartSpec {
  const clean = partSpec.trim();
  const atIdx = clean.indexOf('@');
  if (atIdx < 0) return { model: '', endpoint: clean };
  return {
    model: clean.slice(0, atIdx).trim(),
    endpoint: clean.slice(atIdx + 1).trim(),
  };
}

export function formatFaultSpec(partSpec: string, modeOrRule: string): string {
  const cleanRule = modeOrRule.trim();
  if (cleanRule.includes('@') && cleanRule.includes('=')) return cleanRule;
  const { model, endpoint } = splitFirstAtEndpoint(partSpec);
  return model ? `${model}@${endpoint}=${cleanRule}` : `@${endpoint}=${cleanRule}`;
}

@Injectable({ providedIn: 'root' })
export class HardwareHilStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly subs = new Subscription();
  private readonly periphMeta = new Map<string, PeriphBlockMeta>();
  private nextEventId = 1;

  public readonly fittedParts = signal<HardwarePartSlot[]>([]);
  public readonly periphBlocks = signal<string[]>([]);
  public readonly selectedPeriphBlock = signal<string>('');
  public readonly selectedPeriphText = signal<string>('');
  public readonly events = signal<HardwareEventEntry[]>([]);

  constructor() {
    this.subs.add(this.rpc.session$.subscribe((evt) => this.recordSessionEvent(evt)));
  }

  public async refreshPartsAndPeripherals(core: Core = Core.Cpu0): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const raw = await client.getListParts(core);
      const faultByEndpoint = new Map(this.fittedParts().map((p) => [p.endpoint, p.activeFault]));
      this.fittedParts.set(
        raw.map((spec) => {
          const parsed = splitFirstAtEndpoint(spec);
          return {
            spec,
            model: parsed.model,
            endpoint: parsed.endpoint,
            activeFault: faultByEndpoint.get(parsed.endpoint) ?? null,
          };
        })
      );
    } catch (err) {
      this.rpc.reportError('List fitted parts failed', err);
    }

    try {
      const listRaw = await client.getPeriph(core, '', true);
      const blocks = this.parsePeriphBlockList(listRaw);
      this.periphBlocks.set(blocks);
      const current = this.selectedPeriphBlock();
      if (current && blocks.includes(current)) {
        await this.selectPeriphBlock(current, core);
      } else if (!current && blocks[0]) {
        await this.selectPeriphBlock(blocks[0], core);
      }
    } catch (err) {
      this.rpc.reportError('Peripheral block list failed', err);
    }
  }

  public async selectPeriphBlock(block: string, core: Core = Core.Cpu0): Promise<void> {
    this.selectedPeriphBlock.set(block);
    const client = this.rpc.activeClient;
    if (!client || !block) return;
    const meta = this.periphMeta.get(block);
    const header = meta ? `${block} · ${formatHexUpper32(meta.base)} · 0x${meta.size.toString(16)}\n` : '';
    try {
      const jsonDump = await client.getPeriph(core, block, true);
      this.selectedPeriphText.set(header + jsonDump);
      return;
    } catch (err) {
      if (meta) {
        try {
          const len = Math.min(Math.max(meta.size, 4), 64);
          const bytes = await client.readMemory(core, meta.base, len);
          this.selectedPeriphText.set(header + this.formatMemoryWords(meta.base, bytes));
          return;
        } catch (memErr) {
          this.rpc.reportError(`Peripheral ${block} fallback read failed`, memErr);
        }
      } else {
        this.rpc.reportError(`Peripheral ${block} read failed`, err);
      }
    }
  }

  public async plugPart(partSpec: string, core: Core = Core.Cpu0): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client || !partSpec.trim()) return false;
    try {
      const ok = await client.plug(partSpec.trim(), core);
      if (ok) await this.refreshPartsAndPeripherals(core);
      return ok;
    } catch (err) {
      this.rpc.reportError('Plug part failed', err);
      return false;
    }
  }

  public async unplugPart(endpoint: string, core: Core = Core.Cpu0): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client || !endpoint.trim()) return false;
    try {
      const ok = await client.unplug(endpoint.trim(), core);
      if (ok) await this.refreshPartsAndPeripherals(core);
      return ok;
    } catch (err) {
      this.rpc.reportError('Unplug part failed', err);
      return false;
    }
  }

  public async injectFault(partSpec: string, modeOrRule: string, core: Core = Core.Cpu0): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const rule = formatFaultSpec(partSpec, modeOrRule);
    const { endpoint } = splitFirstAtEndpoint(partSpec);
    try {
      const ok = await client.setFault(rule, core);
      if (ok) {
        this.fittedParts.update((list) =>
          list.map((p) => (p.endpoint === endpoint ? { ...p, activeFault: rule } : p))
        );
      }
      return ok;
    } catch (err) {
      this.rpc.reportError('Inject fault failed', err);
      return false;
    }
  }

  public async clearFault(endpoint: string, core: Core = Core.Cpu0): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      const ok = await client.clearFault(endpoint.trim(), core);
      if (ok) {
        this.fittedParts.update((list) =>
          list.map((p) => (p.endpoint === endpoint.trim() ? { ...p, activeFault: null } : p))
        );
      }
      return ok;
    } catch (err) {
      this.rpc.reportError('Clear fault failed', err);
      return false;
    }
  }

  public ngOnDestroy(): void {
    this.subs.unsubscribe();
  }

  private parsePeriphBlockList(raw: string): string[] {
    this.periphMeta.clear();
    const trimmed = raw.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        const parsed = JSON.parse(trimmed) as { blocks?: Array<{ name: string; base: number; size: number }> } | Array<{ name: string; base: number; size: number }>;
        const arr = Array.isArray(parsed) ? parsed : (parsed.blocks ?? []);
        const names: string[] = [];
        for (const item of arr) {
          if (!item?.name) continue;
          this.periphMeta.set(item.name, { name: item.name, base: item.base >>> 0, size: item.size >>> 0 });
          names.push(item.name);
        }
        return names;
      } catch (err) {
        this.rpc.reportError('Malformed peripheral JSON', err);
      }
    }
    const blocks: string[] = [];
    for (const line of trimmed.split('\n')) {
      const parts = line.trim().split(/\s+/);
      const name = parts[0] ?? '';
      if (!name) continue;
      const base = parts[1] ? Number.parseInt(parts[1], 16) : Number.NaN;
      const size = parts[2] ? Number.parseInt(parts[2], 16) : Number.NaN;
      if (Number.isFinite(base) && Number.isFinite(size)) {
        this.periphMeta.set(name, { name, base: base >>> 0, size: size >>> 0 });
      }
      blocks.push(name);
    }
    return blocks;
  }

  private formatMemoryWords(base: number, bytes: Uint8Array): string {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const lines: string[] = [];
    for (let off = 0; off + 4 <= bytes.length; off += 16) {
      const words: string[] = [];
      for (let w = 0; w < 16 && off + w + 4 <= bytes.length; w += 4) {
        words.push(formatHexUpper32(view.getUint32(off + w, true)));
      }
      lines.push(`${formatHexUpper32((base + off) >>> 0)}: ${words.join(' ')}`);
    }
    return lines.join('\n');
  }

  private recordSessionEvent(evt: SessionEvent): void {
    const labels: Partial<Record<EventKind, string>> = {
      [EventKind.FaultSet]: 'Fault Injected',
      [EventKind.FaultCleared]: 'Fault Cleared',
      [EventKind.Plugged]: 'Part Plugged',
      [EventKind.Unplugged]: 'Part Unplugged',
      [EventKind.MemoryWritten]: 'Memory Written',
      [EventKind.RegisterWritten]: 'Register Written',
      [EventKind.Loaded]: 'Image Loaded',
    };
    const label = labels[evt.kind];
    if (!label) return;
    const entry: HardwareEventEntry = {
      id: this.nextEventId++,
      core: evt.core,
      kind: evt.kind,
      label,
      detail: formatHexUpper32(evt.address),
    };
    this.events.update((list) => [entry, ...list.slice(0, 99)]);
  }
}
