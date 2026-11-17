import {
  ChangeDetectionStrategy,
  Component,
  type ElementRef,
  OnInit,
  computed,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { Router } from '@angular/router';
import { DEFAULT_RPC_URL } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { RemoteHostsStore } from '../core/stores/remote-hosts.store';
import {
  type LiveSessionItem,
  type RemoteAuthMode,
  SERVE_DISCOVER_COMMAND,
  type SavedHostProfile,
  deriveProfileName,
  parseRemoteEndpoint,
} from '../core/stores/remote-hosts.types';
import { VimStore } from '../core/vim/vim.store';
import { ConnectDrawersComponent } from '../features/connect/connect-drawers.component';
import { ConnectLiveSessionsComponent } from '../features/connect/connect-live-sessions.component';
import { ConnectSavedHostsComponent } from '../features/connect/connect-saved-hosts.component';
import { LaunchIconComponent } from '../features/launch/launch-icons.component';
import { CommandModeStore, isEditableEventTarget } from '../shell/command-mode.store';
import { SearchEverywhereStore } from '../core/search/search-everywhere.store';

@Component({
  selector: 'app-connect-route',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    LaunchIconComponent,
    ConnectDrawersComponent,
    ConnectLiveSessionsComponent,
    ConnectSavedHostsComponent,
  ],
  templateUrl: './connect.route.html',
  styleUrl: './connect.route.css',
  host: {
    '(window:keydown.escape)': 'onWindowEscape($event)',
    '(window:keydown)': 'onWindowKeyDown($event)',
  },
})
export class ConnectRouteComponent implements OnInit {
  private readonly router = inject(Router);
  private readonly cmdMode = inject(CommandModeStore);
  private readonly searchEverywhere = inject(SearchEverywhereStore);
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);
  protected readonly vim = inject(VimStore);

  private readonly urlInputEl = viewChild<ElementRef<HTMLInputElement>>('urlInputEl');
  private pendingG = false;

  protected readonly endpointInput = signal<string>(DEFAULT_RPC_URL);
  protected readonly validationError = signal<string | null>(null);
  protected readonly authOpen = signal<boolean>(false);
  protected readonly sshOpen = signal<boolean>(false);
  protected readonly authMode = signal<RemoteAuthMode>('none');
  protected readonly profileName = signal<string>('');
  protected readonly tokenHint = signal<string>('');
  protected readonly observeOnly = signal<boolean>(false);
  protected readonly sshHost = signal<string>('');
  protected readonly sshRemotePort = signal<number>(4567);
  protected readonly sshLocalPort = signal<number>(4567);
  protected readonly selectedIndex = signal<number>(0);

  protected readonly serveCommand = SERVE_DISCOVER_COMMAND;
  protected readonly totalItems = computed(
    () => this.remoteHosts.liveSessions().length + this.remoteHosts.profiles().length
  );

  public ngOnInit(): void {
    const initial = this.rpc.isConnected() ? this.rpc.serverUrl() : '';
    this.endpointInput.set(initial);
    this.observeOnly.set(this.rpc.observeOnly());
    void this.remoteHosts.rescanLiveSessions();
    queueMicrotask(() => this.urlInputEl()?.nativeElement.focus());
  }

  protected goBack(): void {
    void this.router.navigateByUrl('/launch');
  }

  protected onEndpointInput(event: Event): void {
    const target = event.target;
    if (!(target instanceof HTMLInputElement)) return;
    const raw = target.value;
    this.endpointInput.set(raw);
    this.validationError.set(null);
    const parsed = parseRemoteEndpoint(raw, this.sshLocalPort());
    if (parsed.valid && parsed.scheme === 'ssh') {
      this.sshHost.set(parsed.sshUserHost);
      this.sshRemotePort.set(parsed.port);
      this.sshOpen.set(true);
    }
  }

  protected onUrlKeyDown(event: KeyboardEvent): void {
    if (event.key === 'Enter') {
      event.preventDefault();
      void this.connectFromInput();
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.moveSelection(1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.moveSelection(-1);
    }
  }

  protected toggleAuthDrawer(): void {
    this.authOpen.update((v) => !v);
  }

  protected toggleSshDrawer(): void {
    this.sshOpen.update((v) => !v);
  }

  protected onSshHostChange(host: string): void {
    this.sshHost.set(host);
    const clean = host.trim();
    const cur = this.endpointInput().trim().toLowerCase();
    if (clean && (!cur || cur.startsWith('ssh://'))) {
      this.endpointInput.set(`ssh://${clean}:${this.sshRemotePort()}`);
    }
  }

  protected onSshRemotePortChange(port: number): void {
    this.sshRemotePort.set(port);
    const clean = this.sshHost().trim();
    const cur = this.endpointInput().trim().toLowerCase();
    if (clean && (!cur || cur.startsWith('ssh://'))) {
      this.endpointInput.set(`ssh://${clean}:${port}`);
    }
  }

  protected onSshLocalPortChange(port: number): void {
    this.sshLocalPort.set(port);
  }

  protected rescan(): void {
    const parsed = parseRemoteEndpoint(this.endpointInput(), this.sshLocalPort());
    const extra = parsed.valid ? [parsed.wsUrl] : [];
    void this.remoteHosts.rescanLiveSessions(extra);
  }

  protected saveCurrentProfile(): void {
    const raw = this.endpointInput().trim() || (this.sshHost().trim() ? `ssh://${this.sshHost().trim()}:${this.sshRemotePort()}` : '');
    const parsed = parseRemoteEndpoint(raw, this.sshLocalPort());
    if (!parsed.valid) {
      this.validationError.set(parsed.reason ?? 'Invalid remote endpoint');
      return;
    }
    const saved = this.remoteHosts.saveProfile({
      endpointUrl: parsed.normalizedInput,
      name: this.profileName(),
      authMode: this.authMode(),
      tokenHint: this.tokenHint(),
      sshLocalPort: this.sshLocalPort(),
    });
    if (saved) {
      this.endpointInput.set(saved.endpointUrl);
      this.validationError.set(null);
      this.rpc.pushToast(`Saved host profile ${saved.name}`, 'neutral');
    }
  }

  protected async connectFromInput(): Promise<void> {
    const raw = this.endpointInput().trim() || (this.sshHost().trim() ? `ssh://${this.sshHost().trim()}:${this.sshRemotePort()}` : '');
    const parsed = parseRemoteEndpoint(raw, this.sshLocalPort());
    if (!parsed.valid) {
      this.validationError.set(parsed.reason ?? 'Enter a ws://, wss://, or ssh:// endpoint');
      return;
    }
    this.validationError.set(null);
    const name = deriveProfileName(parsed, this.profileName());
    const ok = await this.rpc.connect(parsed.wsUrl, false, {
      observeOnly: this.observeOnly(),
      profileName: name,
    });
    if (!ok) return;
    this.remoteHosts.recordConnected(parsed.normalizedInput, {
      name,
      authMode: this.authMode(),
      tokenHint: this.tokenHint(),
      sshLocalPort: this.sshLocalPort(),
      latencyMs: this.rpc.lastHandshakeMs() ?? undefined,
      status: this.observeOnly() ? 'in-use' : parsed.isLoopback ? 'loopback' : 'online',
    });
    await this.router.navigateByUrl('/debug');
  }

  protected async attachLiveSession(payload: { session: LiveSessionItem; observe: boolean }): Promise<void> {
    this.endpointInput.set(payload.session.wsUrl);
    this.observeOnly.set(payload.observe);
    const ok = await this.rpc.connect(payload.session.wsUrl, false, {
      observeOnly: payload.observe,
      profileName: payload.session.title,
      handshakeMs: payload.session.latencyMs,
    });
    if (!ok) return;
    this.remoteHosts.recordConnected(payload.session.wsUrl, {
      name: payload.session.title,
      latencyMs: payload.session.latencyMs,
      status: payload.observe ? 'in-use' : payload.session.status,
      elfName: payload.session.elfName,
      archSummary: payload.session.archSummary,
    });
    await this.router.navigateByUrl('/debug');
  }

  protected async connectSavedHost(payload: { profile: SavedHostProfile; observe: boolean }): Promise<void> {
    const p = payload.profile;
    this.endpointInput.set(p.endpointUrl);
    this.profileName.set(p.name);
    this.authMode.set(p.authMode);
    this.observeOnly.set(payload.observe);
    if (p.sshHost) {
      this.sshHost.set(p.sshHost);
      this.sshRemotePort.set(p.sshRemotePort ?? 4567);
      this.sshLocalPort.set(p.sshLocalPort ?? 4567);
    }
    const ok = await this.rpc.connect(p.wsUrl, false, {
      observeOnly: payload.observe,
      profileName: p.name,
    });
    if (!ok) return;
    this.remoteHosts.recordConnected(p.endpointUrl, {
      name: p.name,
      authMode: p.authMode,
      tokenHint: p.tokenHint,
      sshLocalPort: p.sshLocalPort,
      latencyMs: this.rpc.lastHandshakeMs() ?? undefined,
      status: payload.observe ? 'in-use' : undefined,
    });
    await this.router.navigateByUrl('/debug');
  }

  protected openTunnelDrawerForProfile(profile: SavedHostProfile): void {
    this.endpointInput.set(profile.endpointUrl);
    this.sshHost.set(profile.sshHost ?? '');
    this.sshRemotePort.set(profile.sshRemotePort ?? 4567);
    this.sshLocalPort.set(profile.sshLocalPort ?? 4567);
    this.sshOpen.set(true);
  }

  protected saveSessionAsProfile(session: LiveSessionItem): void {
    const saved = this.remoteHosts.saveProfile({
      endpointUrl: session.wsUrl,
      name: session.title,
      pinned: session.pinned,
    });
    if (saved) this.rpc.pushToast(`Saved host profile ${saved.name}`, 'neutral');
  }

  protected copyText(text: string, label = 'Copied to clipboard'): void {
    if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(text);
    }
    this.rpc.pushToast(label, 'neutral');
  }

  protected onWindowEscape(event: KeyboardEvent): void {
    if (event.defaultPrevented || this.cmdMode.hasOpenOverlay() || this.searchEverywhere.open()) return;
    if (this.authOpen() || this.sshOpen()) {
      event.preventDefault();
      this.authOpen.set(false);
      this.sshOpen.set(false);
    }
  }

  protected onWindowKeyDown(event: KeyboardEvent): void {
    if (!this.vim.enabled() || this.vim.mode() !== 'normal') return;
    if (this.cmdMode.hasOpenOverlay() || this.searchEverywhere.open()) return;
    if (isEditableEventTarget(event.target)) return;
    const count = this.totalItems();
    if (count === 0) return;
    if (event.key === 'j') {
      event.preventDefault();
      this.moveSelection(1);
    } else if (event.key === 'k') {
      event.preventDefault();
      this.moveSelection(-1);
    } else if (event.key === 'G') {
      event.preventDefault();
      this.selectedIndex.set(count - 1);
    } else if (event.key === 'g') {
      event.preventDefault();
      if (this.pendingG) {
        this.pendingG = false;
        this.selectedIndex.set(0);
      } else {
        this.pendingG = true;
      }
      return;
    } else if (event.key === 'Enter') {
      event.preventDefault();
      this.activateSelected();
    }
    this.pendingG = false;
  }

  private moveSelection(delta: number): void {
    const count = this.totalItems();
    if (count === 0) return;
    this.selectedIndex.update((i) => (i + delta + count) % count);
  }

  private activateSelected(): void {
    const idx = this.selectedIndex();
    const live = this.remoteHosts.liveSessions();
    if (idx < live.length) {
      const target = live[idx];
      if (target) void this.attachLiveSession({ session: target, observe: target.status === 'in-use' });
      return;
    }
    const profile = this.remoteHosts.profiles()[idx - live.length];
    if (profile) void this.connectSavedHost({ profile, observe: false });
  }
}
