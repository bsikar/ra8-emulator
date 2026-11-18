import {
  AfterViewInit,
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  OnDestroy,
  computed,
  effect,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { ExecutionStore } from '../../core/stores/execution.store';
import { ProfileStore } from '../../core/stores/profile.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { get2dContext, observeHiDpiCanvas, resolveDevicePixelRatio } from '../../shared/utils/hidpi-canvas';
import { ProfileViewService } from './profile-view.service';
import { drawProfileTimeline } from './timeline-canvas-render';
import {
  type ExecutionSlice,
  TIMELINE_LABEL_WIDTH,
  TIMELINE_RIGHT_PAD,
  buildExecutionSlices,
  computeWindowUtilization,
  formatTimelineNs,
  hitTestTimelineSlice,
  panTimelineWindow,
  timelineXToNs,
  timelineYToLane,
  zoomTimelineWindow,
} from './timeline-model';

const DEFAULT_HOVER_MSG = 'Drag to brush [A, B] · Shift+drag or Pan mode to pan · Wheel to zoom';

@Component({
  selector: 'app-profile-timeline-canvas',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './profile-timeline-canvas.component.html',
  styleUrl: './profile-timeline-canvas.component.css',
})
export class ProfileTimelineCanvasComponent implements AfterViewInit, OnDestroy {
  protected readonly profile = inject(ProfileStore);
  protected readonly execution = inject(ExecutionStore);
  private readonly view = inject(ProfileViewService);

  private readonly tlCanvas = viewChild<ElementRef<HTMLCanvasElement>>('tlCanvas');
  private stopObserver: (() => void) | null = null;
  private dragState:
    | { kind: 'pan'; startX: number; chartW: number; win: { startNs: bigint; endNs: bigint } }
    | { kind: 'brush'; startNs: bigint; curNs: bigint; moved: boolean }
    | null = null;

  protected readonly dragMode = signal<'brush' | 'pan'>('brush');
  protected readonly customWindow = signal<{ startNs: bigint; endNs: bigint } | null>(null);
  protected readonly fromDraft = signal<string>('0');
  protected readonly toDraft = signal<string>('1000000');
  protected readonly hoverInfo = signal<string>(DEFAULT_HOVER_MSG);
  protected readonly hoveredSlice = signal<ExecutionSlice | null>(null);
  protected readonly liveBrush = signal<{ fromNs: bigint; toNs: bigint } | null>(null);
  protected readonly tooltip = signal<{ x: number; y: number; title: string; detail: string } | null>(null);

  protected readonly built = computed(() =>
    buildExecutionSlices(this.profile.traceTimeline(), this.execution.virtualTimeNs())
  );
  protected readonly fullBounds = computed(() => {
    const u = this.built().utilization;
    const endNs = u.windowEndNs > u.windowStartNs ? u.windowEndNs : u.windowStartNs + 1000n;
    return { startNs: u.windowStartNs, endNs };
  });
  protected readonly activeWindow = computed(() => this.customWindow() ?? this.fullBounds());
  protected readonly windowUtil = computed(() => {
    const win = this.activeWindow();
    return computeWindowUtilization(this.built().slices, win.startNs, win.endNs);
  });
  protected readonly windowWidthLabel = computed(() => {
    const win = this.activeWindow();
    return formatTimelineNs(win.endNs - win.startNs);
  });
  protected readonly totalSpanLabel = computed(() => {
    const b = this.fullBounds();
    return formatTimelineNs(b.endNs - b.startNs);
  });

  constructor() {
    let lastNonce = 0;
    effect(() => {
      const nonce = this.view.resetViewNonce();
      if (nonce !== lastNonce) {
        lastNonce = nonce;
        this.customWindow.set(null);
        this.liveBrush.set(null);
      }
    });
    effect(() => {
      const brush = this.liveBrush() ?? this.view.brushRange();
      this.redraw(this.built().slices, this.activeWindow(), brush);
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    this.stopObserver = observeHiDpiCanvas(canvas, () => this.redraw());
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
  }

  protected zoom(factor: number, anchorRatio = 0.5): void {
    const win = this.activeWindow();
    const bounds = this.fullBounds();
    this.customWindow.set(
      zoomTimelineWindow(win.startNs, win.endNs, factor, anchorRatio, bounds.startNs, bounds.endNs)
    );
  }

  protected resetWindow(): void {
    this.customWindow.set(null);
  }

  protected onWheel(event: WheelEvent): void {
    event.preventDefault();
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const { labelW, chartW } = this.chartMetrics(rect.width);
    const anchor = Math.min(1, Math.max(0, (event.clientX - rect.left - labelW) / chartW));
    this.zoom(event.deltaY < 0 ? 0.75 : 1.35, anchor);
  }

  protected onPointerDown(event: PointerEvent): void {
    if (event.button !== 0 && event.button !== 1) return;
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const { labelW, chartW } = this.chartMetrics(rect.width);
    const xChart = event.clientX - rect.left - labelW;
    const win = this.activeWindow();
    const isPan = this.dragMode() === 'pan' || event.shiftKey || event.button === 1;
    if (typeof canvas.setPointerCapture === 'function') {
      try {
        canvas.setPointerCapture(event.pointerId);
      } catch (err) {
        void err;
      }
    }
    if (isPan) {
      this.dragState = { kind: 'pan', startX: event.clientX, chartW, win };
    } else {
      const startNs = timelineXToNs(xChart, chartW, win.startNs, win.endNs);
      this.dragState = { kind: 'brush', startNs, curNs: startNs, moved: false };
    }
  }

  protected onPointerMove(event: PointerEvent): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const { labelW, chartW } = this.chartMetrics(rect.width);
    const xChart = event.clientX - rect.left - labelW;
    const yCss = event.clientY - rect.top;

    if (this.dragState?.kind === 'pan') {
      const dx = event.clientX - this.dragState.startX;
      const span = Number(this.dragState.win.endNs - this.dragState.win.startNs);
      const deltaNs = BigInt(Math.round((-dx / this.dragState.chartW) * span));
      const b = this.fullBounds();
      this.customWindow.set(
        panTimelineWindow(this.dragState.win.startNs, this.dragState.win.endNs, deltaNs, b.startNs, b.endNs)
      );
      return;
    }

    if (this.dragState?.kind === 'brush') {
      const win = this.activeWindow();
      const curNs = timelineXToNs(xChart, chartW, win.startNs, win.endNs);
      this.dragState.curNs = curNs;
      if (curNs !== this.dragState.startNs) this.dragState.moved = true;
      const fromNs = curNs < this.dragState.startNs ? curNs : this.dragState.startNs;
      const toNs = curNs > this.dragState.startNs ? curNs : this.dragState.startNs;
      if (toNs > fromNs) this.liveBrush.set({ fromNs, toNs });
      return;
    }

    this.updateHover(xChart, yCss, chartW, rect.width, rect.height, event.clientX - rect.left, yCss);
  }

  protected onPointerUp(event: PointerEvent): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (canvas && typeof canvas.releasePointerCapture === 'function') {
      try {
        canvas.releasePointerCapture(event.pointerId);
      } catch (err) {
        void err;
      }
    }
    if (this.dragState?.kind === 'brush' && this.dragState.moved) {
      const fromNs = this.dragState.curNs < this.dragState.startNs ? this.dragState.curNs : this.dragState.startNs;
      const toNs = this.dragState.curNs > this.dragState.startNs ? this.dragState.curNs : this.dragState.startNs;
      if (toNs > fromNs) {
        this.fromDraft.set(fromNs.toString());
        this.toDraft.set(toNs.toString());
        void this.view.setBrushRange({ fromNs, toNs }, true);
      }
    }
    this.liveBrush.set(null);
    this.dragState = null;
  }

  protected onPointerCancel(): void {
    this.liveBrush.set(null);
    this.dragState = null;
  }

  protected onPointerLeave(): void {
    this.hoveredSlice.set(null);
    this.tooltip.set(null);
    this.hoverInfo.set(DEFAULT_HOVER_MSG);
  }

  protected onFromInput(event: Event): void {
    this.fromDraft.set((event.target as HTMLInputElement).value);
  }

  protected onToInput(event: Event): void {
    this.toDraft.set((event.target as HTMLInputElement).value);
  }

  protected captureRange(): void {
    const range = this.parseRange();
    if (range) void this.view.setBrushRange(range, true);
  }

  private updateHover(
    xChart: number,
    yCss: number,
    chartW: number,
    rectW: number,
    rectH: number,
    localX: number,
    localY: number
  ): void {
    const lane = timelineYToLane(yCss, rectH);
    if (!lane || xChart < 0) {
      this.onPointerLeave();
      return;
    }
    const win = this.activeWindow();
    const hit = hitTestTimelineSlice(this.built().slices, win.startNs, win.endNs, lane, xChart, chartW);
    this.hoveredSlice.set(hit);
    if (!hit) {
      this.tooltip.set(null);
      this.hoverInfo.set(DEFAULT_HOVER_MSG);
      return;
    }
    const coreName = hit.core === Core.Cpu1 ? 'CPU1' : 'CPU0';
    const dur = formatTimelineNs(hit.endNs - hit.startNs);
    const title = `${coreName} · ${hit.label} (${hit.kind})`;
    const detail = `${dur} · ${hit.startNs}ns..${hit.endNs}ns`;
    this.hoverInfo.set(`${title} · ${detail}`);
    this.tooltip.set({
      x: Math.min(Math.max(8, localX + 12), Math.max(8, rectW - 220)),
      y: Math.min(Math.max(8, localY + 12), Math.max(8, rectH - 46)),
      title,
      detail,
    });
  }

  private chartMetrics(cssW: number): { labelW: number; chartW: number } {
    const labelW = Math.min(TIMELINE_LABEL_WIDTH, Math.max(88, Math.floor(cssW * 0.22)));
    const chartW = Math.max(10, cssW - labelW - TIMELINE_RIGHT_PAD);
    return { labelW, chartW };
  }

  private parseRange(): { fromNs: bigint; toNs: bigint } | null {
    const a = Number.parseInt(this.fromDraft().trim(), 10);
    const b = Number.parseInt(this.toDraft().trim(), 10);
    if (!Number.isFinite(a) || !Number.isFinite(b) || a < 0 || b <= a) return null;
    return { fromNs: BigInt(a), toNs: BigInt(b) };
  }

  private redraw(
    slices = this.built().slices,
    win = this.activeWindow(),
    brush = this.liveBrush() ?? this.view.brushRange()
  ): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const ctx = get2dContext(canvas);
    if (!ctx) return;
    const dpr = resolveDevicePixelRatio();
    const cssW = Math.max(1, canvas.clientWidth || Math.round(canvas.width / dpr));
    const cssH = Math.max(1, canvas.clientHeight || Math.round(canvas.height / dpr));
    drawProfileTimeline(ctx, slices, win.startNs, win.endNs, brush, cssW, cssH, dpr, {
      coreFilter: this.view.coreFilter(),
      threadFilter: this.view.threadFilter(),
      hoveredSlice: this.hoveredSlice(),
    });
  }
}
