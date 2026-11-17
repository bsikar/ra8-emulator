import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';

@Component({
  selector: 'app-tonal-button',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <button
      [attr.type]="type()"
      [class.es-tonal-btn]="variant() === 'tonal'"
      [class.es-ghost-link]="variant() === 'ghost'"
      [class.is-active]="active()"
      [disabled]="disabled()"
      [attr.aria-label]="ariaLabel()"
      [attr.data-testid]="testId()"
      (click)="pressed.emit($event)"
    >
      <ng-content />
    </button>
  `,
  styles: [
    `
      :host {
        display: inline-flex;
      }
      button.is-active {
        color: var(--es-text-primary);
        border-bottom: 1px solid var(--es-signal-cursor);
      }
    `,
  ],
})
export class TonalButtonComponent {
  public readonly variant = input<'tonal' | 'ghost'>('tonal');
  public readonly type = input<'button' | 'submit'>('button');
  public readonly disabled = input<boolean>(false);
  public readonly active = input<boolean>(false);
  public readonly ariaLabel = input<string | null>(null);
  public readonly testId = input<string | null>(null);
  public readonly pressed = output<MouseEvent>();
}
