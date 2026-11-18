import { Injectable, computed, inject, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { mergeFoldedTexts } from './profile-hotspots';
import { type TimelineCoreFilter, formatTimelineNs } from './timeline-model';

export const ALL_THREADS_FILTER = 0xffff_ffff;
const FULL_START_NS = 0n;
const FULL_END_NS = 0xffff_ffff_ffff_ffffn;

export interface ThreadFilterOption {
  thread: number;
  label: string;
}

@Injectable({ providedIn: 'root' })
export class ProfileViewService {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly profile = inject(ProfileStore);

  public readonly coreFilter = signal<TimelineCoreFilter>('cpu0');
  public readonly threadFilter = signal<number>(ALL_THREADS_FILTER);
  public readonly brushRange = signal<{ fromNs: bigint; toNs: bigint } | null>(null);
  public readonly resetViewNonce = signal<number>(0);

  public readonly activeCaptureCore = computed<Core>(() =>
    this.coreFilter() === 'cpu1' && this.execution.cpu1Attached() ? Core.Cpu1 : Core.Cpu0
  );

  public readonly threadOptions = computed<ThreadFilterOption[]>(() => {
    const seen = new Map<number, string>();
    for (const task of this.profile.rtosTasks()) {
      if (task.thread !== 0 && !seen.has(task.thread)) {
        seen.set(task.thread, task.name);
      }
    }
    return Array.from(seen.entries()).map(([thread, name]) => ({
      thread,
      label: `${name} (0x${thread.toString(16)})`,
    }));
  });

  public readonly brushSummary = computed<string>(() => {
    const samples = this.profile.flamegraph().totalSamples;
    const brush = this.brushRange();
    if (!brush) return `Full Run (${samples} samples)`;
    return `${formatTimelineNs(brush.fromNs)} – ${formatTimelineNs(brush.toNs)} (${samples} samples)`;
  });

  public async selectCoreFilter(filter: TimelineCoreFilter): Promise<void> {
    if (filter === 'cpu1' && !this.execution.cpu1Attached()) return;
    this.coreFilter.set(filter);
    if (this.rpc.isConnected()) await this.captureActiveWindow();
  }

  public async selectThreadFilter(thread: number): Promise<void> {
    this.threadFilter.set(thread);
    if (this.rpc.isConnected()) await this.captureActiveWindow();
  }

  public async setBrushRange(
    range: { fromNs: bigint; toNs: bigint } | null,
    autoCapture = true
  ): Promise<void> {
    this.brushRange.set(range);
    if (autoCapture && this.rpc.isConnected()) await this.captureActiveWindow();
  }

  public async resetToFullRun(): Promise<void> {
    this.brushRange.set(null);
    this.resetViewNonce.update((n) => n + 1);
    if (this.rpc.isConnected()) await this.captureActiveWindow();
  }

  public async captureActiveWindow(): Promise<string> {
    const brush = this.brushRange();
    const fromNs = brush ? brush.fromNs : FULL_START_NS;
    const toNs = brush ? brush.toNs : FULL_END_NS;
    const thread = this.threadFilter();
    const filter = this.coreFilter();

    if (filter === 'both' && this.execution.cpu1Attached()) {
      const client = this.rpc.activeClient;
      if (!client) return '';
      const [c0, c1] = await Promise.all([
        this.safeGetFolded(() => client.getFolded(Core.Cpu0, thread, fromNs, toNs)),
        this.safeGetFolded(() => client.getFolded(Core.Cpu1, thread, fromNs, toNs)),
      ]);
      const merged = mergeFoldedTexts(c0, c1);
      this.profile.foldedText.set(merged);
      return merged;
    }

    const core = filter === 'cpu1' ? Core.Cpu1 : Core.Cpu0;
    return this.profile.captureFolded(core, thread, fromNs, toNs);
  }

  public async exportFolded(): Promise<boolean> {
    let text = this.profile.foldedText();
    if (!text.trim() && this.rpc.isConnected()) {
      text = await this.captureActiveWindow();
    }
    if (!text.trim()) {
      this.rpc.pushToast('No folded stack samples to export', 'neutral');
      return false;
    }
    if (typeof URL.createObjectURL === 'function' && typeof document !== 'undefined') {
      const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = `ra8-profile-${this.coreFilter()}.folded`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      if (typeof URL.revokeObjectURL === 'function') URL.revokeObjectURL(url);
    }
    this.rpc.pushToast(`Exported ra8-profile-${this.coreFilter()}.folded`);
    return true;
  }

  public clearAll(): void {
    this.profile.clear();
    this.brushRange.set(null);
    this.threadFilter.set(ALL_THREADS_FILTER);
    this.resetViewNonce.update((n) => n + 1);
  }

  private async safeGetFolded(fn: () => Promise<string>): Promise<string> {
    try {
      return await fn();
    } catch (err) {
      this.rpc.noteOptionalError(err, 'Folded profile unavailable');
      return '';
    }
  }
}
