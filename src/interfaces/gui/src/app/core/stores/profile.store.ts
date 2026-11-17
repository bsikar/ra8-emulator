import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import { Core, EventKind, type MetricsReport, type StackReport, type TraceEvent } from 'ra8-rpc-client';
import { type FlamegraphView, parseFoldedStacks } from '../../shared/utils/flamegraph';
import { type StackMetrics, computeStackMetrics } from '../../shared/utils/stack-math';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export const MAX_TRACE_ENTRIES = 512;

export interface TraceTimelineEntry {
  id: number;
  core: Core;
  kind: EventKind;
  virtualNs: bigint;
  thread: number;
  exception: number;
  name: string;
}

export interface RtosTaskSummary {
  key: string;
  core: Core;
  thread: number;
  name: string;
  switches: number;
  sharePercent: number;
}

@Injectable({ providedIn: 'root' })
export class ProfileStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly subs = new Subscription();
  private metricsTimer: ReturnType<typeof setInterval> | null = null;
  private lastVirtualNsSample: bigint | null = null;
  private lastWallMsSample: number | null = null;
  private nextTraceId = 1;

  public readonly metrics = signal<MetricsReport | null>(null);
  public readonly cpu0Stack = signal<StackReport | null>(null);
  public readonly cpu1Stack = signal<StackReport | null>(null);
  public readonly traceTimeline = signal<TraceTimelineEntry[]>([]);
  public readonly foldedText = signal<string>('');
  public readonly hostCpuHistory = signal<number[]>([]);
  public readonly hostRssHistory = signal<number[]>([]);
  public readonly pacingRatio = signal<number | null>(null);

  public readonly cpu0StackMetrics = computed<StackMetrics>(() => computeStackMetrics(this.cpu0Stack()));
  public readonly cpu1StackMetrics = computed<StackMetrics>(() => computeStackMetrics(this.cpu1Stack()));
  public readonly flamegraph = computed<FlamegraphView>(() => parseFoldedStacks(this.foldedText()));

  public readonly rtosTasks = computed<RtosTaskSummary[]>(() => {
    const counts = new Map<string, { core: Core; thread: number; name: string; count: number }>();
    let total = 0;
    for (const evt of this.traceTimeline()) {
      if (evt.kind !== EventKind.RtosSwitch && evt.kind !== EventKind.RtosIdle) continue;
      const name = evt.kind === EventKind.RtosIdle ? 'IDLE' : evt.name || `Thread 0x${evt.thread.toString(16)}`;
      const key = `${evt.core}:${name}`;
      const existing = counts.get(key) ?? { core: evt.core, thread: evt.thread, name, count: 0 };
      existing.count += 1;
      counts.set(key, existing);
      total += 1;
    }
    return Array.from(counts.entries())
      .map(([key, item]) => ({
        key,
        core: item.core,
        thread: item.thread,
        name: item.name,
        switches: item.count,
        sharePercent: total > 0 ? Math.round((item.count * 100) / total) : 0,
      }))
      .sort((a, b) => b.switches - a.switches)
      .slice(0, 12);
  });

  constructor() {
    this.subs.add(this.rpc.trace$.subscribe((evt) => this.pushTraceEvent(evt)));
    this.subs.add(this.rpc.disconnected$.subscribe(() => this.stopMetricsPoll()));
  }

  public pushTraceEvent(evt: TraceEvent): void {
    const entry: TraceTimelineEntry = {
      id: this.nextTraceId++,
      core: evt.core,
      kind: evt.kind,
      virtualNs: evt.virtualNs,
      thread: evt.thread,
      exception: evt.exception,
      name: evt.name,
    };
    this.traceTimeline.update((prev) =>
      prev.length >= MAX_TRACE_ENTRIES
        ? [...prev.slice(prev.length - MAX_TRACE_ENTRIES + 1), entry]
        : [...prev, entry]
    );
  }

  public async refreshMetrics(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const [report, vns] = await Promise.all([client.getMetrics(), client.now(Core.Cpu0)]);
      this.metrics.set(report);
      this.recordPacing(vns);
      this.hostCpuHistory.update((arr) => [...arr.slice(-59), report.hostCpuPercent]);
      this.hostRssHistory.update((arr) => [...arr.slice(-59), report.hostRssMb]);
    } catch (err) {
      this.rpc.reportError('Metrics refresh failed', err);
    }
  }

  public async refreshStacks(cpu1Attached = false): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.cpu0Stack.set(await client.getStackReport(Core.Cpu0));
    } catch (err) {
      this.rpc.reportError('CPU0 stack report failed', err);
    }
    if (cpu1Attached) {
      try {
        this.cpu1Stack.set(await client.getStackReport(Core.Cpu1));
      } catch (err) {
        this.rpc.reportError('CPU1 stack report failed', err);
      }
    }
  }

  public async captureFolded(
    core: Core = Core.Cpu0,
    thread = 0xffff_ffff,
    fromNs = 0n,
    toNs = 0xffff_ffff_ffff_ffffn
  ): Promise<string> {
    const client = this.rpc.activeClient;
    if (!client) return '';
    try {
      const folded = await client.getFolded(core, thread, fromNs, toNs);
      this.foldedText.set(folded);
      return folded;
    } catch (err) {
      this.rpc.reportError('Folded profile unavailable', err);
      return '';
    }
  }

  public startMetricsPoll(intervalMs = 1000): void {
    this.stopMetricsPoll();
    this.metricsTimer = setInterval(() => {
      void this.refreshMetrics();
    }, intervalMs);
  }

  public stopMetricsPoll(): void {
    if (this.metricsTimer) {
      clearInterval(this.metricsTimer);
      this.metricsTimer = null;
    }
  }

  public clear(): void {
    this.metrics.set(null);
    this.cpu0Stack.set(null);
    this.cpu1Stack.set(null);
    this.traceTimeline.set([]);
    this.foldedText.set('');
    this.hostCpuHistory.set([]);
    this.hostRssHistory.set([]);
    this.pacingRatio.set(null);
    this.lastVirtualNsSample = null;
    this.lastWallMsSample = null;
  }

  public ngOnDestroy(): void {
    this.stopMetricsPoll();
    this.subs.unsubscribe();
  }

  private recordPacing(vns: bigint): void {
    const wallMs = typeof performance !== 'undefined' ? performance.now() : Date.now();
    if (this.lastVirtualNsSample !== null && this.lastWallMsSample !== null) {
      const dVirt = Number(vns - this.lastVirtualNsSample);
      const dWall = (wallMs - this.lastWallMsSample) * 1_000_000;
      if (dWall > 0 && dVirt >= 0) this.pacingRatio.set(dVirt / dWall);
    }
    this.lastVirtualNsSample = vns;
    this.lastWallMsSample = wallMs;
  }
}
