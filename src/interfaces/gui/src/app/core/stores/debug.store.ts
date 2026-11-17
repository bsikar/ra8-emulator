import { Injectable, computed, effect, inject, signal } from '@angular/core';
import {
  Access,
  type Backtrace,
  CAP_WORKSPACE,
  Core,
  type DisasmRow,
  type NamedPointResult,
  type RA8RpcClient,
  type Register,
  type SetVarReply,
  SetVarStatus,
  type SourceLineResult,
} from 'ra8-rpc-client';
import { type EvaluatedLocal, evaluateLocals } from '../../shared/utils/dwarf-eval';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { type BreakpointEntry, DebugPointsStore, type WatchpointEntry } from './debug-points.store';
import { ExecutionStore } from './execution.store';

export type { BreakpointEntry, WatchpointEntry };

@Injectable({ providedIn: 'root' })
export class DebugStore {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly points = inject(DebugPointsStore);

  public readonly activeCore = signal<Core>(Core.Cpu0);
  public readonly cpu0Registers = signal<Record<string, number>>({});
  public readonly cpu0PrevRegisters = signal<Record<string, number>>({});
  public readonly cpu1Registers = signal<Record<string, number>>({});
  public readonly cpu1PrevRegisters = signal<Record<string, number>>({});
  public readonly cpu0Disasm = signal<DisasmRow[]>([]);
  public readonly cpu1Disasm = signal<DisasmRow[]>([]);
  public readonly cpu0Backtrace = signal<Backtrace | null>(null);
  public readonly cpu1Backtrace = signal<Backtrace | null>(null);
  public readonly selectedFrameIndex = signal<number>(0);
  public readonly sourceLine = signal<SourceLineResult | null>(null);
  public readonly sourceFileLines = signal<string[]>([]);
  public readonly locals = signal<EvaluatedLocal[]>([]);
  public readonly lastSetVar = signal<SetVarReply | null>(null);
  public readonly canUndoWrite = signal<boolean>(false);
  public readonly memoryAddress = signal<number>(0x2000_0000);
  public readonly memoryBytes = signal<Uint8Array>(new Uint8Array(0));

  public readonly cpu0Breakpoints = this.points.cpu0Breakpoints;
  public readonly cpu1Breakpoints = this.points.cpu1Breakpoints;
  public readonly deferredBreakpoints = this.points.deferredBreakpoints;
  public readonly watchpoints = this.points.watchpoints;
  public readonly allBreakpoints = this.points.allBreakpoints;

  public readonly registers = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1Registers() : this.cpu0Registers()
  );
  public readonly previousRegisters = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1PrevRegisters() : this.cpu0PrevRegisters()
  );
  public readonly disasm = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1Disasm() : this.cpu0Disasm()
  );
  public readonly backtrace = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1Backtrace() : this.cpu0Backtrace()
  );

  constructor() {
    effect(() => {
      if (this.execution.inspectionEpoch() > 0 && this.rpc.isConnected()) {
        void this.refreshAll();
      }
    });
  }

  public async refreshAll(): Promise<void> {
    if (!this.rpc.isConnected()) return;
    this.selectedFrameIndex.set(0);
    await Promise.all([
      this.refreshRegisters(),
      this.refreshDisassembly(Core.Cpu0),
      this.execution.cpu1Attached() ? this.refreshDisassembly(Core.Cpu1) : Promise.resolve([]),
      this.refreshBacktrace(),
      this.refreshSourceAndLocals(0),
    ]);
  }

  public async refreshRegisters(): Promise<void> {
    await this.refreshCoreRegisters(Core.Cpu0);
    if (this.execution.cpu1Attached()) await this.refreshCoreRegisters(Core.Cpu1);
  }

  public refreshDisassembly(core: Core = this.activeCore(), address?: number, count = 32): Promise<DisasmRow[]> {
    return this.runRpc('Disassembly failed', [], async (client) => {
      const reply = await client.disassemble(core, { address, count, usePc: address === undefined });
      if (core === Core.Cpu0) this.cpu0Disasm.set(reply.rows);
      else this.cpu1Disasm.set(reply.rows);
      return reply.rows;
    });
  }

  public async refreshBacktrace(): Promise<void> {
    await this.refreshCoreBacktrace(Core.Cpu0);
    if (this.execution.cpu1Attached()) await this.refreshCoreBacktrace(Core.Cpu1);
  }

  public async selectFrame(frameIndex: number, frameBase?: number | null): Promise<void> {
    const next = Math.max(0, frameIndex);
    this.selectedFrameIndex.set(next);
    await this.refreshSourceAndLocals(next, frameBase);
  }

  public async refreshSourceAndLocals(frameIndex = this.selectedFrameIndex(), frameBase?: number | null): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    const core = this.activeCore();
    try {
      const sl = await client.getSourceLine(core);
      this.sourceLine.set(sl.found ? sl : null);
      if (sl.found && sl.path && this.rpc.hasCapability(CAP_WORKSPACE)) await this.loadWorkspaceSourceFile(sl.path);
      else if (!sl.found) this.sourceFileLines.set([]);
    } catch (err) {
      this.sourceLine.set(null);
      this.rpc.errorMessage.set(err instanceof Error ? err.message : String(err));
    }
    try {
      const locRes = frameIndex === 0 ? await client.getLocals(core) : await client.getLocalsAt(core, frameIndex);
      const regs = core === Core.Cpu1 ? this.cpu1Registers() : this.cpu0Registers();
      const evaluated = await evaluateLocals(locRes.locals, regs, (addr, len) => this.readMemoryPage(addr, len, core), {
        frameIndex,
        frameBase,
      });
      this.locals.set(evaluated);
    } catch (err) {
      this.locals.set([]);
      this.rpc.errorMessage.set(err instanceof Error ? err.message : String(err));
    }
  }

  public writeRegister(register: Register, value: number, core: Core = this.activeCore()): Promise<boolean> {
    return this.runRpc('Register write failed', false, async (client) => {
      const ok = await client.writeRegister(core, register, value >>> 0);
      if (ok) this.execution.inspectionEpoch.update((n) => n + 1);
      return ok;
    });
  }

  public setVar(
    name: string,
    value: string,
    frame = this.selectedFrameIndex(),
    core: Core = this.activeCore()
  ): Promise<SetVarReply | null> {
    const cleanName = name.trim();
    if (!cleanName) return Promise.resolve(null);
    return this.runRpc(`setVar(${cleanName}) failed`, null, async (client) => {
      const reply = await client.setVar({ core, frame, name: cleanName, value: value.trim() });
      this.lastSetVar.set(reply);
      if (reply.status === SetVarStatus.Ok) {
        this.canUndoWrite.set(true);
        this.execution.inspectionEpoch.update((n) => n + 1);
        this.rpc.pushToast(`Updated ${cleanName}`);
      } else {
        this.rpc.reportError(`setVar(${cleanName})`, new Error(reply.message || `status ${reply.status}`));
      }
      return reply;
    });
  }

  public undoWrite(core: Core = this.activeCore()): Promise<boolean> {
    return this.runRpc('Undo write failed', false, async (client) => {
      const ok = await client.undoWrite(core);
      if (ok) {
        this.canUndoWrite.set(false);
        this.execution.inspectionEpoch.update((n) => n + 1);
        this.rpc.pushToast('Undid last variable write');
      }
      return ok;
    });
  }

  public async readMemoryPage(address = this.memoryAddress(), length = 128, core: Core = this.activeCore()): Promise<Uint8Array | null> {
    const client = this.rpc.activeClient;
    if (!client) return null;
    try {
      const bytes = await client.readMemory(core, address >>> 0, length);
      if (length >= 64) {
        this.memoryAddress.set(address >>> 0);
        this.memoryBytes.set(bytes);
      }
      return bytes;
    } catch (err) {
      this.rpc.errorMessage.set(err instanceof Error ? err.message : String(err));
      return null;
    }
  }

  public writeMemoryBytes(address: number, bytes: Uint8Array, core: Core = this.activeCore()): Promise<boolean> {
    return this.runRpc('Memory write failed', false, async (client) => {
      const ok = await client.writeMemory(core, address >>> 0, bytes);
      if (ok) await this.readMemoryPage(this.memoryAddress(), Math.max(128, this.memoryBytes().length), core);
      return ok;
    });
  }

  public toggleBreakpoint(address: number, core: Core = this.activeCore(), label?: string): Promise<boolean> {
    return this.points.toggleBreakpoint(address, core, label);
  }

  public addNamedBreakpoint(name: string, core: Core = this.activeCore()): Promise<NamedPointResult | null> {
    return this.points.addNamedBreakpoint(name, core);
  }

  public addWatchpoint(address: number, sizeBytes = 4, access: Access = Access.Write, core: Core = this.activeCore()): Promise<boolean> {
    return this.points.addWatchpoint(address, sizeBytes, access, core);
  }

  public removeWatchpoint(wp: WatchpointEntry): Promise<void> {
    return this.points.removeWatchpoint(wp);
  }

  private async runRpc<T>(label: string, fallback: T, fn: (client: RA8RpcClient) => Promise<T>): Promise<T> {
    const client = this.rpc.activeClient;
    if (!client) return fallback;
    try {
      return await fn(client);
    } catch (err) {
      this.rpc.reportError(label, err);
      return fallback;
    }
  }

  private async refreshCoreRegisters(core: Core): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const regs = await client.readExtendedRegisters(core);
      if (core === Core.Cpu0) {
        this.cpu0PrevRegisters.set(this.cpu0Registers());
        this.cpu0Registers.set(regs);
      } else {
        this.cpu1PrevRegisters.set(this.cpu1Registers());
        this.cpu1Registers.set(regs);
      }
    } catch (err) {
      if (core === Core.Cpu0) this.rpc.reportError('CPU0 register read failed', err);
      else this.rpc.errorMessage.set(`CPU1 register read skipped: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  private async refreshCoreBacktrace(core: Core): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    const target = core === Core.Cpu1 ? this.cpu1Backtrace : this.cpu0Backtrace;
    try {
      target.set(await client.getBacktrace(core));
    } catch (err) {
      target.set(null);
      this.rpc.errorMessage.set(err instanceof Error ? err.message : String(err));
    }
  }

  private async loadWorkspaceSourceFile(path: string): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const res = await client.workspaceRead({ path, offset: 0n, length: 65_536 });
      this.sourceFileLines.set(new TextDecoder().decode(res.bytes).split(/\r?\n/));
    } catch (err) {
      this.sourceFileLines.set([]);
      this.rpc.errorMessage.set(err instanceof Error ? err.message : String(err));
    }
  }
}
