import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ConsoleStore } from '../core/stores/console.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

@Component({
  selector: 'app-console-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  template: `
    <div class="console-pane">
      <div class="console-head">
        <app-section-kicker label="UART SERIAL STREAM" />
        <app-tonal-button [disabled]="consoleStore.entries().length === 0" (pressed)="consoleStore.clear()">
          Clear
        </app-tonal-button>
      </div>
      @if (consoleStore.filteredEntries().length > 0) {
        <div class="console-log mono">
          @for (entry of consoleStore.filteredEntries(); track entry.id) {
            <div class="log-row">
              <span class="es-meta">[CH{{ entry.channel }}]</span>
              <span>{{ entry.text }}</span>
            </div>
          }
        </div>
      } @else {
        <p class="es-meta empty-note">
          {{ rpc.isConnected() ? 'No UART bytes received yet.' : 'Connect a session to stream UART output.' }}
        </p>
      }
    </div>
  `,
  styles: [
    `
      .console-pane {
        padding: 12px 16px;
        display: flex;
        flex-direction: column;
        gap: 10px;
        height: 100%;
      }
      .console-head {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding-bottom: 8px;
        border-bottom: 1px solid var(--es-divider);
      }
      .console-log {
        flex: 1;
        min-height: 0;
        overflow: auto;
        font-size: 12px;
      }
      .log-row {
        display: flex;
        gap: 8px;
        padding: 2px 0;
        white-space: pre-wrap;
      }
      .empty-note {
        margin: 0;
      }
    `,
  ],
})
export class ConsoleRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly consoleStore = inject(ConsoleStore);
}
