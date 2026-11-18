import { ChangeDetectionStrategy, Component, OnDestroy, effect, inject } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { ProfileStore } from '../core/stores/profile.store';
import { ProfileFlamegraphPaneComponent } from '../features/profile/profile-flamegraph-pane.component';
import { ProfileMetricsSidebarComponent } from '../features/profile/profile-metrics-sidebar.component';
import { ProfileTimelineCanvasComponent } from '../features/profile/profile-timeline-canvas.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-profile-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    SplitPaneComponent,
    ProfileTimelineCanvasComponent,
    ProfileFlamegraphPaneComponent,
    ProfileMetricsSidebarComponent,
  ],
  template: `
    <div class="profile-shell">
      <app-split-pane primarySize="70%" persistKey="profile-main" [minPrimaryPx]="420" [minSecondaryPx]="240">
        <app-split-pane pane-primary direction="vertical" primarySize="44%" persistKey="profile-charts-v" [minPrimaryPx]="160" [minSecondaryPx]="180">
          <app-profile-timeline-canvas pane-primary />
          <app-profile-flamegraph-pane pane-secondary />
        </app-split-pane>
        <app-profile-metrics-sidebar pane-secondary />
      </app-split-pane>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; }
      .profile-shell { height: 100%; min-height: 0; min-width: 0; background: var(--es-canvas); }
    `,
  ],
})
export class ProfileRouteComponent implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly profile = inject(ProfileStore);

  constructor() {
    effect(() => {
      if (this.rpc.isConnected()) {
        this.profile.startMetricsPoll(1000);
        void this.profile.refreshMetrics();
        void this.profile.refreshStacks(this.execution.cpu1Attached());
        void this.profile.captureFolded(Core.Cpu0);
      } else {
        this.profile.stopMetricsPoll();
      }
    });
  }

  public ngOnDestroy(): void {
    this.profile.stopMetricsPoll();
  }
}
