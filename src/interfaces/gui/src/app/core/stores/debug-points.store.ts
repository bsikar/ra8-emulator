import { Injectable, computed, inject, signal } from '@angular/core';
import { Access, Core, type ElfSymbol, type NamedPointResult } from 'ra8-rpc-client';
import { formatHex32 } from '../../shared/utils/hex';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export interface RestoredBreakpointSummary {
  applied: number;
  deferred: number;
  unresolved: number;
}

function isHexAddressLabel(label: string): boolean {
  return /^0x[0-9a-f]+$/i.test(label.trim());
}

export interface BreakpointEntry {
  id: number;
  core: Core;
  address: number;
  label: string;
  deferred: boolean;
}

export interface WatchpointEntry {
  id: number;
  core: Core;
  first: number;
  last: number;
  access: Access;
}

@Injectable({ providedIn: 'root' })
export class DebugPointsStore {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly bpLabelsCpu0 = new Map<number, string>();
  private readonly bpLabelsCpu1 = new Map<number, string>();

  public readonly cpu0Breakpoints = signal<Map<number, number>>(new Map());
  public readonly cpu1Breakpoints = signal<Map<number, number>>(new Map());
  public readonly deferredBreakpoints = signal<BreakpointEntry[]>([]);
  public readonly watchpoints = signal<WatchpointEntry[]>([]);

  public readonly allBreakpoints = computed<BreakpointEntry[]>(() => {
    const out: BreakpointEntry[] = [];
    for (const [address, id] of this.cpu0Breakpoints().entries()) {
      out.push({
        id,
        core: Core.Cpu0,
        address,
        label: this.bpLabelsCpu0.get(address) ?? formatHex32(address),
        deferred: false,
      });
    }
    for (const [address, id] of this.cpu1Breakpoints().entries()) {
      out.push({
        id,
        core: Core.Cpu1,
        address,
        label: this.bpLabelsCpu1.get(address) ?? formatHex32(address),
        deferred: false,
      });
    }
    return [...out, ...this.deferredBreakpoints()];
  });

  public async toggleBreakpoint(address: number, core: Core, label?: string): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const normalized = (address & ~1) >>> 0;
    const sig = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
    const labels = core === Core.Cpu1 ? this.bpLabelsCpu1 : this.bpLabelsCpu0;
    const next = new Map(sig());
    try {
      const existingId = next.get(normalized);
      if (existingId !== undefined) {
        await client.clearBreakpointById(core, existingId);
        next.delete(normalized);
        labels.delete(normalized);
      } else {
        const id = await client.setBreakpointId(core, normalized);
        next.set(normalized, id);
        if (label) labels.set(normalized, label);
      }
      sig.set(next);
      return true;
    } catch (err) {
      this.rpc.reportError('Breakpoint error', err);
      return false;
    }
  }

  public async addNamedBreakpoint(name: string, core: Core): Promise<NamedPointResult | null> {
    const client = this.rpc.activeClient;
    const clean = name.trim();
    if (!client || !clean) return null;
    try {
      const res = await client.setBreakpointByName(core, clean);
      this.recordNamedPoint(core, clean, res);
      return res;
    } catch (err) {
      this.rpc.reportError(`Named breakpoint "${clean}" failed`, err);
      return null;
    }
  }

  public collectSymbolBreakpointNames(core: Core, elfSymbols: readonly ElfSymbol[]): string[] {
    const names = new Set<string>();
    for (const entry of this.deferredBreakpoints()) {
      if (entry.core !== core) continue;
      const clean = entry.label.trim();
      if (clean && !isHexAddressLabel(clean)) names.add(clean);
    }
    const sig = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
    const labels = core === Core.Cpu1 ? this.bpLabelsCpu1 : this.bpLabelsCpu0;
    for (const address of sig().keys()) {
      const explicit = labels.get(address)?.trim();
      if (explicit && !isHexAddressLabel(explicit)) {
        names.add(explicit);
        continue;
      }
      const norm = (address & ~1) >>> 0;
      const match = elfSymbols.find((s) => ((s.address & ~1) >>> 0) === norm);
      if (match?.name) names.add(match.name);
    }
    return [...names];
  }

  public async clearBreakpointsForCore(core: Core): Promise<void> {
    const client = this.rpc.activeClient;
    const sig = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
    const labels = core === Core.Cpu1 ? this.bpLabelsCpu1 : this.bpLabelsCpu0;
    const ids = [
      ...sig().values(),
      ...this.deferredBreakpoints()
        .filter((b) => b.core === core)
        .map((b) => b.id),
    ];
    if (client) {
      for (const id of ids) {
        try {
          await client.clearBreakpointById(core, id);
        } catch (err) {
          this.rpc.noteOptionalError(err, 'Clear breakpoint before reload');
        }
      }
    }
    sig.set(new Map());
    labels.clear();
    this.deferredBreakpoints.update((arr) => arr.filter((b) => b.core !== core));
  }

  public async restoreNamedBreakpoints(
    core: Core,
    names: readonly string[]
  ): Promise<RestoredBreakpointSummary> {
    const unique = [...new Set(names.map((n) => n.trim()).filter(Boolean))];
    const client = this.rpc.activeClient;
    if (!client || unique.length === 0) {
      return { applied: 0, deferred: 0, unresolved: unique.length };
    }
    let applied = 0;
    let deferred = 0;
    let unresolved = 0;
    for (const clean of unique) {
      try {
        const res = await client.setBreakpointByName(core, clean);
        this.recordNamedPoint(core, clean, res);
        if (res.deferred) deferred += 1;
        else applied += 1;
      } catch (err) {
        this.rpc.noteOptionalError(err, `Unresolved breakpoint symbol on reload (${clean})`);
        unresolved += 1;
      }
    }
    return { applied, deferred, unresolved };
  }

  private recordNamedPoint(core: Core, clean: string, res: NamedPointResult): void {
    if (res.deferred) {
      this.deferredBreakpoints.update((arr) => [
        ...arr.filter((b) => !(b.core === core && b.label === clean)),
        { id: res.id, core, address: 0, label: clean, deferred: true },
      ]);
      return;
    }
    const normalized = (res.address & ~1) >>> 0;
    const sig = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
    const labels = core === Core.Cpu1 ? this.bpLabelsCpu1 : this.bpLabelsCpu0;
    const next = new Map(sig());
    next.set(normalized, res.id);
    labels.set(normalized, clean);
    sig.set(next);
  }

  public async addWatchpoint(
    address: number,
    sizeBytes = 4,
    access: Access = Access.Write,
    core: Core = Core.Cpu0
  ): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const first = address >>> 0;
    const last = (first + Math.max(1, sizeBytes) - 1) >>> 0;
    try {
      const id = await client.setWatchpoint(core, first, last, access);
      this.watchpoints.update((arr) => [...arr, { id, core, first, last, access }]);
      return true;
    } catch (err) {
      this.rpc.reportError('Watchpoint failed', err);
      return false;
    }
  }

  public async removeWatchpoint(wp: WatchpointEntry): Promise<void> {
    const client = this.rpc.activeClient;
    if (client) {
      try {
        await client.clearWatchpoint(wp.core, wp.id);
      } catch (err) {
        this.rpc.reportError('Clear watchpoint failed', err);
      }
    }
    this.watchpoints.update((arr) => arr.filter((item) => !(item.id === wp.id && item.core === wp.core)));
  }
}
