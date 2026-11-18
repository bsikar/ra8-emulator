import { ChangeDetectionStrategy, Component, computed, inject, input, signal } from '@angular/core';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import {
  type RewindBookmark,
  forkReasonLabel,
  restoreNamedSnapshot,
  saveNamedSnapshot,
} from './rewind-model';

@Component({
  selector: 'app-rewind-branch-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './rewind-branch-sidebar.component.html',
  styleUrl: './rewind-branch-sidebar.component.css',
})
export class RewindBranchSidebarComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);
  private readonly execution = inject(ExecutionStore);

  public readonly bookmarks = input<readonly RewindBookmark[]>([]);
  protected readonly snapName = signal<string>('checkpoint.ra8snap');
  protected readonly reasonLabel = forkReasonLabel;

  protected readonly activeBranchLabel = computed(() => {
    const live = this.rewind.branches().find((b) => b.isLive) ?? this.rewind.branches()[0];
    if (!live) return 'No active branch';
    return `#${live.id} · r${live.recordedEndR.toString()}`;
  });

  protected formatBytes(bytes: bigint): string {
    const num = Number(bytes);
    if (num >= 1024 * 1024) return `${(num / (1024 * 1024)).toFixed(1)} MiB`;
    return `${Math.round(num / 1024)} KiB`;
  }

  protected canEdit(): boolean {
    return this.rpc.isConnected() && !this.rpc.observeOnly();
  }

  protected onSnapInput(event: Event): void {
    this.snapName.set((event.target as HTMLInputElement).value);
  }

  protected saveSnap(): void {
    void saveNamedSnapshot(this.rpc, this.snapName());
  }

  protected restoreSnap(): void {
    void restoreNamedSnapshot(this.rpc, this.rewind, this.snapName(), this.execution);
  }
}
