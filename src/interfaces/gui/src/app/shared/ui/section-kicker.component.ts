import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

@Component({
  selector: 'app-section-kicker',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<span class="es-kicker" [attr.data-testid]="testId()">{{ label() }}</span>`,
  styles: [
    `
      :host {
        display: inline-flex;
        align-items: center;
      }
      .kicker {
        font-family: var(--font-sans);
        font-size: 11px;
        font-weight: 500;
        line-height: 0.875rem;
        letter-spacing: 0.15em;
        text-transform: uppercase;
        color: var(--es-text-kicker);
      }
    `,
  ],
})
export class SectionKickerComponent {
  public readonly label = input.required<string>();
  public readonly testId = input<string | null>(null);
  protected readonly hasLabel = computed(() => this.label().trim().length > 0);
}
