/**
 * Session control, virtual board, camera, RTC, parts, and snapshot RPC methods.
 */

import {
  MetricsReport,
  StackReport,
  decodeMetricsReport,
  decodeStackReport,
  encodeFoldedAsk,
} from "../wire/metrics.js";
import {
  AdvanceQueued,
  AdvancedResult,
  BoardParts,
  RtcReport,
  ScheduleInputArgs,
  Stopped,
  decodeAdvanceQueued,
  decodeAdvanced,
  decodeBoardParts,
  decodeRtcReport,
  decodeStopped,
  encodeAdvance,
  encodeCameraSource,
  encodeConsoleInput,
  encodePartSpec,
  encodeRun,
  encodeRunBudget,
  encodeScheduleInput,
  encodeSetSpeed,
  encodeStatePath,
  encodeSubscription,
  uploadElfImage,
} from "../wire/session.js";
import { Core, Method, RunMode, Topic } from "../wire/types.js";
import { decodeAck, decodeTextSlice, decodeU64, encodeCoreOnly, encodeText } from "./envelope.js";
import { WsTransport } from "./ws-transport.js";

/** Session execution, board hardware, input, metrics, and snapshot methods. */
export class RA8RpcSessionClient extends WsTransport {
  public async sessionStatus(): Promise<{ loaded: boolean; machine: string }> {
    const reply = await this.call(Method.SessionStatus, new Uint8Array());
    if (reply.length < 5 || reply[0]! > 1) throw new Error("Invalid session status reply");
    return { loaded: reply[0] === 1, machine: decodeTextSlice(reply.subarray(1)) };
  }

  public closeSession(): Promise<boolean> {
    return this.ack(Method.SessionClose, new Uint8Array());
  }

  public configureSession(machine: string, profile = ""): Promise<boolean> {
    const name = encodeText(machine, 64);
    const board = encodeText(profile, 65536);
    const args = new Uint8Array(name.length + board.length);
    args.set(name);
    args.set(board, name.length);
    return this.ack(Method.SessionConfigure, args);
  }

  public async loadElf(
    core: Core,
    image: Uint8Array,
    onProgress?: (loadedBytes: number, totalBytes: number) => void
  ): Promise<boolean> {
    return uploadElfImage((m, a, t) => this.call(m, a, t), core, image, onProgress);
  }

  public run(core: Core = Core.Cpu0, mode: RunMode = RunMode.Run, budget = 0n): Promise<boolean> {
    return this.ack(Method.Run, encodeRun(core, mode, budget));
  }

  public continueRun(core: Core = Core.Cpu0, budget = 0n): Promise<boolean> {
    return this.run(core, RunMode.Cont, budget);
  }

  public step(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.Step, encodeCoreOnly(core));
  }

  public stepOver(core: Core = Core.Cpu0): Promise<boolean> {
    return this.run(core, RunMode.Next, 0n);
  }

  public stepOut(core: Core = Core.Cpu0): Promise<boolean> {
    return this.run(core, RunMode.Finish, 0n);
  }

  public pause(core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.Pause, encodeCoreOnly(core));
  }

  public async interrupt(core: Core = Core.Cpu0): Promise<Stopped> {
    return decodeStopped(await this.call(Method.Interrupt, encodeCoreOnly(core)));
  }

  public setRunBudget(core: Core, instructions: bigint | number): Promise<boolean> {
    return this.ack(Method.SetRunBudget, encodeRunBudget(core, instructions));
  }

  public setSpeed(core: Core = Core.Cpu0, milli: bigint | number = 0n): Promise<boolean> {
    return this.ack(Method.SetSpeed, encodeSetSpeed(core, milli));
  }

  public async now(core: Core = Core.Cpu0): Promise<bigint> {
    return decodeU64(await this.call(Method.Now, encodeCoreOnly(core)));
  }

  public async advance(core: Core, ns: bigint): Promise<boolean> {
    const resp = await this.call(Method.Advance, encodeAdvance(core, ns), 30000);
    if (resp.length >= 22) {
      decodeAdvanced(resp);
      return true;
    }
    return decodeAck(resp).accepted !== 0;
  }

  public async advanceDetail(core: Core, ns: bigint): Promise<AdvancedResult> {
    return decodeAdvanced(await this.call(Method.Advance, encodeAdvance(core, ns), 30000));
  }

  public async advanceAsync(core: Core, ns: bigint): Promise<AdvanceQueued> {
    return decodeAdvanceQueued(await this.call(Method.AdvanceAsync, encodeAdvance(core, ns)));
  }

  public subscribe(core: Core, topic: Topic, rate = 0): Promise<boolean> {
    return this.ack(Method.Subscribe, encodeSubscription(core, topic, rate));
  }

  public unsubscribe(core: Core, topic: Topic): Promise<boolean> {
    return this.ack(Method.Unsubscribe, encodeSubscription(core, topic, 0));
  }

  public async getMetrics(): Promise<MetricsReport> {
    return decodeMetricsReport(await this.call(Method.Metrics, encodeCoreOnly(Core.Cpu0)));
  }

  public async getStackReport(core: Core = Core.Cpu0): Promise<StackReport> {
    return decodeStackReport(await this.call(Method.Stack, encodeCoreOnly(core)));
  }

  public async getFolded(
    core: Core = Core.Cpu0,
    thread = 0xffffffff,
    fromNs = 0n,
    toNs = 0xffffffffffffffffn
  ): Promise<string> {
    return decodeTextSlice(await this.call(Method.Folded, encodeFoldedAsk(core, thread, fromNs, toNs)));
  }

  public async getBoardParts(): Promise<BoardParts> {
    return decodeBoardParts(await this.call(Method.BoardParts, encodeCoreOnly(Core.Cpu0)));
  }

  public async getListParts(core: Core = Core.Cpu0): Promise<string[]> {
    const text = decodeTextSlice(await this.call(Method.ListParts, encodeCoreOnly(core))).trim();
    return text.length > 0 ? text.split("\n").filter((line) => line.trim().length > 0) : [];
  }

  public setCameraSource(text: string, allowWebcam = false): Promise<boolean> {
    return this.ack(Method.SetCameraSource, encodeCameraSource(text, allowWebcam));
  }

  public async getRtc(core: Core = Core.Cpu0): Promise<RtcReport> {
    return decodeRtcReport(await this.call(Method.Rtc, encodeCoreOnly(core)));
  }

  public sendInput(args: ScheduleInputArgs): Promise<boolean> {
    return this.ack(Method.Input, encodeScheduleInput(args));
  }

  public sendConsoleInput(core: Core, bytes: Uint8Array): Promise<boolean> {
    return this.ack(Method.ConsoleInput, encodeConsoleInput(core, bytes));
  }

  public plug(spec: string, core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.Plug, encodePartSpec(spec, core));
  }

  public unplug(endpoint: string, core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.Unplug, encodePartSpec(endpoint, core));
  }

  public setFault(rule: string, core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.SetFault, encodePartSpec(rule, core));
  }

  public clearFault(endpoint: string, core: Core = Core.Cpu0): Promise<boolean> {
    return this.ack(Method.ClearFault, encodePartSpec(endpoint, core));
  }

  public snapshot(bareName: string): Promise<boolean> {
    return this.ack(Method.Snapshot, encodeStatePath(bareName));
  }

  public restore(bareName: string): Promise<boolean> {
    return this.ack(Method.Restore, encodeStatePath(bareName));
  }
}
