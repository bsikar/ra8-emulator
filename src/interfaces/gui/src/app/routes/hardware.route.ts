import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { HardwareHilStore } from '../core/stores/hardware-hil.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-hardware-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, SectionKickerComponent],
  template: `
    <app-split-pane primarySize="300px">
      <div pane-primary class="pane-body">
        <app-section-kicker label="FITTED PARTS" />
        @if (hil.fittedParts().length > 0) {
          @for (part of hil.fittedParts(); track part.endpoint) {
            <div class="item-row">
              <span class="mono">{{ part.spec }}</span>
              @if (part.activeFault) {
                <span class="fault-note mono">{{ part.activeFault }}</span>
              }
            </div>
          }
        } @else {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'No external parts fitted.' : 'Connect a session to inspect HIL peripherals.' }}
          </p>
        }
      </div>
      <div pane-secondary class="pane-body">
        <app-section-kicker label="PERIPHERAL INSPECTOR" />
        @if (hil.selectedPeriphText()) {
          <pre class="mono periph-pre">{{ hil.selectedPeriphText() }}</pre>
        } @else {
          <p class="es-meta note">Select a peripheral block once connected.</p>
        }
      </div>
    </app-split-pane>
  `,
  styles: [
    `
      .pane-body {
        padding: 12px 16px;
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .item-row {
        display: flex;
        justify-content: space-between;
        padding: 6px 0;
        border-bottom: 1px solid var(--es-divider);
        font-size: 12px;
      }
      .fault-note {
        color: var(--es-signal-fault);
      }
      .periph-pre,
      .note {
        margin: 0;
        font-size: 12px;
      }
    `,
  ],
})
export class HardwareRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly hil = inject(HardwareHilStore);
}
