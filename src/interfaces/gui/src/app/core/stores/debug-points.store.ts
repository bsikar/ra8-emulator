import { Injectable, computed, inject, signal } from '@angular/core';
import { Access, Core, type NamedPointResult } from 'ra8-rpc-client';
import { formatHex32 } from '../../shared/utils/hex';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

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
      if (res.deferred) {
        this.deferredBreakpoints.update((arr) => [
          ...arr.filter((b) => !(b.core === core && b.label === clean)),
          { id: res.id, core, address: 0, label: clean, deferred: true },
        ]);
      } else {
        const normalized = (res.address & ~1) >>> 0;
        const sig = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
        const labels = core === Core.Cpu1 ? this.bpLabelsCpu1 : this.bpLabelsCpu0;
        const next = new Map(sig());
        next.set(normalized, res.id);
        labels.set(normalized, clean);
        sig.set(next);
      }
      return res;
    } catch (err) {
      this.rpc.reportError(`Named breakpoint "${clean}" failed`, err);
      return null;
    }
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
