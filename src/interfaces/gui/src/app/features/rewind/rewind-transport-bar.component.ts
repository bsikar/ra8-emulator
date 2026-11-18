import { ChangeDetectionStrategy, Component, inject, output, signal } from '@angular/core';
import { CAP_ARTIFACTS, Direction, NavQueryKind, type NavQueryResult } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { DebugStore } from '../../core/stores/debug.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { normalizeSeekTarget } from '../../core/stores/rewind-helpers';
import { formatHex32 } from '../../shared/utils/hex';
import {
  type RewindBookmark,
  advanceRewind,
  exportRewindBundle,
  forkReasonLabel,
  pauseRewind,
  stepBackRewind,
  stepForwardRewind,
} from './rewind-model';

@Component({
  selector: 'app-rewind-transport-bar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './rewind-transport-bar.component.html',
  styleUrl: './rewind-transport-bar.component.css',
})
export class RewindTransportBarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);
  private readonly execution = inject(ExecutionStore);
  private readonly debug = inject(DebugStore);

  public readonly bookmarkCreated = output<RewindBookmark>();

  protected readonly dirBack = Direction.Back;
  protected readonly dirFwd = Direction.Fwd;
  protected readonly speedPreset = signal<string>('1000');
  protected readonly seekDraft = signal<string>('');
  protected readonly bookmarkBarOpen = signal<boolean>(false);
  protected readonly navKind = signal<'frame' | 'iter' | 'isr' | 'rtos' | 'marker'>('iter');
  protected readonly navArg = signal<string>('0');
  protected readonly markerName = signal<string>('');
  protected readonly markerPlace = signal<string>('');

  protected canEdit(): boolean {
    return this.rpc.isConnected() && !this.rpc.observeOnly();
  }

  protected canExport(): boolean {
    return this.rpc.isConnected() && this.rpc.hasCapability(CAP_ARTIFACTS);
  }

  protected toggleBookmarkBar(): void {
    const next = !this.bookmarkBarOpen();
    this.bookmarkBarOpen.set(next);
    if (next && !this.markerPlace().trim()) {
      const pc = this.debug.registers()['pc'];
      if (pc !== undefined) this.markerPlace.set(formatHex32(pc));
    }
  }

  protected onStepBack(): void {
    void stepBackRewind(this.execution, this.rewind);
  }

  protected onPause(): void {
    void pauseRewind(this.execution, this.rewind, this.rpc);
  }

  protected onStepForward(): void {
    void stepForwardRewind(this.execution, this.rewind);
  }

  protected onAdvanceSlice(): void {
    void advanceRewind(this.rpc, this.execution, this.rewind);
  }

  protected onExportBundle(): void {
    void exportRewindBundle(this.rewind, this.rpc);
  }

  protected seekOrigin(): void {
    const live = this.rewind.branches().find((b) => b.isLive);
    void this.rewind.seekPoint(live?.id ?? 0, 0);
  }

  protected speedMilli(): bigint {
    return BigInt(Number.parseInt(this.speedPreset(), 10) || 1000);
  }

  protected onSpeedChange(event: Event): void {
    this.speedPreset.set((event.target as HTMLSelectElement).value);
  }

  protected onSeekInput(event: Event): void {
    this.seekDraft.set((event.target as HTMLInputElement).value);
  }

  protected onSeekSubmit(event: Event): void {
    event.preventDefault();
    const norm = normalizeSeekTarget(this.seekDraft());
    if (norm) void this.rewind.seekTo(norm);
  }

  protected onNavKindChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'frame' || val === 'iter' || val === 'isr' || val === 'rtos' || val === 'marker') {
      this.navKind.set(val);
    }
  }

  protected onNavArgInput(event: Event): void {
    this.navArg.set((event.target as HTMLInputElement).value);
  }

  protected onNavSubmit(event: Event): void {
    event.preventDefault();
    const raw = this.navArg().trim();
    const kindMap: Record<string, NavQueryKind> = {
      frame: NavQueryKind.Frame,
      iter: NavQueryKind.Iteration,
      isr: NavQueryKind.Isr,
      rtos: NavQueryKind.Rtos,
      marker: NavQueryKind.Marker,
    };
    const kind = kindMap[this.navKind()] ?? NavQueryKind.Iteration;
    const isNumeric = /^\d+$/.test(raw);
    void this.rewind.navQuery({
      kind,
      index: isNumeric ? BigInt(raw) : 0n,
      name: isNumeric ? undefined : raw,
    });
  }

  protected formatNavSummary(nav: NavQueryResult): string {
    if (!nav.found) return `0 hits (${nav.count.toString()} total)`;
    return `b${nav.branch}:r${nav.r.toString()} · ${nav.count.toString()} hits`;
  }

  protected forkPromptText(): string {
    const st = this.rewind.forkStatus();
    if (!st) {
      return 'Target stopped at historical state. Confirm counterfactual branch fork before continuing or writing state?';
    }
    return `Historical position b${st.branch}:r${st.r.toString()} (${forkReasonLabel(st.reason)}). Confirm counterfactual fork?`;
  }

  protected onMarkerNameInput(event: Event): void {
    this.markerName.set((event.target as HTMLInputElement).value);
  }

  protected onMarkerPlaceInput(event: Event): void {
    this.markerPlace.set((event.target as HTMLInputElement).value);
  }

  protected async onMarkerSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const name = this.markerName().trim();
    const place = this.markerPlace().trim();
    if (!name || !place) return;
    const res = await this.rewind.setMarker(name, place);
    if (!res) return;
    if (res.found) {
      this.bookmarkCreated.emit({
        name,
        place,
        branch: res.branch,
        r: res.r,
        virtualNs: res.virtualNs,
        count: res.count,
      });
      this.markerName.set('');
      this.rpc.pushToast(`Bookmark "${name}" set (${res.count.toString()} arrivals)`);
    } else {
      this.rpc.pushToast(`Marker "${name}" recorded 0 hits at ${place}`, 'neutral');
    }
  }
}
