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
import { get2dContext, mapClientPointToPanel, observeHiDpiCanvas } from '../../shared/utils/hidpi-canvas';
import {
  type LcdRatePreset,
  computeLcdSubscribeRateHz,
  createLcdScrubberState,
  pushDirtyRectFrame,
} from './lcd-scrubber-model';

type TouchGestureMode = 'tap' | 'swipe' | 'long_press';

@Component({
  selector: 'app-hardware-panel-io',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent],
  template: `
    <div class="panel-io">
      <div class="sec-head">
        <app-section-kicker label="DISPLAY PANEL & TOUCH" />
        <span class="mono es-meta">{{ boardHeader() }}</span>
      </div>

      @if (hasPanel()) {
        <div class="lcd-wrap">
          <canvas
            #lcdCanvas
            class="lcd-canvas"
            data-testid="hardware-lcd-canvas"
            (pointerdown)="onCanvasPointerDown($event)"
            (pointerup)="onCanvasPointerUp($event)"
          ></canvas>
        </div>

        <div class="ctrl-row">
          <button type="button" class="mini-btn" [class.is-active]="liveMode()" data-testid="hardware-live-btn" (click)="resumeLive()">
            {{ liveMode() ? 'Live' : 'Resume Live' }}
          </button>
          <input
            type="range"
            class="scrubber"
            data-testid="hardware-frame-scrubber"
            [min]="0"
            [max]="maxFrameIndex()"
            [value]="effectiveFrameIndex()"
            [disabled]="frames().length === 0"
            (input)="onScrubInput($event)"
            aria-label="LCD frame scrubber"
          />
          <span class="mono es-meta">{{ scrubberStatus() }}</span>
          <select class="es-select mono" aria-label="LCD update rate" data-testid="hardware-lcd-rate" [value]="ratePreset()" (change)="onRateChange($event)">
            <option value="unthrottled">Unthrottled (0)</option>
            <option value="hz60">60 Hz</option>
            <option value="hz15">15 Hz</option>
          </select>
          <select class="es-select" aria-label="Touch gesture mode" data-testid="hardware-touch-mode" [value]="touchMode()" (change)="onTouchModeChange($event)">
            <option value="tap">Tap</option>
            <option value="swipe">Swipe</option>
            <option value="long_press">Long Press</option>
          </select>
        </div>
      } @else {
        <div class="headless-card">
          <p class="es-meta note">Headless target profile — no display panel fitted on this board.</p>
        </div>
      }

      <div class="io-grid">
        <div class="io-card">
          <app-section-kicker label="GPIO LEDS & SWITCHES" />
          <div class="led-strip">
            @for (on of ledPreview(); track $index) {
              <span class="led-item mono">
                <span class="led-dot" [class.is-on]="on"></span>
                {{ ledName($index) }}
              </span>
            }
          </div>
          <div class="sw-row">
            <button type="button" class="mini-btn mono" data-testid="hardware-sw-0" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="board.sendButton(0)">SW1</button>
            <button type="button" class="mini-btn mono" data-testid="hardware-sw-1" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="board.sendButton(1)">SW2</button>
            <span class="es-meta">Camera</span>
            <select class="es-select mono" aria-label="Camera source" data-testid="hardware-camera-select" [value]="board.cameraSource()" (change)="onCameraChange($event)">
              <option value="none">none</option>
              <option value="gradient">gradient</option>
            </select>
          </div>
        </div>

        <div class="io-card">
          <div class="sec-head">
            <app-section-kicker label="REAL-TIME CLOCK (RTC)" />
            <button type="button" class="mini-btn" data-testid="hardware-rtc-refresh" [disabled]="!rpc.isConnected()" (click)="refreshRtc()">Read RTC</button>
          </div>
          <p class="mono rtc-val" data-testid="hardware-rtc-readout">{{ rtcText() }}</p>
        </div>
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; overflow: auto; }
      .panel-io { padding: 12px 16px; display: flex; flex-direction: column; gap: 10px; min-width: 0; }
      .sec-head, .ctrl-row, .sw-row, .led-strip { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .sec-head { justify-content: space-between; }
      .lcd-wrap { border: 1px solid var(--es-border); border-radius: var(--es-radius); background: var(--es-chrome); overflow: hidden; aspect-ratio: 16 / 10; }
      .lcd-canvas { width: 100%; height: 100%; display: block; cursor: crosshair; }
      .scrubber { flex: 1; min-width: 120px; accent-color: var(--es-signal-cursor); }
      .headless-card, .io-card { padding: 10px 12px; background: var(--es-container); border: 1px solid var(--es-border); border-radius: var(--es-radius); display: flex; flex-direction: column; gap: 8px; }
      .io-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px; }
      .led-item { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-secondary); }
      .led-dot { width: 6px; height: 6px; border-radius: var(--es-radius-full); border: 1px solid var(--es-border-strong); }
      .led-dot.is-on { background: var(--es-signal-nominal); border-color: var(--es-signal-nominal); }
      .mini-btn { border: 1px solid var(--es-border); background: transparent; color: var(--es-text-secondary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .mini-btn.is-active { background: var(--es-interactive); border-color: var(--es-signal-cursor); color: var(--es-text-primary); }
      .mini-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .es-select { background: var(--es-chrome); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .rtc-val, .note { margin: 0; font-size: 12px; color: var(--es-text-primary); }
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

  private readonly scrubState = signal(createLcdScrubberState(480, 272));
  protected readonly liveMode = signal<boolean>(true);
  protected readonly selectedIndex = signal<number>(0);
  protected readonly ratePreset = signal<LcdRatePreset>('unthrottled');
  protected readonly touchMode = signal<TouchGestureMode>('tap');
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
  protected readonly boardHeader = computed(() => {
    const name = this.board.selectedPreset()?.partNumber || this.board.boardProfileName();
    return this.board.lcdFrames() > 0 ? `${name} · ${this.board.lcdFps()} FPS` : name;
  });
  protected readonly ledPreview = computed(() => this.board.ledStates().slice(0, 6));
  protected readonly scrubberStatus = computed(() => {
    const list = this.frames();
    if (list.length === 0) return '0 / 120 frames';
    const idx = this.effectiveFrameIndex();
    const frame = list[idx];
    return frame ? `#${idx + 1}/${list.length} · ${formatVirtualTime(frame.virtualNs)}` : '0 / 120 frames';
  });
  protected readonly rtcText = computed(() => {
    const rtc = this.rtcReport();
    if (!rtc) return 'Not sampled yet.';
    const d = `${rtc.year.toString().padStart(4, '0')}-${String(rtc.month).padStart(2, '0')}-${String(rtc.day).padStart(2, '0')}`;
    const t = `${String(rtc.hour).padStart(2, '0')}:${String(rtc.minute).padStart(2, '0')}:${String(rtc.second).padStart(2, '0')}`;
    return `${d} ${t} (${rtc.running ? 'running' : 'stopped'}, ${rtc.valid ? 'valid' : 'unset'})`;
  });

  constructor() {
    this.subs.add(
      this.rpc.lcdDirty$.subscribe((rect) => {
        this.scrubState.update((st) => pushDirtyRectFrame(st, rect, this.execution.virtualTimeNs()));
      })
    );
    effect(() => {
      const idx = this.selectedIndex();
      if (!this.liveMode()) this.paintScrubbedFrame(idx);
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!canvas) return;
    const parts = this.board.boardParts();
    const w = parts && parts.panelWidth > 0 ? parts.panelWidth : 800;
    const h = parts && parts.panelHeight > 0 ? parts.panelHeight : 480;
    this.board.attachCanvas(canvas, w, h);
    this.stopObserver = observeHiDpiCanvas(canvas, () => undefined);
    if (this.rpc.isConnected()) void this.refreshRtc();
  }

  public ngOnDestroy(): void {
    this.stopObserver?.();
    this.stopObserver = null;
    this.board.detachCanvas();
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
    const canvas = this.lcdCanvas()?.nativeElement;
    if (canvas) {
      const parts = this.board.boardParts();
      this.board.attachCanvas(canvas, parts?.panelWidth || 800, parts?.panelHeight || 480);
    }
    void this.applySubscribeRate(this.ratePreset());
  }

  protected onRateChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'unthrottled' || val === 'hz60' || val === 'hz15') {
      this.ratePreset.set(val);
      if (this.liveMode()) void this.applySubscribeRate(val);
    }
  }

  protected onTouchModeChange(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'tap' || val === 'swipe' || val === 'long_press') this.touchMode.set(val);
  }

  protected onCameraChange(event: Event): void {
    void this.board.setCamera((event.target as HTMLSelectElement).value);
  }

  protected onCanvasPointerDown(event: PointerEvent): void {
    const hit = this.mapPointer(event);
    if (hit) this.dragStart = { x: hit.x, y: hit.y, tsMs: Date.now() };
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

  private mapPointer(event: PointerEvent): { x: number; y: number } | null {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!canvas) return null;
    const parts = this.board.boardParts();
    const w = parts && parts.panelWidth > 0 ? parts.panelWidth : 800;
    const h = parts && parts.panelHeight > 0 ? parts.panelHeight : 480;
    const hit = mapClientPointToPanel(event.clientX, event.clientY, canvas.getBoundingClientRect(), w, h, true);
    return hit.inside ? { x: hit.x, y: hit.y } : null;
  }

  private paintScrubbedFrame(index: number): void {
    const frame = this.frames()[index];
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!frame || !canvas) return;
    const ctx = get2dContext(canvas);
    if (!ctx || typeof ImageData === 'undefined') return;
    canvas.width = frame.width;
    canvas.height = frame.height;
    ctx.putImageData(new ImageData(new Uint8ClampedArray(frame.rgba), frame.width, frame.height), 0, 0);
  }

  private async applySubscribeRate(preset: LcdRatePreset): Promise<void> {
    const client = this.rpc.activeClient;
    const rate = computeLcdSubscribeRateHz(preset);
    if (!client || rate === null) return;
    try {
      await client.subscribe(Core.Cpu0, Topic.LcdDirty, rate);
    } catch (err) {
      this.rpc.noteOptionalError(err);
    }
  }
}
