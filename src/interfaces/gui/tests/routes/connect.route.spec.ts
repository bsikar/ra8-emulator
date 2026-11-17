import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { describe, expect, it, beforeEach } from 'vitest';
import { appRoutes } from '../../src/app/app.routes';
import { RpcConnectionStore } from '../../src/app/core/rpc/rpc-connection.store';
import { RemoteHostsStore } from '../../src/app/core/stores/remote-hosts.store';
import { ConnectRouteComponent } from '../../src/app/routes/connect.route';

describe('ConnectRouteComponent (Screen 02)', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('auto-opens SSH Tunnel drawer when ssh:// URL is typed and saves host profile', async () => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const remoteHosts = TestBed.inject(RemoteHostsStore);
    remoteHosts.setProbeForTest(async () => ({ reachable: false, latencyMs: 0, caps: 0 }));

    const fixture = TestBed.createComponent(ConnectRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="connect-live-empty"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="connect-saved-empty"]')).toBeTruthy();

    const input = el.querySelector('[data-testid="connect-url-input"]') as HTMLInputElement;
    input.value = 'ssh://build@10.0.4.18:4569';
    input.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    expect(el.querySelector('[data-testid="connect-ssh-drawer"]')).toBeTruthy();
    expect(el.querySelector('[data-testid="connect-ssh-command"]')?.textContent).toContain(
      'ssh -N -L 4567:127.0.0.1:4569 build@10.0.4.18'
    );

    (el.querySelector('[data-testid="connect-save-ssh-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(remoteHosts.profiles().length).toBe(1);
    expect(remoteHosts.profiles()[0]?.endpointUrl).toBe('ssh://build@10.0.4.18:4569');
  });

  it('validates endpoints, connects live session in Observe mode, and navigates cleanly', async () => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const rpc = TestBed.inject(RpcConnectionStore);
    const remoteHosts = TestBed.inject(RemoteHostsStore);
    remoteHosts.setProbeForTest(async () => ({
      reachable: true,
      latencyMs: 0.3,
      caps: 0,
      title: 'Live Loopback',
      elfName: 'blink.elf',
    }));

    let connectedOpts: { observeOnly?: boolean } | undefined;
    rpc.connect = async (_url, _silent, opts) => {
      connectedOpts = opts;
      rpc.connectionState.set('connected');
      rpc.observeOnly.set(Boolean(opts?.observeOnly));
      return true;
    };

    const fixture = TestBed.createComponent(ConnectRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();
    await remoteHosts.rescanLiveSessions(['ws://127.0.0.1:4567']);
    fixture.detectChanges();
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    const observeBtn = el.querySelector('[data-testid="live-session-observe-0"]') as HTMLButtonElement;
    expect(observeBtn).toBeTruthy();
    observeBtn.click();
    await fixture.whenStable();

    expect(connectedOpts?.observeOnly).toBe(true);
    expect(rpc.observeOnly()).toBe(true);
  });

  it('syncs SSH drawer host and port edits for bare SSH aliases like dev and neo', async () => {
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes)] });
    const remoteHosts = TestBed.inject(RemoteHostsStore);
    remoteHosts.setProbeForTest(async () => ({ reachable: false, latencyMs: 0, caps: 0 }));

    const fixture = TestBed.createComponent(ConnectRouteComponent);
    fixture.autoDetectChanges(true);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    (el.querySelector('[data-testid="connect-ssh-toggle"]') as HTMLButtonElement).click();
    await fixture.whenStable();

    const hostInput = el.querySelector('[data-testid="connect-ssh-host-input"]') as HTMLInputElement;
    const remotePortInput = el.querySelector('[data-testid="connect-ssh-remote-port"]') as HTMLInputElement;
    const localPortInput = el.querySelector('[data-testid="connect-ssh-local-port"]') as HTMLInputElement;

    hostInput.value = 'neo';
    hostInput.dispatchEvent(new Event('input'));
    remotePortInput.value = '4572';
    remotePortInput.dispatchEvent(new Event('input'));
    localPortInput.value = '14572';
    localPortInput.dispatchEvent(new Event('input'));
    await fixture.whenStable();

    expect((el.querySelector('[data-testid="connect-url-input"]') as HTMLInputElement).value).toBe('ssh://neo:4572');
    expect(el.querySelector('[data-testid="connect-ssh-command"]')?.textContent).toContain(
      'ssh -N -L 14572:127.0.0.1:4572 neo'
    );

    (el.querySelector('[data-testid="connect-save-ssh-btn"]') as HTMLButtonElement).click();
    await fixture.whenStable();
    expect(remoteHosts.profiles()[0]?.wsUrl).toBe('ws://127.0.0.1:14572');
    expect(remoteHosts.profiles()[0]?.sshHost).toBe('neo');
  });
});
