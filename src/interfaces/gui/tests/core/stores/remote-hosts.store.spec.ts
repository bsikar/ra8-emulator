import { TestBed } from '@angular/core/testing';
import { describe, expect, it, beforeEach } from 'vitest';
import { CAP_TRANSPORT } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { RemoteHostsStore } from '../../../src/app/core/stores/remote-hosts.store';

describe('RemoteHostsStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('starts honestly empty with zero hardcoded remote profiles', () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(RemoteHostsStore);
    expect(store.profiles()).toEqual([]);
    expect(store.liveSessions()).toEqual([]);
  });

  it('saves, pins, persists, and removes ws://, wss://, and ssh:// profiles', () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(RemoteHostsStore);

    const ssh = store.saveProfile({
      endpointUrl: 'ssh://build@10.0.4.18:4568',
      name: 'ci-runner-arm-02',
      sshLocalPort: 4590,
    });
    const wss = store.saveProfile({
      endpointUrl: 'wss://hil-rack-04.lab:8443/rpc',
      name: 'hil-bench-04.local',
      authMode: 'token',
    });

    expect(ssh?.wsUrl).toBe('ws://127.0.0.1:4590');
    expect(ssh?.transportLabel).toBe('SSH Tunnel · Remote Workspace');
    expect(wss?.transportLabel).toBe('Token Auth · TLS');

    store.togglePinProfile(ssh!.id);
    expect(store.profiles()[0]?.id).toBe(ssh!.id);
    expect(store.profiles()[0]?.pinned).toBe(true);

    store.removeProfile(wss!.id);
    expect(store.profiles().length).toBe(1);
    expect(localStorage.getItem('ra8.hostProfiles.v1')).toContain('ci-runner-arm-02');
  });

  it('probes candidate endpoints on rescanLiveSessions and updates saved profile health + latency', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    rpc.connectionState.set('disconnected');
    const store = TestBed.inject(RemoteHostsStore);

    const up = store.saveProfile({ endpointUrl: 'ws://127.0.0.1:4567', name: 'EK-RA8D2 Local' });
    const down = store.saveProfile({ endpointUrl: 'wss://offline-bench.local:8443/rpc', name: 'hil-offline' });

    store.setProbeForTest(async (wsUrl) => {
      if (wsUrl === 'ws://127.0.0.1:4567') {
        return {
          reachable: true,
          latencyMs: 0.4,
          caps: CAP_TRANSPORT,
          elfName: 'blink.elf',
          archSummary: 'Cortex-M85 + State',
        };
      }
      return { reachable: false, latencyMs: 0, caps: 0 };
    });

    const live = await store.rescanLiveSessions();
    expect(live.length).toBe(1);
    expect(live[0]?.title).toBe('EK-RA8D2 Local');
    expect(live[0]?.status).toBe('loopback');
    expect(live[0]?.latencyMs).toBe(0.4);
    expect(store.lastScanIso()).toBeTruthy();

    const refreshedUp = store.profiles().find((p) => p.id === up!.id);
    const refreshedDown = store.profiles().find((p) => p.id === down!.id);
    expect(refreshedUp?.lastStatus).toBe('loopback');
    expect(refreshedDown?.lastStatus).toBe('offline');
  });
});
