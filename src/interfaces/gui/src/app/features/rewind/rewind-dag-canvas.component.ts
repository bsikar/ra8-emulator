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
import { type RewindLayoutMode, type RewindLayoutNode } from '../../shared/utils/rewind-layout';
import { resolveDagPins } from './rewind-dag-render';
import {
  type RewindBookmark,
  buildDagLayoutFromBranches,
  computeDiffSummary,
  drawRewindDag,
  hitTestRewindNode,
} from './rewind-model';

const LAYOUT_MODE_KEY = 'ra8.rewindLayout.v1';

function loadSavedLayoutMode(): RewindLayoutMode {
  if (typeof localStorage === 'undefined') return 'spine';
  try {
    return localStorage.getItem(LAYOUT_MODE_KEY) === 'waterfall' ? 'waterfall' : 'spine';
  } catch (err) {
    void err;
    return 'spine';
  }
}

@Component({
  selector: 'app-rewind-dag-canvas',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './rewind-dag-canvas.component.html',
  styleUrl: './rewind-dag-canvas.component.css',
})
export class RewindDagCanvasComponent implements AfterViewInit, OnDestroy {
  protected readonly rewind = inject(RewindStore);

  public readonly bookmarks = input<readonly RewindBookmark[]>([]);
  public readonly pointASelected = input<string>('0');
  public readonly pointBSelected = input<string>('latest');
  public readonly diffPairRequested = output<{ pointA: string; pointB: string }>();

  private readonly dagCanvas = viewChild<ElementRef<HTMLCanvasElement>>('dagCanvas');
  private stopObserver: (() => void) | null = null;
  protected readonly layoutMode = signal<RewindLayoutMode>(loadSavedLayoutMode());
  protected readonly clickAction = signal<'seek' | 'pinA' | 'pinB'>('seek');

  protected readonly dagLayout = computed(() =>
    buildDagLayoutFromBranches(this.rewind.branches(), this.bookmarks(), this.layoutMode())
  );

  protected readonly resolvedPins = computed(() =>
    resolveDagPins(this.dagLayout(), this.pointASelected(), this.pointBSelected())
  );

  protected readonly summary = computed(() =>
    computeDiffSummary(this.rewind.activeDiff(), this.rewind.branches(), this.rewind.frameStatus())
  );

  constructor() {
    effect(() => {
      const layout = this.dagLayout();
      const ptA = this.pointASelected();
      const ptB = this.pointBSelected();
      const bms = this.bookmarks();
      this.redraw(layout, ptA, ptB, bms);
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    this.stopObserver = observeHiDpiCanvas(canvas, () =>
      this.redraw(this.dagLayout(), this.pointASelected(), this.pointBSelected(), this.bookmarks())
    );
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
  }

  protected setLayoutMode(mode: RewindLayoutMode): void {
    this.layoutMode.set(mode);
    if (typeof localStorage !== 'undefined') {
      try {
        localStorage.setItem(LAYOUT_MODE_KEY, mode);
      } catch (err) {
        void err;
      }
    }
  }

  protected isPinNode(nodeId: string): boolean {
    const pins = this.resolvedPins();
    return pins.pointANode?.id === nodeId || pins.pointBNode?.id === nodeId;
  }

  protected formatNodeChip(node: RewindLayoutNode): string {
    const pins = this.resolvedPins();
    const tags: string[] = [];
    if (pins.pointANode?.id === node.id) tags.push('A');
    if (pins.pointBNode?.id === node.id) tags.push('B');
    const prefix = tags.length > 0 ? `[${tags.join('/')}] ` : '◆ ';
    return `${prefix}${node.label}`;
  }

  protected onCanvasClick(event: MouseEvent): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const hit = hitTestRewindNode(
      this.dagLayout(),
      event.clientX - rect.left,
      event.clientY - rect.top,
      rect.width,
      rect.height
    );
    if (!hit) return;
    this.handleNodeSelect(event.shiftKey, hit.branch, hit.round, hit.id);
  }

  protected onNodeChipClick(event: MouseEvent, branch: number, round: number, nodeId: string): void {
    this.handleNodeSelect(event.shiftKey, branch, round, nodeId);
  }

  private handleNodeSelect(shiftKey: boolean, branch: number, round: number, nodeId: string): void {
    const mode = this.clickAction();
    if (shiftKey || mode === 'pinB') {
      this.diffPairRequested.emit({ pointA: this.pointASelected(), pointB: nodeId });
      return;
    }
    if (mode === 'pinA') {
      this.diffPairRequested.emit({ pointA: nodeId, pointB: this.pointBSelected() });
      return;
    }
    void this.rewind.seekPoint(branch, round);
  }

  private redraw(
    layout = this.dagLayout(),
    ptA = this.pointASelected(),
    ptB = this.pointBSelected(),
    bms = this.bookmarks()
  ): void {
    const canvas = this.dagCanvas()?.nativeElement;
    if (!canvas) return;
    const ctx = get2dContext(canvas);
    if (!ctx) return;
    const dpr = resolveDevicePixelRatio();
    const cssW = Math.max(1, canvas.clientWidth || Math.round(canvas.width / dpr));
    const cssH = Math.max(1, canvas.clientHeight || Math.round(canvas.height / dpr));
    drawRewindDag(ctx, layout, cssW, cssH, dpr, ptA, ptB, bms);
  }
}
