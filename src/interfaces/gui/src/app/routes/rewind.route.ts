import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { RewindStore } from '../core/stores/rewind.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-rewind-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, SectionKickerComponent],
  template: `
    <app-split-pane primarySize="280px">
      <div pane-primary class="pane-body">
        <app-section-kicker label="EXECUTION BRANCHES" />
        @if (rewind.branches().length > 0) {
          @for (branch of rewind.branches(); track branch.id) {
            <div class="branch-row">
              <span class="mono">Branch #{{ branch.id }}</span>
              <span class="es-meta">{{ branch.isLive ? 'LIVE' : 'SAVED' }}</span>
            </div>
          }
        } @else {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'History recording disabled (start serve with --history).' : 'Connect a session to inspect branches.' }}
          </p>
        }
      </div>
      <div pane-secondary class="pane-body">
        <app-section-kicker label="STATE DIFF" />
        @if (rewind.diffRows().length > 0) {
          @for (row of rewind.diffRows(); track row.entity) {
            <div class="branch-row mono">
              <span>{{ row.entity }}</span>
              <span>{{ row.beforeVal }} -> {{ row.afterVal }}</span>
            </div>
          }
        } @else {
          <p class="es-meta note">No checkpoint diff loaded.</p>
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
      .branch-row {
        display: flex;
        justify-content: space-between;
        padding: 6px 0;
        border-bottom: 1px solid var(--es-divider);
        font-size: 12px;
      }
      .note {
        margin: 0;
      }
    `,
  ],
})
export class RewindRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly rewind = inject(RewindStore);
}
