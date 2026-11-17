import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import {
  CAP_TRANSPORT,
  Core,
  RunMode,
  StopReason,
  type Stopped,
  type TransportEvent,
} from 'ra8-rpc-client';
import { formatVirtualTime } from '../../shared/utils/hex';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export type ExecutionStatus = 'stopped' | 'running' | 'halted';

const SLICE_BUDGET_INSTR = 250_000n;
const ASYNC_SLICE_NS = 16_000_000n;

@Injectable({ providedIn: 'root' })
export class ExecutionStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly subs = new Subscription();
  private continuousWanted = false;
  private sliceInFlight = false;

  public readonly executionStatus = signal<ExecutionStatus>('stopped');
  public readonly activeCore = signal<Core>(Core.Cpu0);
  public readonly cpu1Attached = signal<boolean>(false);
  public readonly virtualTimeNs = signal<bigint>(0n);
  public readonly speedMilli = signal<number>(0);
  public readonly lastStop = signal<Stopped | null>(null);
  public readonly inspectionEpoch = signal<number>(0);

  public readonly virtualTimeLabel = computed(() => formatVirtualTime(this.virtualTimeNs()));
  public readonly isRunning = computed(() => this.executionStatus() === 'running');

  constructor() {
    this.subs.add(this.rpc.connected$.subscribe(() => void this.onConnected()));
    this.subs.add(this.rpc.disconnected$.subscribe(() => this.onDisconnected()));
    this.subs.add(this.rpc.stop$.subscribe((evt) => this.handleStop(evt)));
    this.subs.add(this.rpc.transport$.subscribe((evt) => this.handleTransport(evt)));
  }

  public async run(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client || this.continuousWanted) return;
    this.lastStop.set(null);
    this.continuousWanted = true;
    this.executionStatus.set('running');
    await this.pumpNextSlice();
  }

  public async pause(): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.interrupt(Core.Cpu0);
    } catch (err) {
      this.rpc.noteOptionalError(err, 'Interrupt note');
    }
    try {
      await client.pause(Core.Cpu0);
      if (this.cpu1Attached()) {
        await client.pause(Core.Cpu1);
      }
    } catch (err) {
      this.rpc.reportError('Pause failed', err);
    }
    this.executionStatus.set('halted');
    await this.refreshClock();
    this.inspectionEpoch.update((n) => n + 1);
  }

  public async step(core: Core = this.activeCore()): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.lastStop.set(null);
      await client.step(core);
      this.executionStatus.set('halted');
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Step failed', err);
    }
  }

  public async stepOver(core: Core = this.activeCore()): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.lastStop.set(null);
      await client.stepOver(core);
      this.executionStatus.set('halted');
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Step over failed', err);
    }
  }

  public async stepOut(core: Core = this.activeCore()): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.lastStop.set(null);
      await client.stepOut(core);
      this.executionStatus.set('halted');
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Step out failed', err);
    }
  }

  public async reverseContinue(core: Core = this.activeCore()): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.reverseContinue(core);
      this.executionStatus.set('halted');
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Reverse continue unavailable', err);
    }
  }

  public async skipBkpt(core: Core = this.activeCore()): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.skipBreakpoint(core);
      this.lastStop.set(null);
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Skip BKPT failed', err);
    }
  }

  public async resetImage(): Promise<void> {
    this.continuousWanted = false;
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.resetImage(Core.Cpu0);
      this.lastStop.set(null);
      this.executionStatus.set('halted');
      await this.refreshClock();
      this.inspectionEpoch.update((n) => n + 1);
    } catch (err) {
      this.rpc.reportError('Reset image failed', err);
    }
  }

  public async setSpeed(milli: number): Promise<void> {
    this.speedMilli.set(milli);
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.setSpeed(Core.Cpu0, BigInt(Math.max(0, Math.round(milli))));
    } catch (err) {
      this.rpc.reportError('Set speed failed', err);
    }
  }

  public async refreshClock(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.virtualTimeNs.set(await client.now(Core.Cpu0));
    } catch (err) {
      this.rpc.errorMessage.set(`Clock read failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  public ngOnDestroy(): void {
    this.continuousWanted = false;
    this.subs.unsubscribe();
  }

  private async onConnected(): Promise<void> {
    this.executionStatus.set('halted');
    await this.probeCpu1();
    await this.refreshClock();
    this.inspectionEpoch.update((n) => n + 1);
  }

  private onDisconnected(): void {
    this.continuousWanted = false;
    this.sliceInFlight = false;
    this.executionStatus.set('stopped');
    this.cpu1Attached.set(false);
    this.lastStop.set(null);
  }

  private async probeCpu1(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      await client.readRegister(Core.Cpu1, 0);
      this.cpu1Attached.set(true);
      await this.rpc.subscribeCoreTopics(client, Core.Cpu1);
    } catch (err) {
      this.cpu1Attached.set(false);
      this.rpc.noteOptionalError(err);
    }
  }

  private async pumpNextSlice(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client || !this.continuousWanted || this.sliceInFlight) return;
    this.sliceInFlight = true;
    try {
      if (this.rpc.hasCapability(CAP_TRANSPORT)) {
        await client.advanceAsync(Core.Cpu0, ASYNC_SLICE_NS);
      } else {
        await client.run(Core.Cpu0, RunMode.Cont, SLICE_BUDGET_INSTR);
      }
    } catch (err) {
      this.continuousWanted = false;
      this.executionStatus.set('halted');
      this.rpc.reportError('Run failed', err);
    } finally {
      this.sliceInFlight = false;
    }
  }

  private handleStop(evt: Stopped): void {
    if (evt.reason === StopReason.Count && this.continuousWanted) {
      void this.pumpNextSlice();
      return;
    }
    this.continuousWanted = false;
    if (
      evt.reason === StopReason.Breakpoint ||
      evt.reason === StopReason.Watchpoint ||
      evt.reason === StopReason.UnitBreak ||
      evt.reason === StopReason.UnitWatch ||
      evt.reason === StopReason.CoreFault ||
      evt.reason === StopReason.ReplayFailed
    ) {
      this.lastStop.set(evt);
    }
    this.executionStatus.set('halted');
    void this.refreshClock();
    this.inspectionEpoch.update((n) => n + 1);
  }

  private handleTransport(evt: TransportEvent): void {
    if (evt.reachedNs > 0n) {
      this.virtualTimeNs.set(evt.reachedNs);
    }
    if (!evt.finished) return;
    if (evt.toNs > 0n) {
      this.virtualTimeNs.set(evt.toNs);
    }
    if (evt.reason === StopReason.Count && this.continuousWanted) {
      void this.pumpNextSlice();
      return;
    }
    this.continuousWanted = false;
    this.executionStatus.set('halted');
    this.inspectionEpoch.update((n) => n + 1);
  }
}
