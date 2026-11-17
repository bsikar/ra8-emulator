import { ChangeDetectionStrategy, Component, input, output, signal } from '@angular/core';
import type { SavedHostProfile } from '../../core/stores/remote-hosts.types';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { formatRelativeTime } from '../launch/launch-commands';
import { LaunchIconComponent } from '../launch/launch-icons.component';

@Component({
  selector: 'app-connect-saved-hosts',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, LaunchIconComponent],
  styleUrl: './connect-cards.css',
  template: `
    <div class="connect-section-head is-secondary">
      <app-section-kicker label="SAVED HOSTS" />
      <app-section-kicker label="LAST CONNECTED" />
    </div>

    <div class="connect-list" role="listbox" aria-label="Saved remote host profiles">
      @if (profiles().length === 0) {
        <div class="empty-row" data-testid="connect-saved-empty">
          <div class="empty-copy">
            <span class="empty-title">No saved host profiles yet.</span>
            <span class="empty-hint">
              Enter a <span class="mono">ws://</span>, <span class="mono">wss://</span>, or <span class="mono">ssh://</span> endpoint above or configure Auth / SSH Tunnel to store reusable hosts.
            </span>
          </div>
        </div>
      } @else {
        @for (profile of profiles(); track profile.id; let idx = $index) {
          <div
            class="connect-row"
            [class.is-selected]="selectedIndex() === liveCount() + idx"
            [attr.data-testid]="'saved-host-row-' + profile.id"
            (mouseenter)="selectedChange.emit(liveCount() + idx)"
          >
            <button
              type="button"
              class="connect-row-main"
              [attr.data-testid]="'saved-host-connect-' + profile.id"
              (click)="connectProfile.emit({ profile, observe: false })"
            >
              <div class="connect-line-top">
                <span class="connect-title">{{ profile.name }}</span>
                <span class="connect-meta es-meta">{{ profile.transportLabel }}</span>
              </div>
              <div class="connect-subline es-subline">
                {{ profile.endpointUrl }}
                @if (profile.lastElf) {
                  <span> · {{ profile.lastElf }}</span>
                }
              </div>
            </button>

            <div class="connect-row-right">
              <span class="es-meta mono">{{ lastConnectedLabel(profile) }}</span>

              <button
                type="button"
                class="icon-btn"
                [class.is-pinned]="profile.pinned"
                [attr.data-testid]="'saved-host-pin-' + profile.id"
                aria-label="Pin host profile"
                (click)="togglePin.emit(profile.id)"
              >
                <app-launch-icon name="pin" [size]="14" [filled]="profile.pinned" />
              </button>

              <div class="row-menu-wrap" (click)="$event.stopPropagation()">
                <button
                  type="button"
                  class="icon-btn"
                  [attr.data-testid]="'saved-host-menu-' + profile.id"
                  aria-label="Host profile actions"
                  (click)="toggleMenu(profile.id)"
                >
                  <app-launch-icon name="kebab" [size]="14" />
                </button>
                @if (openMenuId() === profile.id) {
                  <div class="row-menu" role="menu">
                    <button
                      type="button"
                      class="row-menu-item"
                      (click)="openMenuId.set(null); connectProfile.emit({ profile, observe: false })"
                    >
                      Connect
                    </button>
                    <button
                      type="button"
                      class="row-menu-item"
                      [attr.data-testid]="'saved-host-observe-' + profile.id"
                      (click)="openMenuId.set(null); connectProfile.emit({ profile, observe: true })"
                    >
                      Connect Observe Only
                    </button>
                    @if (profile.sshHost) {
                      <button
                        type="button"
                        class="row-menu-item"
                        (click)="openMenuId.set(null); openTunnel.emit(profile)"
                      >
                        Prepare SSH Tunnel
                      </button>
                    }
                    <button
                      type="button"
                      class="row-menu-item is-danger"
                      [attr.data-testid]="'saved-host-remove-' + profile.id"
                      (click)="openMenuId.set(null); remove.emit(profile.id)"
                    >
                      Remove Profile
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
export class ConnectSavedHostsComponent {
  public readonly profiles = input.required<readonly SavedHostProfile[]>();
  public readonly liveCount = input<number>(0);
  public readonly selectedIndex = input<number>(0);

  public readonly selectedChange = output<number>();
  public readonly connectProfile = output<{ profile: SavedHostProfile; observe: boolean }>();
  public readonly openTunnel = output<SavedHostProfile>();
  public readonly togglePin = output<string>();
  public readonly remove = output<string>();

  protected readonly openMenuId = signal<string | null>(null);

  protected lastConnectedLabel(profile: SavedHostProfile): string {
    const rel = profile.lastConnectedIso ? formatRelativeTime(profile.lastConnectedIso) : 'Saved';
    return profile.lastStatus === 'offline' ? `Offline · ${rel}` : rel;
  }

  protected toggleMenu(id: string): void {
    this.openMenuId.update((cur) => (cur === id ? null : id));
  }
}
