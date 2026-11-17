import { ChangeDetectionStrategy, Component, input } from '@angular/core';

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
    `,
  ],
})
export class SectionKickerComponent {
  public readonly label = input.required<string>();
  public readonly testId = input<string | null>(null);
}
