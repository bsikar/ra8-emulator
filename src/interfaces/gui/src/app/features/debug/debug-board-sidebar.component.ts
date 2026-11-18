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
import { RouterLink } from '@angular/router';
import { RpcConnectionStore } from '../../core/rpc/rpc-connection.store';
import { BoardStore } from '../../core/stores/board.store';
import { ConsoleStore } from '../../core/stores/console.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { observeHiDpiCanvas } from '../../shared/utils/hidpi-canvas';

@Component({
  selector: 'app-debug-board-sidebar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [RouterLink, SectionKickerComponent],
  template: `
    <div class="board-side">
      <section class="panel-sec">
        <div class="sec-head">
          <app-section-kicker label="BOARD PREVIEW" />
          <span class="mono es-meta">{{ boardLabel() }}</span>
        </div>

        @if (hasPanel()) {
          <div class="canvas-frame" [style.aspectRatio]="panelAspectRatio()">
            <canvas #lcdCanvas class="lcd-canvas" data-testid="debug-board-canvas"></canvas>
          </div>
          <div class="cam-row">
            <span class="es-meta">Camera</span>
            <span class="es-meta mono">{{ panelResolution() }}</span>
            <select class="es-select mono" aria-label="Camera source" [value]="board.cameraSource()" (change)="onCameraChange($event)">
              <option value="none">none</option>
              <option value="gradient">gradient</option>
              <option value="checker">checker</option>
            </select>
          </div>
        } @else {
          <div class="headless-card">
            <p class="es-meta note">Headless target profile — no display panel fitted.</p>
          </div>
        }

        <div class="io-row">
          <div class="led-group">
            @for (on of ledPreview(); track $index) {
              <span class="led-item mono">
                <span class="led-dot" [class.is-on]="on"></span>
                {{ ledName($index) }}
              </span>
            }
          </div>
          <div class="sw-group">
            <button type="button" class="sw-btn mono" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="board.sendButton(0)">
              SW1
            </button>
            <button type="button" class="sw-btn mono" [disabled]="!rpc.isConnected() || rpc.observeOnly()" (click)="board.sendButton(1)">
              SW2
            </button>
          </div>
        </div>
      </section>

      <section class="uart-sec">
        <div class="sec-head">
          <app-section-kicker label="SERIAL · UART" />
          <a routerLink="/console" class="console-link">Open Console ↗</a>
        </div>
        <form class="tx-form" (submit)="onTxSubmit($event)">
          <input
            type="text"
            class="tx-input mono"
            data-testid="debug-serial-tx-input"
            [value]="txDraft()"
            (input)="onTxInput($event)"
            placeholder="Send command to SCI8..."
          />
          <button type="submit" class="sw-btn" [disabled]="!rpc.isConnected() || rpc.observeOnly()">Send</button>
        </form>
        <div #uartTailEl class="uart-tail mono">
          @if (uartTail().length > 0) {
            @for (entry of uartTail(); track entry.id) {
              <div class="uart-line">{{ entry.text }}</div>
            }
          } @else {
            <p class="es-meta note">No UART output yet.</p>
          }
        </div>
      </section>
    </div>
  `,
  styles: [
    `
      .board-side { display: flex; flex-direction: column; height: 100%; min-width: 0; }
      .panel-sec { padding: 10px 12px; border-bottom: 1px solid var(--es-border); display: flex; flex-direction: column; gap: 8px; }
      .uart-sec { flex: 1; min-height: 0; padding: 10px 12px; display: flex; flex-direction: column; gap: 8px; }
      .sec-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
      .canvas-frame { border: 1px solid var(--es-border); background: var(--es-chrome); border-radius: var(--es-radius); overflow: hidden; }
      .lcd-canvas { width: 100%; height: 100%; display: block; }
      .headless-card { padding: 12px; background: var(--es-container); border: 1px solid var(--es-border); border-radius: var(--es-radius); }
      .cam-row, .io-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
      .es-select { background: var(--es-container); color: var(--es-text-secondary); border: 1px solid var(--es-border); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 6px; }
      .led-group, .sw-group { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .led-item { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--es-text-muted); }
      .led-dot { width: 6px; height: 6px; border-radius: var(--es-radius-full); border: 1px solid var(--es-border-strong); background: transparent; }
      .led-dot.is-on { background: var(--es-signal-nominal); border-color: var(--es-signal-nominal); }
      .sw-btn { border: 1px solid var(--es-border); background: var(--es-interactive); color: var(--es-text-primary); border-radius: var(--es-radius-sm); font-size: 12px; padding: 2px 8px; cursor: pointer; }
      .sw-btn:disabled { opacity: 0.45; cursor: not-allowed; }
      .console-link { color: var(--es-text-secondary); font-size: 12px; text-decoration: none; }
      .uart-tail { flex: 1; min-height: 0; overflow: auto; font-size: 12px; color: var(--es-text-secondary); }
      .uart-line { padding: 2px 0; border-bottom: 1px solid var(--es-divider); white-space: pre-wrap; word-break: break-word; }
      .tx-form { display: flex; gap: 6px; }
      .tx-input { flex: 1; min-width: 0; background: transparent; border: 0; border-bottom: 1px solid var(--es-border); color: var(--es-text-primary); font-size: 12px; padding: 4px 2px; }
      .note { margin: 0; }
    `,
  ],
})
export class DebugBoardSidebarComponent implements AfterViewInit, OnDestroy {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly board = inject(BoardStore);
  protected readonly console = inject(ConsoleStore);

  private readonly lcdCanvas = viewChild<ElementRef<HTMLCanvasElement>>('lcdCanvas');
  private readonly uartTailEl = viewChild<ElementRef<HTMLElement>>('uartTailEl');
  private stopCanvasObserver: (() => void) | null = null;
  protected readonly txDraft = signal<string>('');

  protected readonly hasPanel = computed(() => {
    const parts = this.board.boardParts();
    if (parts) return parts.panelWidth > 0 && parts.panelHeight > 0;
    const profile = this.board.boardProfile();
    return profile !== null && profile.panel !== null;
  });

  protected readonly panelDimensions = computed(() => {
    const parts = this.board.boardParts();
    const w = parts && parts.panelWidth > 0 ? parts.panelWidth : 800;
    const h = parts && parts.panelHeight > 0 ? parts.panelHeight : 480;
    return { w, h };
  });

  protected readonly panelAspectRatio = computed(() => {
    const { w, h } = this.panelDimensions();
    return `${w} / ${h}`;
  });

  protected readonly panelResolution = computed(() => {
    const { w, h } = this.panelDimensions();
    return `${w}x${h}`;
  });

  protected readonly boardLabel = computed(() => {
    const name = this.board.selectedPreset()?.partNumber || this.board.boardProfileName();
    return this.board.lcdFrames() > 0 ? `${name} · ${this.board.lcdFps()} FPS` : name;
  });

  protected readonly ledPreview = computed(() => this.board.ledStates().slice(0, 4));
  protected readonly uartTail = computed(() => this.console.filteredEntries().slice(-12));

  constructor() {
    effect(() => {
      const count = this.uartTail().length;
      const el = this.uartTailEl()?.nativeElement;
      if (count > 0 && el) {
        queueMicrotask(() => {
          el.scrollTop = el.scrollHeight;
        });
      }
    });
  }

  public ngAfterViewInit(): void {
    const canvas = this.lcdCanvas()?.nativeElement;
    if (!canvas) return;
    const { w, h } = this.panelDimensions();
    this.board.attachCanvas(canvas, w, h);
    this.stopCanvasObserver = observeHiDpiCanvas(canvas, () => undefined);
  }

  public ngOnDestroy(): void {
    this.stopCanvasObserver?.();
    this.stopCanvasObserver = null;
    this.board.detachCanvas();
  }

  protected ledName(index: number): string {
    return this.board.boardParts()?.ledNames[index] ?? `LED${index + 1}`;
  }

  protected onCameraChange(event: Event): void {
    const value = (event.target as HTMLSelectElement).value;
    void this.board.setCamera(value);
  }

  protected onTxInput(event: Event): void {
    this.txDraft.set((event.target as HTMLInputElement).value);
  }

  protected async onTxSubmit(event: Event): Promise<void> {
    event.preventDefault();
    const text = this.txDraft().trim();
    if (!text) return;
    await this.console.sendInput(text);
    this.txDraft.set('');
  }
}
