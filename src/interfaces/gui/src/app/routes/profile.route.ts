import { ChangeDetectionStrategy, Component, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ProfileStore } from '../core/stores/profile.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-profile-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SplitPaneComponent, SectionKickerComponent],
  template: `
    <app-split-pane primarySize="280px">
      <div pane-primary class="pane-body">
        <app-section-kicker label="METRICS & STACKS" />
        @if (profile.metrics(); as m) {
          <div class="stat-row mono"><span>Host CPU</span><span>{{ m.hostCpuPercent }}%</span></div>
          <div class="stat-row mono"><span>Host RSS</span><span>{{ m.hostRssMb }} MiB</span></div>
          <div class="stat-row mono"><span>CPU0 Load</span><span>{{ m.cpu0LoadPercent }}%</span></div>
        } @else {
          <p class="es-meta note">
            {{ rpc.isConnected() ? 'Awaiting metrics sample...' : 'Connect a session to view telemetry.' }}
          </p>
        }
      </div>
      <div pane-secondary class="pane-body">
        <app-section-kicker label="FOLDED STACK PROFILE" />
        @if (profile.flamegraph().totalSamples > 0) {
          <p class="mono note">{{ profile.flamegraph().totalSamples }} total samples</p>
        } @else {
          <p class="es-meta note">No folded stack samples captured.</p>
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
      .stat-row {
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
export class ProfileRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly profile = inject(ProfileStore);
}
