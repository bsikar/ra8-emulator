import { ChangeDetectionStrategy, Component, effect, inject, signal } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { RewindStore } from '../core/stores/rewind.store';
import { RewindBranchSidebarComponent } from '../features/rewind/rewind-branch-sidebar.component';
import { RewindDagCanvasComponent } from '../features/rewind/rewind-dag-canvas.component';
import { RewindDiffPaneComponent } from '../features/rewind/rewind-diff-pane.component';
import { type RewindBookmark } from '../features/rewind/rewind-model';
import { RewindTransportBarComponent } from '../features/rewind/rewind-transport-bar.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-rewind-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    SplitPaneComponent,
    RewindTransportBarComponent,
    RewindBranchSidebarComponent,
    RewindDagCanvasComponent,
    RewindDiffPaneComponent,
  ],
  template: `
    <div class="rewind-shell">
      <app-rewind-transport-bar (bookmarkCreated)="onBookmarkCreated($event)" />
      <div class="rewind-body">
        <app-split-pane primarySize="280px" persistKey="rewind-left" [minPrimaryPx]="220" [minSecondaryPx]="400">
          <app-rewind-branch-sidebar pane-primary [bookmarks]="bookmarks()" />
          <app-split-pane pane-secondary direction="vertical" primarySize="52%" persistKey="rewind-right-v" [minPrimaryPx]="180" [minSecondaryPx]="180">
            <app-rewind-dag-canvas
              pane-primary
              [bookmarks]="bookmarks()"
              [pointASelected]="pointA()"
              [pointBSelected]="pointB()"
              (diffPairRequested)="onDiffPairRequested($event)"
            />
            <app-rewind-diff-pane
              pane-secondary
              [pointA]="pointA()"
              [pointB]="pointB()"
              (pointsChanged)="onPointsChanged($event)"
            />
          </app-split-pane>
        </app-split-pane>
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; }
      .rewind-shell { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .rewind-body { flex: 1; min-height: 0; min-width: 0; }
    `,
  ],
})
export class RewindRouteComponent {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly rewind = inject(RewindStore);

  protected readonly bookmarks = signal<RewindBookmark[]>([]);
  protected readonly pointA = signal<string>('0');
  protected readonly pointB = signal<string>('latest');

  constructor() {
    effect(() => {
      if (this.rpc.isConnected()) void this.rewind.refreshBranches();
    });
  }

  protected onBookmarkCreated(bm: RewindBookmark): void {
    this.bookmarks.update((list) => [...list.filter((b) => b.name !== bm.name), bm]);
  }

  protected onPointsChanged(evt: { pointA: string; pointB: string }): void {
    this.pointA.set(evt.pointA);
    this.pointB.set(evt.pointB);
  }

  protected onDiffPairRequested(evt: { pointA: string; pointB: string }): void {
    this.pointA.set(evt.pointA);
    this.pointB.set(evt.pointB);
    if (this.rpc.isConnected()) {
      void this.rewind.compareDiff(evt.pointA, evt.pointB);
    }
  }
}
