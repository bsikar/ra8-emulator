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
import { Core, InputKind, type RtcReport, Topic } from 'ra8-rpc-client';
import { Subscription } from 'rxjs';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { ExecutionStore } from '../../core/stores/execution.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatVirtualTime } from '../../shared/utils/hex';
import { mapClientPointToPanel, observeHiDpiCanvas } from '../../shared/utils/hidpi-canvas';
import {
  type CameraSourceKind,
  type PanelCrosshair,
  exportRgbaToPngDataUrl,
  formatBoardMemorySummary,
  formatRtcReport,
  formatSiliconSummary,
  paintHiDpiPanelCanvas,
  resolveCameraSpec,
} from './hardware-panel-helpers';
import {
  type AdaptiveLcdMode,
  computeAdaptiveLcdPolicy,
  createLcdScrubberState,
  pushDirtyRectAdaptive,
} from './lcd-scrubber-model';

type TouchGestureMode = 'tap' | 'swipe' | 'long_press';

@Component({
  selector: 'app-hardware-panel-io',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  templateUrl: './hardware-panel-io.component.html',
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: auto; }
      .panel-io { display: flex; flex-direction: column; min-width: 0; background: var(--es-canvas); }
      .sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 8px; min-width: 0; }
      .sec-head, .sub-head, .lcd-meta-row, .ctrl-row, .sw-row, .led-strip, .cam-row, .kv-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .sec-head, .sub-head, .lcd-meta-row, .kv-row { justify-content: space-between; }
      .kv-row { font-size: 12px; color: var(--es-text-secondary); }
      .val-right { color: var(--es-text-primary); text-align: right; }
      .lcd-wrap { border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); background: var(--es-chrome); overflow: hidden; aspect-ratio: 16 / 10; }
      .lcd-canvas { width: 100%; height: 100%; display: block; cursor: crosshair; }
      .scrubber { flex: 1; min-width: 100px; accent-color: var(--es-signal-cursor); }
      .headless-box { padding: 10px 0; border-top: 1px solid var(--es-divider); }
      .led-item, .toggle-lbl { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-secondary); }
      .led-dot { width: 6px; height: 6px; border-radius: var(--es-radius-full); border: 1px solid var(--es-border-strong); }
      .led-dot.is-on { background: var(--es-signal-nominal); border-color: var(--es-signal-nominal); }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn.is-active { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .es-select { background: var(--es-chrome); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .es-input { flex: 1; min-width: 100px; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 3px 2px; }
      .note { margin: 0; font-size: 12px; }
    `,
  ],
})
export class HardwarePanelIoComponent implements AfterViewInit, OnDestroy {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly execution = inject(ExecutionStore);

  private readonly lcdCanvas = viewChild<ElementRef<HTMLCanvasElement>>('lcdCanvas');
  private readonly subs = new Subscription();
  private stopObserver: (() => void) | null = null;
  private dragStart: { x: number; y: number; tsMs: number } | null = null;

  protected readonly scrubState = signal(createLcdScrubberState(480, 272));
  protected readonly liveMode = signal<boolean>(true);
  protected readonly selectedIndex = signal<number>(0);
  protected readonly adaptiveMode = signal<AdaptiveLcdMode>('rate_1x');
  protected readonly touchMode = signal<TouchGestureMode>('tap');
  protected readonly crosshair = signal<PanelCrosshair | null>(null);
  protected readonly cameraKind = signal<CameraSourceKind>('gradient');
  protected readonly cameraArg = signal<string>('');
  protected readonly allowWebcam = signal<boolean>(false);
  protected readonly rtcReport = signal<RtcReport | null>(null);

  protected readonly frames = computed(() => this.scrubState().frames);
  protected readonly maxFrameIndex = computed(() => Math.max(0, this.frames().length - 1));
  protected readonly effectiveFrameIndex = computed(() =>
    this.liveMode() ? this.maxFrameIndex() : Math.min(this.selectedIndex(), this.maxFrameIndex())
  );
  protected readonly hasPanel = computed(() => {
    const parts = this.board.boardParts();
    if (parts) return parts.panelWidth > 0 && parts.panelHeight > 0;
    const profile = this.board.boardProfile();
    return profile !== null && profile.panel !== null;
  });
  protected readonly panelDimsLabel = computed(() => {
    const { w, h } = this.resolvePanelDims();
    return `${w}×${h} · RGB565`;
  });
  protected readonly boardHeader = computed(() => {
    const name = this.board.selectedPreset()?.targetId.toUpperCase() || this.board.boardProfileName().toUpperCase();
    return this.board.lcdFrames() > 0 ? `${name} · ${this.board.lcdFps()} FPS` : name;
  });
  protected readonly crosshairLabel = computed(() => {
    const pt = this.crosshair();
    return pt ? `x: ${pt.x}  y: ${pt.y}` : 'x: —  y: —';
  });
  protected readonly ledPreview = computed(() => this.board.ledStates().slice(0, 6));
  protected readonly scrubberStatus = computed(() => {
    const list = this.frames();
    if (list.length === 0) return '0 / 120';
    const idx = this.effectiveFrameIndex();
    const frame = list[idx];
    return frame ? `#${idx + 1}/${list.length} · ${formatVirtualTime(frame.virtualNs)}` : '0 / 120';
  });
  protected readonly rtcText = computed(() => formatRtcReport(this.rtcReport()));
  protected readonly siliconSummary = computed(() => formatSiliconSummary(this.board.selectedPreset()));
  protected readonly memorySummary = computed(() => formatBoardMemorySummary(this.board.boardProfile()));

  constructor() {
    this.subs.add(
      this.rpc.lcdDirty$.subscribe((rect) => {
        const policy = computeAdaptiveLcdPolicy(this.adaptiveMode());
        this.scrubState.update((st) =>
          pushDirtyRectAdaptive(st, rect, this.execution.virtualTimeNs(), policy, Date.now())
        );
      })
    );
    effect(() => {
      this.scrubState();
      this.liveMode();
      this.selectedIndex();
      this.crosshair();
      this.repaintCanvas();
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (canvas) {
      this.stopObserver = observeHiDpiCanvas(canvas, () => this.repaintCanvas());
    }
    if (this.rpc.isConnected()) void this.refreshRtc();
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
    this.subs.unsubscribe();
  }

  protected ledName(index: number): string {
    return this.board.boardParts()?.ledNames[index] ?? `LED${index + 1}`;
  }

  protected onScrubInput(event: Event): void {
    const idx = Number.parseInt((event.target as HTMLInputElement).value, 10);
    this.liveMode.set(false);
    this.selectedIndex.set(Number.isFinite(idx) ? idx : 0);
  }

  protected resumeLive(): void {
    this.liveMode.set(true);
    void this.applySubscribeRate(this.adaptiveMode());
  }

  protected onRateChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value as AdaptiveLcdMode;
    if (val === 'slow_0_1x' || val === 'rate_1x' || val === 'rate_100x' || val === 'rate_max') {
      this.adaptiveMode.set(val);
      void this.applySubscribeRate(val);
    }
  }

  protected onTouchModeChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'tap' || val === 'swipe' || val === 'long_press') this.touchMode.set(val);
  }

  protected onCameraKindChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value as CameraSourceKind;
    this.cameraKind.set(val);
  }

  protected onCameraArgInput(event: Event): void {
    this.cameraArg.set((event.target as HTMLInputElement).value);
  }

  protected onWebcamConsentToggle(event: Event): void {
    this.allowWebcam.set((event.target as HTMLInputElement).checked);
  }

  protected applyCamera(event: Event): void {
    event.preventDefault();
    const spec = resolveCameraSpec(this.cameraKind(), this.cameraArg());
    void this.board.setCamera(spec, this.allowWebcam());
  }

  protected savePng(): void {
    const frame = this.activeFrameRgba();
    const url = exportRgbaToPngDataUrl(frame.rgba, frame.width, frame.height);
    if (!url) {
      this.rpc.pushToast('PNG export requires a browser canvas context', 'neutral');
      return;
    }
    const link = document.createElement('a');
    link.href = url;
    link.download = 'ra8-panel.png';
    link.click();
    this.rpc.pushToast('Saved panel frame PNG');
  }

  protected onCanvasPointerMove(event: PointerEvent): void {
    const hit = this.mapPointer(event);
    if (hit) this.crosshair.set(hit);
  }

  protected onCanvasPointerLeave(): void {
    this.crosshair.set(null);
  }

  protected onCanvasPointerDown(event: PointerEvent): void {
    const hit = this.mapPointer(event);
    if (hit) {
      this.crosshair.set(hit);
      this.dragStart = { x: hit.x, y: hit.y, tsMs: Date.now() };
    }
  }

  protected onCanvasPointerUp(event: PointerEvent): void {
    const start = this.dragStart;
    this.dragStart = null;
    if (!start || !this.rpc.isConnected() || this.rpc.observeOnly()) return;
    const end = this.mapPointer(event) ?? { x: start.x, y: start.y };
    const dist = Math.hypot(end.x - start.x, end.y - start.y);
    const elapsedMs = Date.now() - start.tsMs;
    if (this.touchMode() === 'swipe' || dist >= 12) {
      void this.board.sendTouch(InputKind.Swipe, start.x, start.y, end.x, end.y, 120_000_000n);
    } else if (this.touchMode() === 'long_press' || elapsedMs >= 500) {
      void this.board.sendTouch(InputKind.LongPress, start.x, start.y, start.x, start.y, 600_000_000n);
    } else {
      void this.board.sendTouch(InputKind.Tap, start.x, start.y);
    }
  }

  public async refreshRtc(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      this.rtcReport.set(await client.getRtc(Core.Cpu0));
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
  }

  private resolvePanelDims(): { w: number; h: number } {
    const parts = this.board.boardParts();
    if (parts && parts.panelWidth > 0 && parts.panelHeight > 0) {
      return { w: parts.panelWidth, h: parts.panelHeight };
    }
    const st = this.scrubState();
    return { w: st.width, h: st.height };
  }

  private activeFrameRgba(): { rgba: Uint8ClampedArray; width: number; height: number } {
    const st = this.scrubState();
    if (!this.liveMode()) {
      const snap = st.frames[this.effectiveFrameIndex()];
      if (snap) return { rgba: snap.rgba, width: snap.width, height: snap.height };
    }
    return { rgba: st.backingRgba, width: st.width, height: st.height };
  }

  private repaintCanvas(): void {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!canvas) return;
    const frame = this.activeFrameRgba();
    paintHiDpiPanelCanvas(canvas, frame.rgba, frame.width, frame.height, this.crosshair());
  }

  private mapPointer(event: PointerEvent): PanelCrosshair | null {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!canvas) return null;
    const { w, h } = this.resolvePanelDims();
    const hit = mapClientPointToPanel(event.clientX, event.clientY, canvas.getBoundingClientRect(), w, h, true);
    return hit.inside ? { x: hit.x, y: hit.y } : null;
  }

  private async applySubscribeRate(mode: AdaptiveLcdMode): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    const policy = computeAdaptiveLcdPolicy(mode);
    try {
      await client.subscribe(Core.Cpu0, Topic.LcdDirty, policy.subscribeRateHz);
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
  }
}
