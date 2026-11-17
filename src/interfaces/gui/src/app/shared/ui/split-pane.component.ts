import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

@Component({
  selector: 'app-split-pane',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div
      class="split-grid"
      [class.is-vertical]="direction() === 'vertical'"
      [style.gridTemplateColumns]="direction() === 'horizontal' ? gridTrack() : null"
      [style.gridTemplateRows]="direction() === 'vertical' ? gridTrack() : null"
    >
      <section class="pane pane-primary">
        <ng-content select="[pane-primary]" />
      </section>
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
      }
      .split-grid {
        display: grid;
        width: 100%;
        height: 100%;
        min-height: 0;
        background: var(--es-canvas);
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
      @media (max-width: 900px) {
        .split-grid {
          grid-template-columns: 1fr !important;
          grid-template-rows: auto auto !important;
        }
        .pane-primary {
          border-right: 0;
          border-bottom: 1px solid var(--es-border);
        }
      }
    `,
  ],
})
export class SplitPaneComponent {
  public readonly direction = input<'horizontal' | 'vertical'>('horizontal');
  public readonly primarySize = input<string>('320px');

  protected readonly gridTrack = computed(() => `${this.primarySize()} minmax(0, 1fr)`);
}
