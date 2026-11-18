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
import {
  buildExecutionSlices,
  drawProfileTimeline,
  hitTestTimelineSlice,
  zoomTimelineWindow,
} from './timeline-model';

@Component({
  selector: 'app-profile-timeline-canvas',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="tl-pane">
      <div class="tl-head">
        <div class="grp">
          <app-section-kicker label="CONTEXT-SWITCH TIMELINE" />
          <span class="mono es-meta">CPU0 {{ built().utilization.cpu0ActivePct }}% active</span>
          @if (execution.cpu1Attached()) {
            <span class="mono es-meta">CPU1 {{ built().utilization.cpu1ActivePct }}% active</span>
          }
        </div>
        <div class="grp">
          <button type="button" class="mini-btn" (click)="zoom(0.5)">Zoom In</button>
          <button type="button" class="mini-btn" (click)="zoom(2)">Zoom Out</button>
          <button type="button" class="mini-btn" (click)="resetWindow()">Reset View</button>
          <input type="text" class="ns-input mono" data-testid="profile-range-from" [value]="fromDraft()" (input)="onFromInput($event)" aria-label="Capture start ns" />
          <span class="es-meta">to</span>
          <input type="text" class="ns-input mono" data-testid="profile-range-to" [value]="toDraft()" (input)="onToInput($event)" aria-label="Capture end ns" />
          <button type="button" class="mini-btn" data-testid="profile-capture-btn" (click)="captureRange()">Capture Range</button>
        </div>
      </div>

      <div class="canvas-box">
        <canvas
          #tlCanvas
          class="tl-canvas"
          data-testid="profile-timeline-canvas"
          (wheel)="onWheel($event)"
          (mousemove)="onMouseMove($event)"
        ></canvas>
      </div>

      <div class="tl-foot mono es-meta">
        <span>{{ hoverInfo() }}</span>
        <span>{{ built().slices.length }} slices recorded</span>
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: hidden; }
      .tl-pane { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .tl-head, .tl-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; font-size: 12px; }
      .tl-foot { border-bottom: 0; border-top: 1px solid var(--es-divider); }
      .grp { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; }
      .ns-input { width: 82px; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 2px 4px; }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .canvas-box { flex: 1; min-height: 110px; position: relative; overflow: hidden; }
      .tl-canvas { width: 100%; height: 100%; display: block; }
    `,
  ],
})
export class ProfileTimelineCanvasComponent implements AfterViewInit, OnDestroy {
  protected readonly profile = inject(ProfileStore);
  protected readonly execution = inject(ExecutionStore);

  private readonly tlCanvas = viewChild<ElementRef<HTMLCanvasElement>>('tlCanvas');
  private stopObserver: (() => void) | null = null;

  protected readonly customWindow = signal<{ startNs: bigint; endNs: bigint } | null>(null);
  protected readonly fromDraft = signal<string>('0');
  protected readonly toDraft = signal<string>('1000000');
  protected readonly hoverInfo = signal<string>('Wheel to zoom · Hover swimlane to inspect task or ISR slice');

  protected readonly built = computed(() =>
    buildExecutionSlices(this.profile.traceTimeline(), this.execution.virtualTimeNs())
  );
  protected readonly activeWindow = computed(() => {
    const custom = this.customWindow();
    if (custom) return custom;
    const u = this.built().utilization;
    return { startNs: u.windowStartNs, endNs: u.windowEndNs > u.windowStartNs ? u.windowEndNs : u.windowStartNs + 1000n };
  });

  constructor() {
    effect(() => {
      const slices = this.built().slices;
      const win = this.activeWindow();
      const brush = this.parseRange();
      this.redraw(slices, win, brush);
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    this.stopObserver = observeHiDpiCanvas(canvas, () =>
      this.redraw(this.built().slices, this.activeWindow(), this.parseRange())
    );
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
  }

  protected zoom(factor: number): void {
    const win = this.activeWindow();
    this.customWindow.set(zoomTimelineWindow(win.startNs, win.endNs, factor, 0.5));
  }

  protected resetWindow(): void {
    this.customWindow.set(null);
  }

  protected onWheel(event: WheelEvent): void {
    event.preventDefault();
    this.zoom(event.deltaY < 0 ? 0.75 : 1.35);
  }

  protected onMouseMove(event: MouseEvent): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left - 88;
    const y = event.clientY - rect.top;
    const lane = y >= 68 ? Core.Cpu1 : Core.Cpu0;
    const win = this.activeWindow();
    const hit = hitTestTimelineSlice(this.built().slices, win.startNs, win.endNs, lane, x, Math.max(10, rect.width - 100));
    if (hit) {
      this.hoverInfo.set(`${hit.label} (${hit.kind}) · ${hit.startNs}ns..${hit.endNs}ns`);
    }
  }

  protected onFromInput(event: Event): void {
    this.fromDraft.set((event.target as HTMLInputElement).value);
  }

  protected onToInput(event: Event): void {
    this.toDraft.set((event.target as HTMLInputElement).value);
  }

  protected captureRange(): void {
    const range = this.parseRange();
    if (range) void this.profile.captureFolded(Core.Cpu0, 0xffff_ffff, range.fromNs, range.toNs);
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
    brush = this.parseRange()
  ): void {
    const canvas = this.tlCanvas()?.nativeElement;
    if (!canvas) return;
    const ctx = get2dContext(canvas);
    if (!ctx) return;
    const dpr = resolveDevicePixelRatio();
    const cssW = Math.max(1, canvas.clientWidth || Math.round(canvas.width / dpr));
    const cssH = Math.max(1, canvas.clientHeight || Math.round(canvas.height / dpr));
    drawProfileTimeline(ctx, slices, win.startNs, win.endNs, brush, cssW, cssH, dpr);
  }
}
