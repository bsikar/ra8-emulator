import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { CAP_WORKSPACE, Core, ErrorCode, RpcCallError } from 'ra8-rpc-client';
import { beforeEach, describe, expect, it } from 'vitest';
import { appRoutes } from '../../../src/app/app.routes';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { BoardStore } from '../../../src/app/core/stores/board.store';
import { DebugPointsStore } from '../../../src/app/core/stores/debug-points.store';
import { RecentElfRepository } from '../../../src/app/core/stores/recent-elf-db';
import {
  RECENT_ELF_REPOSITORY,
  RecentElfStore,
  readWorkspaceFileFully,
} from '../../../src/app/core/stores/recent-elf.store';
import type { BrowserFileHandleLike } from '../../../src/app/shared/utils/file-picker';

function makeValidElf(fillByte: number): Uint8Array {
  const bytes = new Uint8Array(128);
  bytes[0] = 0x7f;
  bytes[1] = 0x45;
  bytes[2] = 0x4c;
  bytes[3] = 0x46;
  bytes[4] = 1;
  bytes[5] = 1;
  bytes[6] = 1;
  const view = new DataView(bytes.buffer);
  view.setUint16(16, 2, true);
  view.setUint16(18, 40, true);
  view.setUint32(24, 0x0200_0401, true);
  bytes[120] = fillByte;
  return bytes;
}

describe('RecentElfStore and workspace chunk helper', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('merges chunked remote reads via readWorkspaceFileFully', async () => {
    const partA = new Uint8Array([1, 2, 3]);
    const partB = new Uint8Array([4, 5]);
    const calls: bigint[] = [];
    const merged = await readWorkspaceFileFully(
      {
        readWorkspaceFile: async (_path, offset = 0n) => {
          calls.push(offset);
          const isFirst = offset === 0n;
          return {
            version: { kind: 1, size: 5n, modifiedNs: 0n, identity: 1n },
            versionBytes: new Uint8Array(25),
            eof: !isFirst,
            bytes: isFirst ? partA : partB,
          };
        },
      },
      'build/app.elf',
      3
    );
    expect(calls).toEqual([0n, 3n]);
    expect([...(merged ?? [])]).toEqual([1, 2, 3, 4, 5]);
  });

  it('reloads fresh ELF bytes from retained FileSystemFileHandle paused at reset and restores symbol breakpoints', async () => {
    const repo = new RecentElfRepository(null);
    TestBed.configureTestingModule({ providers: [provideRouter(appRoutes), { provide: RECENT_ELF_REPOSITORY, useValue: repo }] });
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const points = TestBed.inject(DebugPointsStore);
    const store = TestBed.inject(RecentElfStore);
    const router = TestBed.inject(Router);

    let diskPayload = makeValidElf(0x11);
    let rebuilt = false;
    const handle: BrowserFileHandleLike = {
      kind: 'file',
      name: 'sensor_node.ra8app',
      queryPermission: async () => 'granted',
      getFile: async () => new File([new Uint8Array(diskPayload)], 'sensor_node.ra8app'),
    };

    const uploadedPayloads: Uint8Array[] = [];
    const breakAtMainFlags: Array<boolean | undefined> = [];
    const clearedIds: number[] = [];
    const restoredNames: string[] = [];
    let bpSeq = 1;
    const fakeClient = {
      clearBreakpointById: async (_core: Core, id: number) => { clearedIds.push(id); return true; },
      setBreakpointByName: async (_core: Core, name: string) => {
        restoredNames.push(name);
        if (rebuilt && name === 'stale_helper') throw new RpcCallError(ErrorCode.AppRefused, 0x0123, 1);
        return { id: bpSeq++, address: name === 'main' ? 0x0200_0501 : 0x0200_0601, deferred: 0 };
      },
      getBoardParts: async () => ({ rawJson: '{}', ledNames: [], buttonNames: [], parts: [] }),
    };

    rpc.connectionState.set('connected');
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });
    board.loadElfFile = async (_name, bytes, _core, opts) => {
      uploadedPayloads.push(bytes);
      breakAtMainFlags.push(opts?.breakAtMain);
      return true;
    };

    const recorded = await store.recordLoadedElf({
      fileName: 'sensor_node.ra8app',
      core: Core.Cpu0,
      wsUrl: 'ws://127.0.0.1:4567',
      handle,
      bytes: diskPayload,
    });
    expect(recorded?.sourceKind).toBe('handle');
    expect(store.canReload()).toBe(true);

    await points.addNamedBreakpoint('main', Core.Cpu0);
    await points.addNamedBreakpoint('stale_helper', Core.Cpu0);
    restoredNames.length = 0;

    rebuilt = true;
    diskPayload = makeValidElf(0x99);
    expect(await store.reloadActiveElf()).toBe(true);
    expect(clearedIds).toEqual([1, 2]);
    expect(uploadedPayloads.length).toBe(1);
    expect(uploadedPayloads[0]![120]).toBe(0x99);
    expect(breakAtMainFlags).toEqual([false]);
    expect(restoredNames).toEqual(['main', 'stale_helper']);
    expect(points.cpu0Breakpoints().get(0x0200_0500)).toBe(3);

    expect(await store.openRecent(store.entries()[0]!)).toBe(true);
    expect(breakAtMainFlags).toEqual([false, false]);
    expect(router.url).toBe('/debug');
  });

  it('reloads updated remote --workspace ELFs and honors Observe mode', async () => {
    const repo = new RecentElfRepository(null);
    TestBed.configureTestingModule({
      providers: [
        provideRouter(appRoutes),
        { provide: RECENT_ELF_REPOSITORY, useValue: repo },
      ],
    });
    const rpc = TestBed.inject(RpcConnectionStore);
    const board = TestBed.inject(BoardStore);
    const store = TestBed.inject(RecentElfStore);

    const diskV1 = makeValidElf(0x21);
    const diskV2 = makeValidElf(0x42);
    let remoteBytes = diskV1;
    const loadedMarkers: number[] = [];

    const fakeClient = {
      workspaceRead: async () => ({
        version: { kind: 1, size: BigInt(remoteBytes.length), modifiedNs: 0n, identity: 1n },
        versionBytes: new Uint8Array(25),
        eof: true,
        bytes: remoteBytes,
      }),
    };
    rpc.connectionState.set('connected');
    rpc.serverCaps.set(CAP_WORKSPACE);
    Object.defineProperty(rpc, 'activeClient', { get: () => fakeClient });
    board.loadElfFile = async (_name, bytes) => {
      loadedMarkers.push(bytes[120]!);
      return true;
    };

    await store.recordLoadedElf({
      fileName: 'remote.elf',
      core: Core.Cpu0,
      workspacePath: 'build/remote.elf',
      bytes: diskV1,
    });

    remoteBytes = diskV2;
    expect(await store.reloadActiveElf()).toBe(true);
    expect(loadedMarkers).toEqual([0x42]);

    rpc.setObserveOnly(true);
    expect(store.canReload()).toBe(false);
    expect(await store.reloadActiveElf()).toBe(false);
    expect(await store.openRecent(store.entries()[0]!)).toBe(false);
  });
});
