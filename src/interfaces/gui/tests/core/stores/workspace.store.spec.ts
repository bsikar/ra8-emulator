import { TestBed } from '@angular/core/testing';
import {
  CAP_BUILD,
  CAP_PROJECT,
  CAP_TARGETS,
  CAP_WORKSPACE,
  TargetAction,
  WorkspaceEntryKind,
} from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { WorkspaceStore } from '../../../src/app/core/stores/workspace.store';

describe('WorkspaceStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('persists recent workspaces, pins them to top, and tracks saved hosts', () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(WorkspaceStore);

    store.recordRecentWorkspace({
      id: 'ws1',
      name: 'RA8D2 Blink',
      path: '/work/blink',
      wsUrl: 'ws://127.0.0.1:4567',
      pinned: false,
    });
    store.recordRecentWorkspace({
      id: 'ws2',
      name: 'RA8P1 Dual',
      path: '/work/dual',
      wsUrl: 'ws://127.0.0.1:5000',
      pinned: false,
    });

    expect(store.recentWorkspaces().map((w) => w.id)).toEqual(['ws2', 'ws1']);
    store.togglePinWorkspace('ws1');
    expect(store.recentWorkspaces().map((w) => w.id)).toEqual(['ws1', 'ws2']);
    expect(store.savedHosts()).toContain('ws://127.0.0.1:5000');

    store.removeWorkspace('ws2');
    expect(store.recentWorkspaces().map((w) => w.id)).toEqual(['ws1']);
  });

  it('gates workspace, build, project, and target RPC wrappers by capability flags', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const store = TestBed.inject(WorkspaceStore);

    const calls: string[] = [];
    const fakeClient = {
      workspaceList: async () => {
        calls.push('workspaceList');
        return { offset: 0, count: 1, more: false, entriesJson: '[]', entries: [{ name: 'main.c', kind: 'file' as const }] };
      },
      workspaceStat: async () => ({ kind: WorkspaceEntryKind.File, size: 12n, modifiedNs: 0n, identity: 1n }),
      workspaceRead: async () => ({
        version: { kind: WorkspaceEntryKind.File, size: 12n, modifiedNs: 0n, identity: 1n },
        versionBytes: new Uint8Array(25),
        eof: true,
        bytes: new Uint8Array(0),
      }),
      workspaceWrite: async () => ({ kind: WorkspaceEntryKind.File, size: 4n, modifiedNs: 1n, identity: 2n }),
      workspaceWatch: async () => 7,
      workspaceUnwatch: async () => true,
      buildStart: async () => 42n,
      buildStatus: async () => ({ id: 42n, done: true, result: 'ok' }),
      buildCancel: async () => true,
      projectOpen: async () => true,
      projectClose: async () => true,
      projectBuild: async () => 43n,
      projectPrepare: async () => ({ receipt: 'ready:app.elf' }),
      targetsList: async () => ({
        json: '[]',
        targets: [
          {
            generation: 3,
            reserved: false,
            target: {
              host_id: 'h1',
              probe_id: 'p1',
              board_id: 'b1',
              probe_serial: '123',
              board_serial: '456',
              vendor: 'Renesas',
              model: 'EK-RA8D2',
              cores: '2',
              transport: 'swd',
              connection: 'connected' as const,
              disambiguation: '',
              identity_verified: true,
              managed: true,
              operations: ['registers'],
              capabilities: { build: true, flash: true, hardware_debug: true, emulation: false, npu: false },
            },
          },
        ],
      }),
      targetsReserve: async () => true,
      targetsRelease: async () => true,
      targetsPerform: async () => 'r0=0x00000001',
    };

    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });
    expect(await store.listWorkspace('.')).toBeNull();
    expect(calls).toEqual([]);

    rpc.serverCaps.set(CAP_WORKSPACE | CAP_BUILD | CAP_PROJECT | CAP_TARGETS);
    expect((await store.listWorkspace('.'))?.entries[0]?.name).toBe('main.c');
    expect(await store.watchWorkspace('.')).toBe(7);
    expect(await store.unwatchWorkspace(7)).toBe(true);
    expect(await store.startBuild({ step: 'firmware' })).toBe(42n);
    expect((await store.pollBuildStatus())?.result).toBe('ok');
    expect(await store.openProject('{"board":"ek_ra8d2"}')).toBe(true);
    expect(await store.buildProject('debug')).toBe(43n);
    expect((await store.prepareProject(43n))?.receipt).toBe('ready:app.elf');
    expect((await store.refreshTargets()).length).toBe(1);
    const sel = { hostId: 'h1', probeId: 'p1', boardId: 'b1', generation: 3n, disambiguation: '' };
    expect(await store.reserveTarget(sel)).toBe(true);
    expect(await store.performTarget({ ...sel, action: TargetAction.Registers })).toBe('r0=0x00000001');
    expect(await store.releaseTarget()).toBe(true);
    expect(await store.closeProject()).toBe(true);
  });
});
