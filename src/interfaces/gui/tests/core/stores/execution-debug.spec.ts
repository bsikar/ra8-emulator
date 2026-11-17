import { TestBed } from '@angular/core/testing';
import {
  CAP_TRANSPORT,
  CAP_WORKSPACE,
  Core,
  EventKind,
  LocalWhereKind,
  SetVarScope,
  SetVarStatus,
  StopReason,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';

describe('ExecutionStore and DebugStore', () => {
  it('drives continuous run via Topic.Transport slices without setTimeout polling', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);

    let advanceCalls = 0;
    const fakeClient = {
      advanceAsync: async () => {
        advanceCalls += 1;
        return { core: Core.Cpu0, fromNs: 0n, targetNs: 16_000_000n };
      },
      interrupt: async () => true,
      pause: async () => true,
      now: async () => 16_000_000n,
    };

    rpc.connectionState.set('connected');
    rpc.serverCaps.set(CAP_TRANSPORT);
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await execution.run();
    expect(execution.isRunning()).toBe(true);
    expect(advanceCalls).toBe(1);

    rpc.transport$.next({
      epoch: 1n,
      phase: 0,
      targetNs: 16_000_000n,
      reachedNs: 16_000_000n,
      slices: 1n,
      finished: 1,
      core: Core.Cpu0,
      fromNs: 0n,
      toNs: 16_000_000n,
      reason: StopReason.Count,
      address: 0x0200_0100,
    });
    expect(advanceCalls).toBe(2);
    expect(execution.virtualTimeNs()).toBe(16_000_000n);

    await execution.pause();
    expect(execution.isRunning()).toBe(false);
  });

  it('fetches frame locals via getLocalsAt and loads workspace source via CAP_WORKSPACE', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const debug = TestBed.inject(DebugStore);

    let requestedFrame = -1;
    let workspacePath = '';
    const fakeClient = {
      getSourceLine: async () => ({ found: true, pc: 0x0200_0020, line: 12, path: 'src/main.c' }),
      workspaceRead: async (args: { path: string }) => {
        workspacePath = args.path;
        return { bytes: new TextEncoder().encode('int main(void) {\n  return 0;\n}') };
      },
      getLocals: async () => ({ core: Core.Cpu0, count: 0, locals: [] }),
      getLocalsAt: async (_core: Core, frame: number) => {
        requestedFrame = frame;
        return {
          core: Core.Cpu0,
          count: 1,
          locals: [
            { name: 'outer_x', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.Frame, whereA: -4n, whereB: 0n },
          ],
        };
      },
      readMemory: async () => new Uint8Array([0x2a, 0x00, 0x00, 0x00]),
    };

    rpc.connectionState.set('connected');
    rpc.serverCaps.set(CAP_WORKSPACE);
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await debug.selectFrame(2, 0x2000_0400);
    expect(requestedFrame).toBe(2);
    expect(debug.selectedFrameIndex()).toBe(2);
    expect(debug.locals()[0]?.valueDec).toBe('42');
    expect(debug.memoryBytes().length).toBe(0);
    expect(workspacePath).toBe('src/main.c');
    expect(debug.sourceFileLines()[0]).toBe('int main(void) {');
  });

  it('reads extended registers per core and executes setVar / undoWrite', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const debug = TestBed.inject(DebugStore);

    const extCalls: Core[] = [];
    const fakeClient = {
      readExtendedRegisters: async (core: Core) => {
        extCalls.push(core);
        return core === Core.Cpu0 ? { pc: 0x0200_0100, msp: 0x2000_1000, fpscr: 0x10 } : { pc: 0x0300_0040 };
      },
      setVar: async () => ({
        status: SetVarStatus.Ok,
        scope: SetVarScope.Local,
        address: 0x2000_03fc,
        inRegister: 0,
        size: 4,
        message: 'ok',
      }),
      undoWrite: async () => true,
    };

    rpc.connectionState.set('connected');
    execution.cpu1Attached.set(true);
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await debug.refreshRegisters();
    expect(extCalls).toEqual([Core.Cpu0, Core.Cpu1]);
    expect(debug.cpu0Registers()['fpscr']).toBe(0x10);
    expect(debug.cpu1Registers()['pc']).toBe(0x0300_0040);

    const reply = await debug.setVar('outer_x', '99');
    expect(reply?.status).toBe(SetVarStatus.Ok);
    expect(debug.canUndoWrite()).toBe(true);

    expect(await debug.undoWrite()).toBe(true);
    expect(debug.canUndoWrite()).toBe(false);
  });

  it('enforces Observe read-only mode on execution/debug mutations and syncs external SessionEvent stops', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const debug = TestBed.inject(DebugStore);

    let stepCalls = 0;
    let regWriteCalls = 0;
    let nowValue = 500_000n;
    const fakeClient = {
      step: async () => {
        stepCalls += 1;
        return { core: Core.Cpu0, reason: StopReason.Stepped, address: 0x0200_0002 };
      },
      writeRegister: async () => {
        regWriteCalls += 1;
        return true;
      },
      now: async () => nowValue,
    };

    rpc.connectionState.set('connected');
    rpc.setObserveOnly(true);
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });

    await execution.step();
    await execution.run();
    expect(await debug.writeRegister(0, 123)).toBe(false);
    expect(stepCalls).toBe(0);
    expect(regWriteCalls).toBe(0);
    expect(rpc.toasts().some((t) => t.message.includes('Observe mode is read-only'))).toBe(true);

    const beforeEpoch = execution.inspectionEpoch();
    nowValue = 950_000n;
    rpc.session$.next({ core: Core.Cpu0, kind: EventKind.Stopped, address: 0x0200_0140 });
    await Promise.resolve();
    expect(execution.inspectionEpoch()).toBe(beforeEpoch + 1);
    expect(execution.externalSyncCount()).toBe(1);
    expect(execution.virtualTimeNs()).toBe(950_000n);
  });
});
