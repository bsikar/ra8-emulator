import { ChangeDetectionStrategy, Component, effect, inject } from '@angular/core';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { DebugStore } from '../core/stores/debug.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { PreferencesStore, type WorkbenchLayoutMode } from '../core/stores/preferences.store';
import { ProfileStore } from '../core/stores/profile.store';
import { DebugBoardSidebarComponent } from '../features/debug/debug-board-sidebar.component';
import { DebugCodePaneComponent } from '../features/debug/debug-code-pane.component';
import { DebugInspectorPaneComponent } from '../features/debug/debug-inspector-pane.component';
import { DebugLocalsPaneComponent } from '../features/debug/debug-locals-pane.component';
import { DebugTargetsStackComponent } from '../features/debug/debug-targets-stack.component';
import { SplitPaneComponent } from '../shared/ui/split-pane.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

@Component({
  selector: 'app-debug-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    SplitPaneComponent,
    StatusDotComponent,
    TonalButtonComponent,
    DebugTargetsStackComponent,
    DebugCodePaneComponent,
    DebugLocalsPaneComponent,
    DebugInspectorPaneComponent,
    DebugBoardSidebarComponent,
  ],
  template: `
    <div class="debug-shell">
      <div class="debug-toolbar">
        <div class="toolbar-left">
          <div class="layout-switcher" data-testid="debug-layout-switcher">
            <button type="button" class="sw-tab" [class.is-active]="layout() === 'board'" data-testid="layout-board-btn" (click)="setLayout('board')">Board</button>
            <button type="button" class="sw-tab" [class.is-active]="layout() === 'debugger'" data-testid="layout-debugger-btn" (click)="setLayout('debugger')">Debugger</button>
            <button type="button" class="sw-tab" [class.is-active]="layout() === 'split'" data-testid="layout-split-btn" (click)="setLayout('split')">Split</button>
          </div>
          <app-status-dot
            [tone]="rpc.isConnected() ? (execution.isRunning() ? 'cursor' : 'nominal') : 'muted'"
            [label]="execution.executionStatus()"
          />
          @if (rpc.observeOnly()) {
            <span class="observe-pill" data-testid="debug-observe-pill">OBSERVE · Read-Only</span>
          }
        </div>

        <div class="toolbar-right">
          <app-tonal-button
            testId="debug-step-btn"
            [disabled]="!rpc.isConnected() || execution.isRunning() || rpc.observeOnly()"
            (pressed)="execution.step(debug.activeCore())"
          >
            Step
          </app-tonal-button>
          <app-tonal-button
            testId="debug-step-over-btn"
            [disabled]="!rpc.isConnected() || execution.isRunning() || rpc.observeOnly()"
            (pressed)="execution.stepOver(debug.activeCore())"
          >
            Step Over
          </app-tonal-button>
          <app-tonal-button
            testId="debug-step-out-btn"
            [disabled]="!rpc.isConnected() || execution.isRunning() || rpc.observeOnly()"
            (pressed)="execution.stepOut(debug.activeCore())"
          >
            Step Out
          </app-tonal-button>
          <app-tonal-button
            testId="debug-run-btn"
            [disabled]="!rpc.isConnected() || rpc.observeOnly()"
            (pressed)="toggleRun()"
          >
            {{ execution.isRunning() ? 'Pause' : 'Continue' }}
          </app-tonal-button>
          <app-tonal-button
            testId="debug-reset-btn"
            [disabled]="!rpc.isConnected() || rpc.observeOnly()"
            (pressed)="execution.resetImage()"
          >
            Reset
          </app-tonal-button>
        </div>
      </div>

      <div class="debug-body">
        @if (layout() === 'board') {
          <app-split-pane primarySize="340px" persistKey="debug-board-only" [minPrimaryPx]="240" [minSecondaryPx]="320">
            <app-debug-inspector-pane pane-primary />
            <app-debug-board-sidebar pane-secondary />
          </app-split-pane>
        } @else if (layout() === 'debugger') {
          <app-split-pane primarySize="240px" persistKey="debug-left" [minPrimaryPx]="180" [minSecondaryPx]="420">
            <app-debug-targets-stack pane-primary />
            <app-split-pane pane-secondary direction="vertical" primarySize="54%" persistKey="debug-center-v" [minPrimaryPx]="160" [minSecondaryPx]="150">
              <app-debug-code-pane pane-primary />
              <app-split-pane pane-secondary primarySize="45%" persistKey="debug-bottom-h" [minPrimaryPx]="200" [minSecondaryPx]="240">
                <app-debug-locals-pane pane-primary />
                <app-debug-inspector-pane pane-secondary />
              </app-split-pane>
            </app-split-pane>
          </app-split-pane>
        } @else {
          <app-split-pane primarySize="230px" persistKey="debug-left" [minPrimaryPx]="180" [minSecondaryPx]="520">
            <app-debug-targets-stack pane-primary />
            <app-split-pane pane-secondary primarySize="73%" persistKey="debug-right" [minPrimaryPx]="420" [minSecondaryPx]="220">
              <app-split-pane pane-primary direction="vertical" primarySize="54%" persistKey="debug-center-v" [minPrimaryPx]="160" [minSecondaryPx]="150">
                <app-debug-code-pane pane-primary />
                <app-split-pane pane-secondary primarySize="44%" persistKey="debug-bottom-h" [minPrimaryPx]="180" [minSecondaryPx]="220">
                  <app-debug-locals-pane pane-primary />
                  <app-debug-inspector-pane pane-secondary />
                </app-split-pane>
              </app-split-pane>
              <app-debug-board-sidebar pane-secondary />
            </app-split-pane>
          </app-split-pane>
        }
      </div>
    </div>
  `,
  styles: [
    `
      :host { display: block; height: 100%; min-height: 0; }
      .debug-shell { display: flex; flex-direction: column; height: 100%; min-width: 0; background: var(--es-canvas); }
      .debug-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--es-border); background: var(--es-chrome); flex-wrap: wrap; }
      .toolbar-left, .toolbar-right { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .layout-switcher { display: inline-flex; border: 1px solid var(--es-border); border-radius: var(--es-radius); overflow: hidden; background: var(--es-container); }
      .sw-tab { border: 0; background: transparent; color: var(--es-text-muted); font-size: 12px; padding: 3px 10px; cursor: pointer; }
      .sw-tab.is-active { background: var(--es-interactive); color: var(--es-text-primary); }
      .observe-pill { padding: 2px 8px; border-radius: var(--es-radius-sm); border: 1px solid var(--es-signal-cursor); color: var(--es-signal-cursor); font-size: 12px; }
      .debug-body { flex: 1; min-height: 0; min-width: 0; }
    `,
  ],
})
export class DebugRouteComponent {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly debug = inject(DebugStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly prefs = inject(PreferencesStore);
  private readonly profile = inject(ProfileStore);

  protected readonly layout = () => this.prefs.prefs().workbenchLayout;

  constructor() {
    effect(() => {
      if (this.execution.inspectionEpoch() > 0 && this.rpc.isConnected()) {
        void this.profile.refreshStacks(this.execution.cpu1Attached());
      }
    });
  }

  protected setLayout(mode: WorkbenchLayoutMode): void {
    this.prefs.setWorkbenchLayout(mode);
  }

  protected toggleRun(): void {
    if (this.execution.isRunning()) void this.execution.pause();
    else void this.execution.run();
  }
}
