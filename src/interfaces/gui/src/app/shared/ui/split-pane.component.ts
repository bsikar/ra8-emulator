import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  OnInit,
  computed,
  inject,
  input,
  signal,
} from '@angular/core';

const SPLIT_STORAGE_PREFIX = 'ra8.split.v1.';

function loadPersistedRatio(key: string): number | null {
  if (!key || typeof localStorage === 'undefined') return null;
  try {
    const raw = localStorage.getItem(`${SPLIT_STORAGE_PREFIX}${key}`);
    if (!raw) return null;
    const parsed = Number.parseFloat(raw);
    return Number.isFinite(parsed) && parsed >= 8 && parsed <= 92 ? parsed : null;
  } catch (err) {
    void err;
    return null;
  }
}

function savePersistedRatio(key: string, ratioPct: number): void {
  if (!key || typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(`${SPLIT_STORAGE_PREFIX}${key}`, ratioPct.toFixed(2));
  } catch (err) {
    void err;
  }
}

@Component({
  selector: 'app-split-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div
      class="split-grid"
      [class.is-vertical]="direction() === 'vertical'"
      [class.is-dragging]="dragging()"
      [style.gridTemplateColumns]="direction() === 'horizontal' ? gridTrack() : null"
      [style.gridTemplateRows]="direction() === 'vertical' ? gridTrack() : null"
    >
      <section class="pane pane-primary">
        <ng-content select="[pane-primary]" />
      </section>
      @if (resizable()) {
        <div
          class="split-handle"
          role="separator"
          tabindex="0"
          data-testid="split-pane-handle"
          [attr.aria-label]="handleLabel()"
          [attr.aria-orientation]="direction() === 'horizontal' ? 'vertical' : 'horizontal'"
          (pointerdown)="onPointerDown($event)"
          (pointermove)="onPointerMove($event)"
          (pointerup)="onPointerUp($event)"
          (pointercancel)="onPointerUp($event)"
          (dblclick)="resetSize()"
          (keydown)="onHandleKeyDown($event)"
        ></div>
      }
      <section class="pane pane-secondary">
        <ng-content select="[pane-secondary]" />
      </section>
    </div>
  `,
  styles: [
    `
      :host {
        display: block;
        width: 100%;
        height: 100%;
        min-height: 0;
        min-width: 0;
      }
      .split-grid {
        display: grid;
        width: 100%;
        height: 100%;
        min-height: 0;
        min-width: 0;
        background: var(--es-canvas);
      }
      .split-grid.is-dragging {
        user-select: none;
      }
      .pane {
        min-width: 0;
        min-height: 0;
        overflow: auto;
      }
      .pane-primary {
        border-right: 1px solid var(--es-border);
      }
      .split-grid.is-vertical .pane-primary {
        border-right: 0;
        border-bottom: 1px solid var(--es-border);
      }
      .split-handle {
        position: relative;
        width: 5px;
        margin-left: -3px;
        margin-right: -2px;
        cursor: col-resize;
        z-index: 4;
        background: transparent;
      }
      .split-grid.is-vertical .split-handle {
        width: 100%;
        height: 5px;
        margin: -3px 0 -2px;
        cursor: row-resize;
      }
      .split-handle:hover,
      .split-handle:focus-visible,
      .split-grid.is-dragging .split-handle {
        background: rgba(184, 196, 217, 0.22);
      }
      @media (max-width: 900px) {
        .split-grid {
          grid-template-columns: 1fr !important;
          grid-template-rows: auto auto !important;
        }
        .split-handle {
          display: none;
        }
        .pane-primary {
          border-right: 0;
          border-bottom: 1px solid var(--es-border);
        }
      }
    `,
  ],
})
export class SplitPaneComponent implements OnInit {
  private readonly hostRef = inject<ElementRef<HTMLElement>>(ElementRef);

  public readonly direction = input<'horizontal' | 'vertical'>('horizontal');
  public readonly primarySize = input<string>('320px');
  public readonly persistKey = input<string>('');
  public readonly resizable = input<boolean>(true);
  public readonly minPrimaryPx = input<number>(180);
  public readonly minSecondaryPx = input<number>(200);
  public readonly handleLabel = input<string>('Resize split pane');

  protected readonly ratioPct = signal<number | null>(null);
  protected readonly dragging = signal<boolean>(false);

  protected readonly primaryTrack = computed<string>(() => {
    const pct = this.ratioPct();
    if (pct !== null) {
      return `minmax(${this.minPrimaryPx()}px, ${pct.toFixed(2)}%)`;
    }
    return this.primarySize();
  });

  protected readonly gridTrack = computed<string>(() => {
    const sec = `minmax(${this.minSecondaryPx()}px, 1fr)`;
    return this.resizable() ? `${this.primaryTrack()} 0px ${sec}` : `${this.primaryTrack()} ${sec}`;
  });

  public ngOnInit(): void {
    const saved = loadPersistedRatio(this.persistKey());
    if (saved !== null) this.ratioPct.set(saved);
  }

  public resetSize(): void {
    this.ratioPct.set(null);
    const key = this.persistKey();
    if (key && typeof localStorage !== 'undefined') {
      try {
        localStorage.removeItem(`${SPLIT_STORAGE_PREFIX}${key}`);
      } catch (err) {
        void err;
      }
    }
  }

  protected onPointerDown(event: PointerEvent): void {
    if (event.button !== 0) return;
    event.preventDefault();
    this.dragging.set(true);
    const target = event.currentTarget;
    if (target instanceof HTMLElement && typeof target.setPointerCapture === 'function') {
      target.setPointerCapture(event.pointerId);
    }
    this.updateFromPointer(event.clientX, event.clientY);
  }

  protected onPointerMove(event: PointerEvent): void {
    if (!this.dragging()) return;
    this.updateFromPointer(event.clientX, event.clientY);
  }

  protected onPointerUp(event: PointerEvent): void {
    if (!this.dragging()) return;
    this.dragging.set(false);
    const target = event.currentTarget;
    if (target instanceof HTMLElement && typeof target.releasePointerCapture === 'function') {
      try {
        target.releasePointerCapture(event.pointerId);
      } catch (err) {
        void err;
      }
    }
  }

  protected onHandleKeyDown(event: KeyboardEvent): void {
    const horiz = this.direction() === 'horizontal';
    const delta =
      (horiz && event.key === 'ArrowLeft') || (!horiz && event.key === 'ArrowUp')
        ? -3
        : (horiz && event.key === 'ArrowRight') || (!horiz && event.key === 'ArrowDown')
          ? 3
          : 0;
    if (delta === 0) return;
    event.preventDefault();
    const current = this.ratioPct() ?? 35;
    const next = Math.min(85, Math.max(12, current + delta));
    this.ratioPct.set(next);
    savePersistedRatio(this.persistKey(), next);
  }

  private updateFromPointer(clientX: number, clientY: number): void {
    const rect = this.hostRef.nativeElement.getBoundingClientRect();
    const total = this.direction() === 'horizontal' ? rect.width : rect.height;
    if (total <= 0) return;
    const offset = this.direction() === 'horizontal' ? clientX - rect.left : clientY - rect.top;
    const clampedPx = Math.min(
      Math.max(this.minPrimaryPx(), total - this.minSecondaryPx()),
      Math.max(this.minPrimaryPx(), offset)
    );
    const pct = Math.min(88, Math.max(10, (clampedPx / total) * 100));
    this.ratioPct.set(pct);
    savePersistedRatio(this.persistKey(), pct);
  }
}
