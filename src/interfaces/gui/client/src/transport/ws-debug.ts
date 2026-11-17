/**
 * Debugger inspection, breakpoints, memory, DWARF, and time-travel RPC methods.
 */

import {
  Backtrace,
  COMMON_REGISTERS,
  DisasmReply,
  EXTENDED_REGISTERS,
  FPU_MVE_REGISTERS,
  LocalsResult,
  NamedPointResult,
  Register,
  RegisterEntry,
  SYS_REGISTERS,
  SetVarArgs,
  SetVarReply,
  SourceLineResult,
  decodeBacktrace,
  decodeDisasmReply,
  decodeLocals,
  decodeMemory,
  decodeNamedPoint,
  decodeSetVarReply,
  decodeSourceLine,
  encodeCoreFrame,
  encodeDisasmAsk,
  encodeMapAsk,
  encodeNamedBreak,
  encodePeriphAsk,
  encodePoint,
  encodePointId,
  encodeReadMemory,
  encodeReadRegister,
  encodeSetVarArgs,
  encodeWatchpoint,
  encodeWriteMemory,
  encodeWriteRegister,
  readRegisterBatch,
} from "../wire/debug.js";
import {
  BranchItem,
  DecodedDiff,
  Direction,
  ForkStatus,
  FrameStatusResult,
  NavQueryArgs,
  NavQueryResult,
  decodeBranchList,
  decodeDiff,
  decodeForkStatus,
  decodeFrameStatusResult,
  decodeNavQueryResult,
  encodeBranchConfirmFork,
  encodeBranchDelete,
  encodeBranchSwitch,
  encodeDiffArgs,
  encodeMarkerSetArgs,
  encodeNavQueryArgs,
  encodePlayArgs,
} from "../wire/history.js";
import { encodeSeek } from "../wire/session.js";
import { Access, Core, Method } from "../wire/types.js";
import { decodeAck, decodeTextSlice, decodeU32, encodeCoreOnly } from "./envelope.js";
import { RA8RpcSessionClient } from "./ws-session.js";

/** Debugger inspection and time-travel navigation RPC methods. */
export class RA8RpcDebugClient extends RA8RpcSessionClient {
  public async readRegister(core: Core, register: Register): Promise<number> {
    return decodeU32(await this.call(Method.ReadRegister, encodeReadRegister(core, register)));
  }

  public readRegisterGroup(
    core: Core,
    entries: readonly RegisterEntry[]
  ): Promise<Record<string, number>> {
    return readRegisterBatch((c, r) => this.readRegister(c, r), core, entries);
  }

  public readRegisters(core: Core = Core.Cpu0): Promise<Record<string, number>> {
    return this.readRegisterGroup(core, COMMON_REGISTERS);
  }

  public readSysRegisters(core: Core = Core.Cpu0): Promise<Record<string, number>> {
    return this.readRegisterGroup(core, SYS_REGISTERS);
  }

  public readFpuRegisters(core: Core = Core.Cpu0): Promise<Record<string, number>> {
    return this.readRegisterGroup(core, FPU_MVE_REGISTERS);
  }

  public readExtendedRegisters(core: Core = Core.Cpu0): Promise<Record<string, number>> {
    return this.readRegisterGroup(core, EXTENDED_REGISTERS);
  }

  public writeRegister(core: Core, register: Register, value: number): Promise<boolean> {
    return this.ack(Method.WriteRegister, encodeWriteRegister(core, register, value));
  }

  public async readMemory(core: Core, address: number, length: number): Promise<Uint8Array> {
    return decodeMemory(await this.call(Method.ReadMemory, encodeReadMemory(core, address, length)));
  }

  public writeMemory(core: Core, address: number, bytes: Uint8Array): Promise<boolean> {
    return this.ack(Method.WriteMemory, encodeWriteMemory(core, address, bytes));
  }

  public async setBreakpointId(core: Core, address: number): Promise<number> {
    const resp = await this.call(Method.SetBreakpoint, encodePoint(core, address));
    return resp.length >= 4 ? decodeU32(resp) : (decodeAck(resp).accepted !== 0 ? 1 : 0);
  }

  public async setBreakpoint(core: Core, address: number): Promise<boolean> {
    const resp = await this.call(Method.SetBreakpoint, encodePoint(core, address));
    return resp.length >= 4 ? true : decodeAck(resp).accepted !== 0;
  }

  public clearBreakpointById(core: Core, id: number): Promise<boolean> {
    return this.ack(Method.ClearBreakpoint, encodePointId(core, id));
  }

  public clearBreakpoint(core: Core, idOrAddress: number): Promise<boolean> {
    return this.ack(Method.ClearBreakpoint, encodePointId(core, idOrAddress));
  }

  public async setBreakpointByName(core: Core, name: string): Promise<NamedPointResult> {
    return decodeNamedPoint(await this.call(Method.SetBreakpointName, encodeNamedBreak(core, name)));
  }

  public async setWatchpoint(
    core: Core,
    first: number,
    last = first,
    access: Access = Access.Write
  ): Promise<number> {
    return decodeU32(await this.call(Method.SetWatchpoint, encodeWatchpoint(core, first, last, access)));
  }

  public clearWatchpoint(core: Core, id: number): Promise<boolean> {
    return this.ack(Method.ClearWatchpoint, encodePointId(core, id));
  }

  public async removePoint(core: Core, id: number): Promise<number> {
    return decodeU32(await this.call(Method.RemovePoint, encodePointId(core, id)));
  }

  public skipBreakpoint(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.SkipBkpt, encodeCoreOnly(core));
  }

  public async disassemble(
    core: Core = Core.Cpu0,
    options: { address?: number; count?: number; usePc?: boolean } = {}
  ): Promise<DisasmReply> {
    const resp = await this.call(
      Method.Disasm,
      encodeDisasmAsk({
        core,
        address: options.address ?? 0,
        count: options.count ?? 24,
        usePc: options.usePc ?? options.address === undefined,
      })
    );
    return decodeDisasmReply(resp);
  }

  public async getBacktrace(core: Core = Core.Cpu0): Promise<Backtrace> {
    return decodeBacktrace(await this.call(Method.Backtrace, encodeCoreOnly(core)));
  }

  public async getMap(core: Core = Core.Cpu0, json = false): Promise<string> {
    return decodeTextSlice(await this.call(Method.Map, encodeMapAsk(core, json)));
  }

  public async getPeriph(core: Core = Core.Cpu0, block = "", json = false): Promise<string> {
    return decodeTextSlice(await this.call(Method.Periph, encodePeriphAsk(core, block, json)));
  }

  public async getPeriphJson<T = unknown>(core: Core = Core.Cpu0, block = ""): Promise<T> {
    return JSON.parse(await this.getPeriph(core, block, true)) as T;
  }

  public async getSourceLine(core: Core = Core.Cpu0): Promise<SourceLineResult> {
    return decodeSourceLine(await this.call(Method.SourceLine, encodeCoreOnly(core)));
  }

  public async getLocals(core: Core = Core.Cpu0): Promise<LocalsResult> {
    return decodeLocals(await this.call(Method.Locals, encodeCoreOnly(core)));
  }

  public async getLocalsAt(core: Core, frame: number): Promise<LocalsResult> {
    return decodeLocals(await this.call(Method.LocalsAt, encodeCoreFrame(core, frame)));
  }

  public async setVar(args: SetVarArgs): Promise<SetVarReply> {
    return decodeSetVarReply(await this.call(Method.SetVar, encodeSetVarArgs(args)));
  }

  public undoWrite(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.UndoWrite, encodeCoreOnly(core));
  }

  public resetImage(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.ResetImage, encodeCoreOnly(core));
  }

  public async getBranches(): Promise<BranchItem[]> {
    return decodeBranchList(await this.call(Method.BranchList, encodeCoreOnly(Core.Cpu0)));
  }

  public switchBranch(branch: number): Promise<boolean> {
    return this.ack(Method.BranchSwitch, encodeBranchSwitch(branch));
  }

  public deleteBranch(branch: number, confirm = false): Promise<boolean> {
    return this.ack(Method.BranchDelete, encodeBranchDelete(branch, confirm));
  }

  public confirmFork(confirm = true): Promise<boolean> {
    return this.ack(Method.BranchConfirmFork, encodeBranchConfirmFork(confirm));
  }

  public cancelFork(): Promise<boolean> {
    return this.ack(Method.BranchCancelFork, new Uint8Array(0));
  }

  public async getForkStatus(): Promise<ForkStatus> {
    return decodeForkStatus(await this.call(Method.BranchStatus, encodeCoreOnly(Core.Cpu0)));
  }

  public seek(target: string): Promise<boolean> {
    return this.ack(Method.Seek, encodeSeek(target));
  }

  public reverseContinue(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.Rcont, encodeCoreOnly(core));
  }

  public play(dir: Direction = Direction.Fwd, speedMilli = 1000n): Promise<boolean> {
    return this.ack(Method.Play, encodePlayArgs({ dir, speedMilli }));
  }

  public async navQuery(args: NavQueryArgs): Promise<NavQueryResult> {
    return decodeNavQueryResult(await this.call(Method.NavQuery, encodeNavQueryArgs(args)));
  }

  public async setMarker(name: string, place: string): Promise<NavQueryResult> {
    return decodeNavQueryResult(await this.call(Method.MarkerSet, encodeMarkerSetArgs(name, place)));
  }

  public async getFrameStatus(): Promise<FrameStatusResult> {
    return decodeFrameStatusResult(await this.call(Method.FrameStatus, encodeCoreOnly(Core.Cpu0)));
  }

  public async getDiff(a: string, b: string): Promise<DecodedDiff> {
    return decodeDiff(await this.call(Method.Diff, encodeDiffArgs(a, b)));
  }
}
