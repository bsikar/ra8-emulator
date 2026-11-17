import { ChangeDetectionStrategy, Component, input } from '@angular/core';

export type StatusTone = 'nominal' | 'fault' | 'cursor' | 'muted';

@Component({
  selector: 'app-status-dot',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <span class="status-wrap">
      <span
        class="dot"
        [class.is-nominal]="tone() === 'nominal'"
        [class.is-fault]="tone() === 'fault'"
        [class.is-cursor]="tone() === 'cursor'"
        [attr.aria-hidden]="true"
      ></span>
      @if (label()) {
        <span class="label" [class.is-fault-text]="tone() === 'fault'">{{ label() }}</span>
      }
    </span>
  `,
  styles: [
    `
      .status-wrap {
        display: inline-flex;
        align-items: center;
        gap: 6px;
      }
      .dot {
        width: 5px;
        height: 5px;
        border-radius: var(--es-radius-full);
        background: var(--es-text-muted);
        flex-shrink: 0;
      }
      .dot.is-nominal {
        background: var(--es-signal-nominal);
      }
      .dot.is-fault {
        width: 6px;
        height: 6px;
        background: var(--es-signal-fault);
      }
      .dot.is-cursor {
        background: var(--es-signal-cursor);
      }
      .label {
        font-size: 12px;
        font-weight: 400;
        color: var(--es-text-muted);
        white-space: nowrap;
      }
      .label.is-fault-text {
        color: var(--es-signal-fault);
      }
    `,
  ],
})
export class StatusDotComponent {
  public readonly tone = input<StatusTone>('muted');
  public readonly label = input<string>('');
}
