import { ChangeDetectionStrategy, Component, OnDestroy, effect, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { ProfileStore } from '../core/stores/profile.store';
import { ProfileFlamegraphPaneComponent } from '../features/profile/profile-flamegraph-pane.component';
import { ProfileMetricsSidebarComponent } from '../features/profile/profile-metrics-sidebar.component';
import { ProfileTimelineCanvasComponent } from '../features/profile/profile-timeline-canvas.component';
import { ProfileTopBarComponent } from '../features/profile/profile-top-bar.component';
import { ProfileViewService } from '../features/profile/profile-view.service';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';

@Component({
  selector: 'app-profile-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    SplitPaneComponent,
    ProfileTopBarComponent,
    ProfileTimelineCanvasComponent,
    ProfileFlamegraphPaneComponent,
    ProfileMetricsSidebarComponent,
  ],
  template: `
    <div class="profile-shell">
      <app-profile-top-bar />
      <div class="profile-body">
        <app-split-pane primarySize="70%" persistKey="profile-main" [minPrimaryPx]="420" [minSecondaryPx]="240">
          <app-split-pane pane-primary direction="vertical" primarySize="44%" persistKey="profile-charts-v" [minPrimaryPx]="160" [minSecondaryPx]="180">
            <app-profile-timeline-canvas pane-primary />
            <app-profile-flamegraph-pane pane-secondary />
          </app-split-pane>
          <app-profile-metrics-sidebar pane-secondary />
        </app-split-pane>
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; min-width: 0; }
      .profile-shell { display: flex; flex-direction: column; height: 100%; min-height: 0; min-width: 0; background: var(--es-canvas); }
      .profile-body { flex: 1; min-height: 0; min-width: 0; }
    `,
  ],
})
export class ProfileRouteComponent implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly profile = inject(ProfileStore);
  private readonly view = inject(ProfileViewService);

  constructor() {
    effect(() => {
      if (this.rpc.isConnected()) {
        this.profile.startMetricsPoll(1000);
        void this.profile.refreshMetrics();
        void this.profile.refreshStacks(this.execution.cpu1Attached());
        void this.view.captureActiveWindow();
      } else {
        this.profile.stopMetricsPoll();
      }
    });
  }

  public ngOnDestroy(): void {
    this.profile.stopMetricsPoll();
  }
}
