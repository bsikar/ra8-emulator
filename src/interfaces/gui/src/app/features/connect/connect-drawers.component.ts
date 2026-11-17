import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { type RemoteAuthMode, buildSshTunnelCommand } from '../../core/stores/remote-hosts.types';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { LaunchIconComponent } from '../launch/launch-icons.component';

@Component({
  selector: 'app-connect-drawers',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [TonalButtonComponent, LaunchIconComponent],
  template: `
    @if (authOpen()) {
      <section class="drawer-card" data-testid="connect-auth-drawer" aria-label="Authentication and profile options">
        <div class="drawer-head">
          <span class="es-kicker">AUTHENTICATION &amp; ATTACH OPTIONS</span>
          <app-tonal-button
            variant="ghost"
            testId="connect-save-profile-btn"
            (pressed)="saveProfile.emit()"
          >
            Save Host Profile
          </app-tonal-button>
        </div>

        <div class="drawer-grid">
          <label class="field">
            <span class="field-label">Auth Mode</span>
            <select
              class="drawer-input"
              data-testid="connect-auth-mode"
              [value]="authMode()"
              (change)="onAuthModeSelect($event)"
            >
              <option value="none">None (Loopback / Trusted LAN)</option>
              <option value="token">Bearer Token · TLS</option>
              <option value="mtls">mTLS Client Certificate</option>
            </select>
          </label>

          <label class="field">
            <span class="field-label">Profile Label (optional)</span>
            <input
              type="text"
              class="drawer-input"
              data-testid="connect-profile-name-input"
              placeholder="e.g. hil-bench-04.local"
              [value]="profileName()"
              (input)="profileNameChange.emit(asInputVal($event))"
            />
          </label>

          <label class="field">
            <span class="field-label">Token / Cert Label</span>
            <input
              type="password"
              class="drawer-input mono"
              data-testid="connect-token-input"
              placeholder="Token hint or cert label"
              [value]="tokenHint()"
              (input)="tokenHintChange.emit(asInputVal($event))"
            />
          </label>
        </div>

        <label class="check-row">
          <input
            type="checkbox"
            data-testid="connect-observe-checkbox"
            [checked]="observeOnly()"
            (change)="observeOnlyChange.emit(asChecked($event))"
          />
          <span>Attach in Observe mode (read-only — execution run/step disabled)</span>
        </label>
      </section>
    }

    @if (sshOpen()) {
      <section class="drawer-card" data-testid="connect-ssh-drawer" aria-label="SSH tunnel port forwarding builder">
        <div class="drawer-head">
          <span class="es-kicker">SSH PORT FORWARDING</span>
          <div class="drawer-actions">
            <app-tonal-button
              variant="ghost"
              testId="connect-copy-ssh-btn"
              (pressed)="copySshCommand.emit(tunnelCommand())"
            >
              <app-launch-icon name="copy" [size]="14" />
              <span>Copy SSH Command</span>
            </app-tonal-button>
            <app-tonal-button
              variant="ghost"
              testId="connect-save-ssh-btn"
              (pressed)="saveProfile.emit()"
            >
              Save Tunnel Profile
            </app-tonal-button>
          </div>
        </div>

        <div class="drawer-grid">
          <label class="field">
            <span class="field-label">Remote SSH Host</span>
            <input
              type="text"
              class="drawer-input mono"
              data-testid="connect-ssh-host-input"
              placeholder="build@10.0.4.18"
              [value]="sshHost()"
              (input)="sshHostChange.emit(asInputVal($event))"
            />
          </label>

          <label class="field">
            <span class="field-label">Remote RPC Port</span>
            <input
              type="number"
              class="drawer-input mono"
              data-testid="connect-ssh-remote-port"
              min="1"
              max="65535"
              [value]="sshRemotePort()"
              (input)="sshRemotePortChange.emit(asPortVal($event, 4567))"
            />
          </label>

          <label class="field">
            <span class="field-label">Local Forward Port</span>
            <input
              type="number"
              class="drawer-input mono"
              data-testid="connect-ssh-local-port"
              min="1"
              max="65535"
              [value]="sshLocalPort()"
              (input)="sshLocalPortChange.emit(asPortVal($event, 4567))"
            />
          </label>
        </div>

        <div class="cmd-box mono" data-testid="connect-ssh-command">{{ tunnelCommand() }}</div>
      </section>
    }
  `,
  styles: [
    `
      .drawer-card {
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        padding: 14px 18px;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }
      .drawer-head,
      .drawer-actions {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
        flex-wrap: wrap;
      }
      .drawer-grid {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 12px;
      }
      .field {
        display: flex;
        flex-direction: column;
        gap: 5px;
      }
      .field-label {
        font-size: 12px;
        color: var(--es-text-muted);
      }
      .drawer-input {
        width: 100%;
        height: 32px;
        padding: 0 10px;
        background: var(--es-chrome);
        border: 1px solid var(--es-border-strong);
        border-radius: var(--es-radius-md);
        color: var(--es-text-primary);
        font-size: 12px;
      }
      .check-row {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        color: var(--es-text-secondary);
        font-size: 12px;
        cursor: pointer;
      }
      .cmd-box {
        background: var(--es-chrome);
        border: 1px solid var(--es-divider);
        border-radius: var(--es-radius-md);
        padding: 8px 12px;
        font-size: 12px;
        color: var(--es-text-secondary);
        overflow-x: auto;
      }
      @media (max-width: 780px) {
        .drawer-grid {
          grid-template-columns: 1fr;
        }
      }
    `,
  ],
})
export class ConnectDrawersComponent {
  public readonly authOpen = input.required<boolean>();
  public readonly sshOpen = input.required<boolean>();
  public readonly authMode = input.required<RemoteAuthMode>();
  public readonly profileName = input<string>('');
  public readonly tokenHint = input<string>('');
  public readonly observeOnly = input<boolean>(false);
  public readonly sshHost = input<string>('');
  public readonly sshRemotePort = input<number>(4567);
  public readonly sshLocalPort = input<number>(4567);

  public readonly authModeChange = output<RemoteAuthMode>();
  public readonly profileNameChange = output<string>();
  public readonly tokenHintChange = output<string>();
  public readonly observeOnlyChange = output<boolean>();
  public readonly sshHostChange = output<string>();
  public readonly sshRemotePortChange = output<number>();
  public readonly sshLocalPortChange = output<number>();
  public readonly saveProfile = output<void>();
  public readonly copySshCommand = output<string>();

  protected readonly tunnelCommand = computed(() =>
    buildSshTunnelCommand(this.sshHost(), this.sshLocalPort(), this.sshRemotePort())
  );

  protected onAuthModeSelect(event: Event): void {
    const val = (event.target as HTMLSelectElement).value;
    if (val === 'token' || val === 'mtls' || val === 'none') {
      this.authModeChange.emit(val);
    }
  }

  protected asInputVal(event: Event): string {
    return (event.target as HTMLInputElement).value;
  }

  protected asChecked(event: Event): boolean {
    return (event.target as HTMLInputElement).checked;
  }

  protected asPortVal(event: Event, fallback: number): number {
    const num = Number.parseInt((event.target as HTMLInputElement).value, 10);
    return Number.isFinite(num) ? Math.min(65535, Math.max(1, num)) : fallback;
  }
}
