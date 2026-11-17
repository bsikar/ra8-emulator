import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  effect,
  input,
  output,
  viewChild,
} from '@angular/core';
import { StatusDotComponent } from '../../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';

@Component({
  selector: 'app-launch-connect-bar',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [StatusDotComponent, TonalButtonComponent],
  template: `
    <div class="connect-panel" [class.is-standalone]="!embedded()" data-testid="launch-connect-bar">
      <div class="connect-head">
        <h1 class="es-title connect-title">Connect Target Session</h1>
        <div class="connect-status">
          <app-status-dot
            [tone]="connected() ? 'nominal' : hasError() ? 'fault' : 'muted'"
            [label]="connected() ? 'Connected' : connectionState()"
          />
          @if (!embedded()) {
            <button type="button" class="es-ghost-link" (click)="closed.emit()">Close</button>
          }
        </div>
      </div>

      <p class="es-meta connect-desc">{{ subtitle() }}</p>

      <div class="connect-row">
        <input
          #wsInputEl
          type="text"
          class="ws-input mono"
          data-testid="launch-ws-input"
          aria-label="WebSocket RPC URL"
          [value]="wsUrl()"
          (input)="onUrlInput($event)"
          (keydown.enter)="connectPressed.emit()"
          placeholder="ws://127.0.0.1:4567"
        />
        @if (connected()) {
          <app-tonal-button testId="launch-disconnect-btn" (pressed)="disconnectPressed.emit()">
            Disconnect
          </app-tonal-button>
        } @else {
          <app-tonal-button testId="launch-connect-btn" (pressed)="connectPressed.emit()">
            Connect
          </app-tonal-button>
        }
      </div>

      @if (savedHosts().length > 0) {
        <div class="hosts-row">
          <span class="es-kicker">SAVED HOSTS</span>
          <div class="hosts-chips">
            @for (host of savedHosts(); track host) {
              <button type="button" class="host-chip mono" (click)="connectHost.emit(host)">
                {{ host }}
              </button>
            }
          </div>
        </div>
      }
    </div>
  `,
  styles: [
    `
      .connect-panel {
        display: flex;
        flex-direction: column;
        gap: 12px;
      }
      .connect-panel.is-standalone {
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        padding: 18px 22px;
      }
      .connect-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
      }
      .connect-status {
        display: inline-flex;
        align-items: center;
        gap: 10px;
      }
      .connect-title,
      .connect-desc {
        margin: 0;
      }
      .connect-row {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .ws-input {
        flex: 1;
        min-width: 0;
        height: 32px;
        border: 0;
        border-bottom: 1px solid var(--es-border);
        background: transparent;
        color: var(--es-text-primary);
        font-size: 13px;
        outline: none;
      }
      .ws-input:focus {
        border-bottom-color: var(--es-text-kicker);
      }
      .hosts-row {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: 10px;
      }
      .hosts-chips {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }
      .host-chip {
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius);
        background: var(--es-chrome);
        color: var(--es-text-muted);
        font-size: 12px;
        padding: 2px 8px;
        cursor: pointer;
      }
      .host-chip:hover {
        color: var(--es-text-primary);
        border-color: var(--es-text-kicker);
      }
    `,
  ],
})
export class LaunchConnectBarComponent {
  public readonly embedded = input<boolean>(false);
  public readonly autoFocus = input<boolean>(false);
  public readonly subtitle = input<string>('WebSocket RPC · ARM Cortex-M85 / M33');
  public readonly wsUrl = input<string>('');
  public readonly connected = input<boolean>(false);
  public readonly hasError = input<boolean>(false);
  public readonly connectionState = input<string>('disconnected');
  public readonly savedHosts = input<readonly string[]>([]);

  public readonly wsUrlChange = output<string>();
  public readonly connectPressed = output<void>();
  public readonly disconnectPressed = output<void>();
  public readonly connectHost = output<string>();
  public readonly closed = output<void>();

  private readonly wsInputEl = viewChild<ElementRef<HTMLInputElement>>('wsInputEl');

  constructor() {
    effect(() => {
      if (this.autoFocus()) {
        this.wsInputEl()?.nativeElement.focus();
      }
    });
  }

  public focusInput(): void {
    this.wsInputEl()?.nativeElement.focus();
  }

  protected onUrlInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.wsUrlChange.emit(target.value);
    }
  }
}
