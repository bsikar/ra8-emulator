import { ChangeDetectionStrategy, Component, computed, effect, inject, input, output, signal } from '@angular/core';
import type { DiffPageItem, DiffSide } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { RewindStore } from '../../core/stores/rewind.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatHex32 } from '../../shared/utils/hex';
import {
  formatChangedMask,
  formatDiffPageHash,
  formatDiffPageStatus,
  formatDiffSideLabel,
  formatHexOffset,
} from './rewind-model';

type DiffCategoryTab = 'all' | 'regs' | 'pages' | 'periphs';

@Component({
  selector: 'app-rewind-diff-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './rewind-diff-pane.component.html',
  styleUrl: './rewind-diff-pane.component.css',
})
export class RewindDiffPaneComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);

  public readonly pointA = input<string>('0');
  public readonly pointB = input<string>('latest');
  public readonly pointsChanged = output<{ pointA: string; pointB: string }>();

  protected readonly pointADraft = signal<string>('0');
  protected readonly pointBDraft = signal<string>('latest');
  protected readonly activeTab = signal<DiffCategoryTab>('all');

  protected readonly regs = computed(() => this.rewind.activeDiff()?.regs ?? []);
  protected readonly pages = computed(() => this.rewind.activeDiff()?.pages ?? []);
  protected readonly periphs = computed(() => this.rewind.activeDiff()?.periphs ?? []);
  protected readonly totalCount = computed(
    () => this.regs().length + this.pages().length + this.periphs().length
  );

  constructor() {
    effect(() => {
      this.pointADraft.set(this.pointA());
      this.pointBDraft.set(this.pointB());
    });
  }

  protected hex32(val: number): string {
    return formatHex32(val);
  }

  protected hexOffset(offset: number): string {
    return formatHexOffset(offset);
  }

  protected hexMask(mask: number): string {
    return formatChangedMask(mask);
  }

  protected pageStatus(page: DiffPageItem): string {
    return formatDiffPageStatus(page);
  }

  protected pageHash(page: DiffPageItem): string {
    return formatDiffPageHash(page);
  }

  protected formatSide(side: DiffSide): string {
    return formatDiffSideLabel(side);
  }

  protected onPointAInput(event: Event): void {
    this.pointADraft.set((event.target as HTMLInputElement).value);
  }

  protected onPointBInput(event: Event): void {
    this.pointBDraft.set((event.target as HTMLInputElement).value);
  }

  protected async onSwapPoints(): Promise<void> {
    const prevA = this.pointADraft().trim() || '0';
    const prevB = this.pointBDraft().trim() || 'latest';
    this.pointADraft.set(prevB);
    this.pointBDraft.set(prevA);
    this.pointsChanged.emit({ pointA: prevB, pointB: prevA });
    if (this.rpc.isConnected()) {
      await this.rewind.compareDiff(prevB, prevA);
    }
  }

  protected async onCompareSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const a = this.pointADraft().trim() || '0';
    const b = this.pointBDraft().trim() || 'latest';
    this.pointsChanged.emit({ pointA: a, pointB: b });
    await this.rewind.compareDiff(a, b);
  }
}
