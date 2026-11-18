import {
  AfterViewInit,
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  OnDestroy,
  computed,
  effect,
  inject,
  input,
  output,
  signal,
  viewChild,
} from '@angular/core';
import { RewindStore } from '../../core/stores/rewind.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { get2dContext, observeHiDpiCanvas, resolveDevicePixelRatio } from '../../shared/utils/hidpi-canvas';
import { type RewindLayoutMode } from '../../shared/utils/rewind-layout';
import {
  type RewindBookmark,
  buildDagLayoutFromBranches,
  drawRewindDag,
  hitTestRewindNode,
} from './rewind-model';

@Component({
  selector: 'app-rewind-dag-canvas',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="dag-pane">
      <div class="dag-head">
        <div class="head-left">
          <app-section-kicker label="BRANCH DAG" />
          <span class="es-meta">Click node to seek · Shift+Click to diff</span>
        </div>
        <div class="mode-grp">
          <button type="button" class="mini-btn" [class.is-active]="layoutMode() === 'spine'" data-testid="rewind-layout-spine" (click)="layoutMode.set('spine')">Spine: Center ±Y</button>
          <button type="button" class="mini-btn" [class.is-active]="layoutMode() === 'waterfall'" data-testid="rewind-layout-waterfall" (click)="layoutMode.set('waterfall')">Waterfall</button>
        </div>
      </div>

      <div class="canvas-box">
        <canvas #dagCanvas class="dag-canvas" data-testid="rewind-dag-canvas" (click)="onCanvasClick($event)"></canvas>
      </div>

      <div class="node-strip">
        @for (node of dagLayout().nodes; track node.id + ':' + $index) {
          <button
            type="button"
            class="node-chip mono"
            [class.is-cursor]="node.isCursor"
            [attr.data-testid]="'rewind-node-' + $index"
            (click)="onNodeChipClick($event, node.branch, node.round, node.id)"
          >
            {{ node.label }}
          </button>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .dag-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .dag-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .head-left, .mode-grp, .node-strip { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .canvas-box { flex: 1; min-height: 120px; position: relative; overflow: hidden; }
      .dag-canvas { width: 100%; height: 100%; display: block; cursor: pointer; }
      .node-strip { padding: 6px 12px; border-top: 1px solid var(--es-divider); background: var(--es-chrome); }
      .mini-btn, .node-chip { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn.is-active, .node-chip.is-cursor { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
    `,
  ],
})
export class RewindDagCanvasComponent implements AfterViewInit, OnDestroy {
  protected readonly rewind = inject(RewindStore);

  public readonly bookmarks = input<readonly RewindBookmark[]>([]);
  public readonly pointASelected = input<string>('0');
  public readonly pointBSelected = input<string>('latest');
  public readonly diffPairRequested = output<{ pointA: string; pointB: string }>();

  private readonly dagCanvas = viewChild<ElementRef<HTMLCanvasElement>>('dagCanvas');
  private stopObserver: (() => void) | null = null;
  protected readonly layoutMode = signal<RewindLayoutMode>('spine');
  protected readonly dagLayout = computed(() =>
    buildDagLayoutFromBranches(this.rewind.branches(), this.bookmarks(), this.layoutMode())
  );

  constructor() {
    effect(() => {
      const layout = this.dagLayout();
      const ptA = this.pointASelected();
      const ptB = this.pointBSelected();
      this.redraw(layout, ptA, ptB);
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    this.stopObserver = observeHiDpiCanvas(canvas, () =>
      this.redraw(this.dagLayout(), this.pointASelected(), this.pointBSelected())
    );
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
  }

  protected onCanvasClick(event: MouseEvent): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const hit = hitTestRewindNode(this.dagLayout(), event.clientX - rect.left, event.clientY - rect.top);
    if (!hit) return;
    this.handleNodeSelect(event.shiftKey, hit.branch, hit.round, hit.id);
  }

  protected onNodeChipClick(event: MouseEvent, branch: number, round: number, nodeId: string): void {
    this.handleNodeSelect(event.shiftKey, branch, round, nodeId);
  }

  private handleNodeSelect(shiftKey: boolean, branch: number, round: number, nodeId: string): void {
    if (shiftKey) {
      this.diffPairRequested.emit({ pointA: this.pointASelected(), pointB: nodeId });
    } else {
      void this.rewind.seekPoint(branch, round);
    }
  }

  private redraw(layout = this.dagLayout(), ptA = this.pointASelected(), ptB = this.pointBSelected()): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    const ctx = get2dContext(canvas);
    if (!ctx) return;
    const dpr = resolveDevicePixelRatio();
    const cssW = Math.max(1, canvas.clientWidth || Math.round(canvas.width / dpr));
    const cssH = Math.max(1, canvas.clientHeight || Math.round(canvas.height / dpr));
    drawRewindDag(ctx, layout, cssW, cssH, dpr, ptA, ptB);
  }
}
