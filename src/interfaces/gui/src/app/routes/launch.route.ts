import { ChangeDetectionStrategy, Component, OnInit, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { RpcConnectionStore, resolveWsUrlFromSearch } from '../core/rpc/rpc-connection.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

@Component({
  selector: 'app-launch-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [RouterLink, SectionKickerComponent, StatusDotComponent, TonalButtonComponent],
  template: `
    <div class="launch-canvas">
      <section class="launch-panel" aria-label="Session launch">
        <div class="panel-head">
          <app-section-kicker label="SESSION TARGET" />
          <app-status-dot
            [tone]="rpc.isConnected() ? 'nominal' : rpc.errorMessage() ? 'fault' : 'muted'"
            [label]="rpc.isConnected() ? 'Connected' : rpc.connectionState()"
          />
        </div>

        <h1 class="es-title panel-title">Connect Target Session</h1>
        <p class="es-meta panel-desc">WebSocket RPC · ARM Cortex-M85 / M33</p>

        <div class="connect-row">
          <input
            type="text"
            class="ws-input mono"
            data-testid="launch-ws-input"
            aria-label="WebSocket RPC URL"
            [value]="wsInput()"
            (input)="onUrlInput($event)"
            (keydown.enter)="connectNow()"
            placeholder="ws://127.0.0.1:4567"
          />
          @if (rpc.isConnected()) {
            <app-tonal-button testId="launch-disconnect-btn" (pressed)="rpc.disconnect(true)">
              Disconnect
            </app-tonal-button>
          } @else {
            <app-tonal-button testId="launch-connect-btn" (pressed)="connectNow()">
              Connect
            </app-tonal-button>
          }
        </div>

        @if (rpc.errorMessage()) {
          <p class="error-line" data-testid="launch-error">{{ rpc.errorMessage() }}</p>
        }

        <div class="quick-links">
          <a class="es-ghost-link" routerLink="/debug">Open Debug</a>
          <a class="es-ghost-link" routerLink="/hardware">Open Hardware</a>
          <a class="es-ghost-link" routerLink="/rewind">Open Rewind</a>
          <a class="es-ghost-link" routerLink="/profile">Open Profile</a>
          <a class="es-ghost-link" routerLink="/console">Open Console</a>
        </div>

        @if (workspace.recentWorkspaces().length > 0) {
          <div class="recent-list">
            <app-section-kicker label="WORKSPACE INDEX" />
            @for (item of workspace.recentWorkspaces(); track item.id) {
              <button type="button" class="recent-row" (click)="connectSaved(item.wsUrl)">
                <span class="recent-name">{{ item.name }}</span>
                <span class="es-subline">{{ item.wsUrl }}</span>
              </button>
            }
          </div>
        } @else {
          <p class="es-subline drop-hint">Drop .elf, .board, or .tar.gz anywhere to begin.</p>
        }
      </section>
    </div>
  `,
  styles: [
    `
      .launch-canvas {
        min-height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 32px 24px;
        background: var(--es-canvas);
      }
      .launch-panel {
        width: min(720px, 100%);
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        padding: 24px;
        display: flex;
        flex-direction: column;
        gap: 14px;
      }
      .panel-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
      }
      .panel-title,
      .panel-desc,
      .error-line,
      .drop-hint {
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
      .error-line {
        font-size: 12px;
        color: var(--es-signal-fault);
      }
      .quick-links {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        padding-top: 8px;
        border-top: 1px solid var(--es-divider);
      }
      .recent-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding-top: 8px;
        border-top: 1px solid var(--es-divider);
      }
      .recent-row {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 12px;
        padding: 10px 8px;
        border: 0;
        border-bottom: 1px solid var(--es-divider);
        background: transparent;
        color: var(--es-text-primary);
        text-align: left;
        cursor: pointer;
      }
      .recent-row:hover {
        background: var(--es-interactive);
      }
      .recent-name {
        font-size: 13px;
        font-weight: 500;
      }
    `,
  ],
})
export class LaunchRouteComponent implements OnInit {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly workspace = inject(WorkspaceStore);
  private readonly router = inject(Router);

  protected readonly wsInput = signal<string>(this.rpc.serverUrl());

  public ngOnInit(): void {
    if (typeof window === 'undefined') return;
    const queryUrl = resolveWsUrlFromSearch(window.location.search);
    if (queryUrl) {
      this.wsInput.set(queryUrl);
      void this.connectAndRecord(queryUrl);
    }
  }

  protected onUrlInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) this.wsInput.set(target.value);
  }

  protected connectNow(): void {
    void this.connectAndRecord(this.wsInput());
  }

  protected connectSaved(url: string): void {
    this.wsInput.set(url);
    void this.connectAndRecord(url);
  }

  private async connectAndRecord(url: string): Promise<void> {
    const ok = await this.rpc.connect(url);
    if (ok) {
      this.workspace.addSavedHost(url);
      if (this.router.url.startsWith('/launch')) {
        void this.execution.refreshClock();
      }
    }
  }
}
