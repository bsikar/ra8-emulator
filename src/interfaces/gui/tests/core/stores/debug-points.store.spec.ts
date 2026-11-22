import { TestBed } from '@angular/core/testing';
import { Core, ErrorCode, RpcCallError } from 'ra8-rpc-client';
import { describe, expect, it } from 'vitest';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugPointsStore } from '../../../src/app/core/stores/debug-points.store';

describe('DebugPointsStore named breakpoint preservation', () => {
  it('collects explicit symbol names, deferred symbols, and symbol-matched gutter addresses', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const points = TestBed.inject(DebugPointsStore);

    let nextId = 1;
    const fakeClient = {
      setBreakpointId: async () => nextId++,
      clearBreakpointById: async () => true,
      setBreakpointByName: async (_core: Core, name: string) => {
        if (name === 'deferred_hook') return { id: 99, address: 0, deferred: 1 };
        return { id: nextId++, address: 0x0200_0101, deferred: 0 };
      },
    };
    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await points.addNamedBreakpoint('main', Core.Cpu0);
    await points.addNamedBreakpoint('deferred_hook', Core.Cpu0);
    // Gutter-style address breakpoint with hex label that matches an ELF symbol address
    await points.toggleBreakpoint(0x0200_0241, Core.Cpu0, '0x02000240');
    // Unmapped raw hex address should not emit a bogus symbol name
    await points.toggleBreakpoint(0x0200_0900, Core.Cpu0, '0x02000900');

    const names = points.collectSymbolBreakpointNames(Core.Cpu0, [
      { name: 'isr_uart', address: 0x0200_0241, size: 16, kind: 'func' },
    ]);
    expect(names).toEqual(['deferred_hook', 'main', 'isr_uart']);
  });

  it('clears core breakpoints and re-applies named breakpoints skipping removed symbols cleanly', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const points = TestBed.inject(DebugPointsStore);

    const clearedIds: number[] = [];
    const appliedNames: string[] = [];
    let bpId = 10;
    const fakeClient = {
      setBreakpointByName: async (_core: Core, name: string) => {
        appliedNames.push(name);
        if (name === 'removed_fn') {
          throw new RpcCallError(ErrorCode.AppRefused, 0x0123, 1);
        }
        return { id: bpId++, address: name === 'main' ? 0x0200_0301 : 0, deferred: name === 'later_fn' ? 1 : 0 };
      },
      clearBreakpointById: async (_core: Core, id: number) => {
        clearedIds.push(id);
        return true;
      },
    };
    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await points.addNamedBreakpoint('main', Core.Cpu0);
    expect(points.cpu0Breakpoints().get(0x0200_0300)).toBe(10);

    await points.clearBreakpointsForCore(Core.Cpu0);
    expect(clearedIds).toEqual([10]);
    expect(points.cpu0Breakpoints().size).toBe(0);
    appliedNames.length = 0;

    const summary = await points.restoreNamedBreakpoints(Core.Cpu0, ['main', 'later_fn', 'removed_fn']);
    expect(appliedNames).toEqual(['main', 'later_fn', 'removed_fn']);
    expect(summary).toEqual({ applied: 1, deferred: 1, unresolved: 1 });
    expect(points.cpu0Breakpoints().get(0x0200_0300)).toBe(11);
    expect(points.deferredBreakpoints().map((b) => b.label)).toEqual(['later_fn']);
    expect(rpc.errorMessage()).toBeNull();
  });
});
