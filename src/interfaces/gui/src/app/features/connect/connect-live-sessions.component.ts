import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import type { LiveSessionItem } from '../../core/stores/remote-hosts.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { LaunchIconComponent } from '../launch/launch-icons.component';

@Component({
  selector: 'app-connect-live-sessions',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent, TonalButtonComponent, LaunchIconComponent],
  styleUrl: './connect-cards.css',
  template: `
    <div class="connect-section-head">
      <app-section-kicker label="LIVE SESSIONS" />
      <div class="connect-head-right">
        <button
          type="button"
          class="rescan-btn"
          data-testid="connect-rescan-btn"
          [disabled]="rescanning()"
          (click)="rescan.emit()"
        >
          <app-launch-icon name="refresh" [size]="12" />
          <span data-allow-11px>{{ rescanning() ? 'SCANNING...' : 'RESCAN' }}</span>
        </button>
        <app-section-kicker label="STATUS" />
      </div>
    </div>

    <div class="connect-list" role="listbox" aria-label="Live emulator RPC sessions">
      @if (sessions().length === 0) {
        <div class="empty-row" data-testid="connect-live-empty">
          <div class="empty-copy">
            <span class="empty-title">No active live sessions found on probed endpoints.</span>
            <span class="empty-hint">
              Start an emulator daemon with <span class="mono">--discover</span> or forward an SSH tunnel, then click Rescan.
            </span>
          </div>
          <app-tonal-button
            variant="ghost"
            testId="connect-empty-rescan-btn"
            [disabled]="rescanning()"
            (pressed)="rescan.emit()"
          >
            Rescan
          </app-tonal-button>
        </div>
      } @else {
        @for (session of sessions(); track session.id; let idx = $index) {
          <div
            class="connect-row"
            [class.is-selected]="selectedIndex() === idx"
            [attr.data-testid]="'live-session-row-' + idx"
            (mouseenter)="selectedChange.emit(idx)"
          >
            <button
              type="button"
              class="connect-row-main"
              [attr.data-testid]="'live-session-attach-' + idx"
              (click)="attach.emit({ session, observe: session.status === 'in-use' })"
            >
              <div class="connect-line-top">
                <span class="connect-title">{{ session.title }}</span>
                <span class="connect-meta es-meta">{{ session.archSummary }}</span>
              </div>
              <div class="connect-subline es-subline">
                {{ session.wsUrl }} · {{ session.elfName }}
                @if (session.checkpointCount !== undefined && session.checkpointCount > 0) {
                  <span> · {{ session.checkpointCount }} checkpoints</span>
                }
              </div>
            </button>

            <div class="connect-row-right">
              <app-status-dot
                [tone]="session.status === 'in-use' ? 'cursor' : 'nominal'"
                [label]="statusLabel(session)"
              />

              <button
                type="button"
                class="observe-btn"
                [attr.data-testid]="'live-session-observe-' + idx"
                [attr.aria-label]="'Observe ' + session.title + ' (read-only)'"
                (click)="attach.emit({ session, observe: true })"
              >
                <app-launch-icon name="eye" [size]="13" />
                <span>Observe</span>
              </button>

              <button
                type="button"
                class="icon-btn"
                [class.is-pinned]="session.pinned"
                [attr.data-testid]="'live-session-pin-' + idx"
                aria-label="Pin session"
                (click)="togglePin.emit(session.id)"
              >
                <app-launch-icon name="pin" [size]="14" [filled]="session.pinned" />
              </button>

              <div class="row-menu-wrap" (click)="$event.stopPropagation()">
                <button
                  type="button"
                  class="icon-btn"
                  [attr.data-testid]="'live-session-menu-' + idx"
                  aria-label="Session actions"
                  (click)="toggleMenu(session.id)"
                >
                  <app-launch-icon name="kebab" [size]="14" />
                </button>
                @if (openMenuId() === session.id) {
                  <div class="row-menu" role="menu">
                    <button
                      type="button"
                      class="row-menu-item"
                      (click)="openMenuId.set(null); attach.emit({ session, observe: false })"
                    >
                      Attach (Full Control)
                    </button>
                    <button
                      type="button"
                      class="row-menu-item"
                      (click)="openMenuId.set(null); attach.emit({ session, observe: true })"
                    >
                      Attach Observe Only
                    </button>
                    <button
                      type="button"
                      class="row-menu-item"
                      (click)="openMenuId.set(null); saveAsProfile.emit(session)"
                    >
                      Save Host Profile
                    </button>
                    <button
                      type="button"
                      class="row-menu-item"
                      (click)="openMenuId.set(null); copyUrl.emit(session.wsUrl)"
                    >
                      Copy Endpoint URL
                    </button>
                  </div>
                }
              </div>
            </div>
          </div>
        }
      }
    </div>
  `,
})
export class ConnectLiveSessionsComponent {
  public readonly sessions = input.required<readonly LiveSessionItem[]>();
  public readonly rescanning = input<boolean>(false);
  public readonly selectedIndex = input<number>(0);

  public readonly selectedChange = output<number>();
  public readonly rescan = output<void>();
  public readonly attach = output<{ session: LiveSessionItem; observe: boolean }>();
  public readonly togglePin = output<string>();
  public readonly saveAsProfile = output<LiveSessionItem>();
  public readonly copyUrl = output<string>();

  protected readonly openMenuId = signal<string | null>(null);

  protected statusLabel(session: LiveSessionItem): string {
    if (session.status === 'in-use') return 'In use';
    const kind = session.status === 'loopback' ? 'Loopback' : 'Online';
    return `${kind} · ${session.latencyMs.toFixed(1)} ms`;
  }

  protected toggleMenu(id: string): void {
    this.openMenuId.update((cur) => (cur === id ? null : id));
  }
}
