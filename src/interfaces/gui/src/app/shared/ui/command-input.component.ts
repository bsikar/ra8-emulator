import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  effect,
  input,
  model,
  output,
  viewChild,
} from '@angular/core';

@Component({
  selector: 'app-command-input',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <label class="cmd-field">
      <svg class="cmd-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        <path
          d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5Zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14Z"
          fill="currentColor"
        />
      </svg>
      <input
        #inputEl
        type="text"
        class="cmd-input"
        [value]="value()"
        [placeholder]="placeholder()"
        [attr.aria-label]="ariaLabel()"
        [attr.data-testid]="testId()"
        (input)="onInput($event)"
        (keydown.enter)="submitted.emit(value())"
      />
      <ng-content />
    </label>
  `,
  styles: [
    `
      :host {
        display: block;
      }
      .cmd-field {
        display: flex;
        align-items: center;
        gap: 10px;
        min-height: 38px;
        padding: 4px 2px;
        background: transparent;
        border-bottom: 1px solid var(--es-border);
        transition: border-color 120ms ease;
      }
      .cmd-field:focus-within {
        border-bottom-color: var(--es-text-kicker);
      }
      .cmd-icon {
        color: var(--es-text-muted);
        flex-shrink: 0;
      }
      .cmd-input {
        flex: 1;
        min-width: 0;
        border: 0;
        background: transparent;
        color: var(--es-text-primary);
        font-family: var(--font-sans);
        font-size: 13px;
        line-height: 1.4;
        outline: none;
      }
      .cmd-input::placeholder {
        color: var(--es-text-muted);
      }
    `,
  ],
})
export class CommandInputComponent {
  public readonly value = model<string>('');
  public readonly placeholder = input<string>('Filter or type > for commands...');
  public readonly ariaLabel = input<string>('Command input');
  public readonly testId = input<string | null>(null);
  public readonly autoFocus = input<boolean>(false);
  public readonly submitted = output<string>();

  private readonly inputEl = viewChild<ElementRef<HTMLInputElement>>('inputEl');

  constructor() {
    effect(() => {
      if (this.autoFocus()) {
        this.inputEl()?.nativeElement.focus();
      }
    });
  }

  protected onInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.value.set(target.value);
    }
  }
}
