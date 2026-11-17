import { TestBed } from '@angular/core/testing';
import {
  type ExtensionManifest,
  STARTER_EXTENSION_MANIFEST,
} from '../../../src/app/core/extensions/extension-manifest';
import { ExtensionStore } from '../../../src/app/core/extensions/extension.store';
import {
  type WorkerLike,
  type WorkerMessageEventLike,
  buildWorkerBootstrapScript,
} from '../../../src/app/core/extensions/worker-host';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { DebugStore } from '../../../src/app/core/stores/debug.store';
import { ExecutionStore } from '../../../src/app/core/stores/execution.store';

function createWorkerStub(manifest: ExtensionManifest, onTerminate: () => void): WorkerLike {
  let active = true;
  const selfScope: {
    onmessage: ((event: WorkerMessageEventLike) => void) | null;
    postMessage: (data: unknown) => void;
  } = {
    onmessage: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (active) hostWorker.onmessage?.({ data });
      });
    },
  };
  const fn = new Function('self', buildWorkerBootstrapScript(manifest)) as (s: typeof selfScope) => void;
  fn(selfScope);

  const hostWorker: WorkerLike = {
    onmessage: null,
    onerror: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (active) selfScope.onmessage?.({ data });
      });
    },
    terminate: () => {
      active = false;
      onTerminate();
    },
  };
  return hostWorker;
}

describe('ExtensionStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('starts strictly empty with zero hardcoded extensions and validates installs', async () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(ExtensionStore);
    expect(store.extensions()).toEqual([]);
    expect(store.contributedCommands()).toEqual([]);

    const bad = await store.installExtension('{"name":"broken"}');
    expect(bad.ok).toBe(false);
    expect(store.extensions()).toEqual([]);
  });

  it('installs, executes worker commands over debug stores, disables, and uninstalls cleanly', async () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    const execution = TestBed.inject(ExecutionStore);
    const debug = TestBed.inject(DebugStore);
    const store = TestBed.inject(ExtensionStore);

    let terminatedCount = 0;
    store.configureRuntimeForTest({
      workerFactory: (_url, manifest) => createWorkerStub(manifest, () => (terminatedCount += 1)),
    });

    rpc.connectionState.set('connected');
    execution.executionStatus.set('halted');
    debug.cpu0Registers.set({ pc: 0x0200_1234 });

    const installed = await store.installStarterExample();
    expect(installed).toEqual({ ok: true, id: STARTER_EXTENSION_MANIFEST.id });
    expect(store.extensions()[0]?.workerStatus).toBe('active');
    expect(store.contributedCommands().map((c) => c.command)).toContain('ra8.targetInspector.snapshot');

    const result = (await store.executeContributedCommand('ra8.targetInspector.snapshot')) as { pc: string };
    expect(result.pc).toBe('0x2001234');
    expect(store.messages()[0]?.text).toContain('0x2001234');
    expect(rpc.toasts().some((t) => t.message.includes('0x2001234'))).toBe(true);
    expect(store.contributedPanels()[0]?.state).toBeTruthy();

    expect(store.disableExtension(STARTER_EXTENSION_MANIFEST.id)).toBe(true);
    expect(terminatedCount).toBe(1);
    expect(store.contributedCommands()).toEqual([]);

    expect(await store.enableExtension(STARTER_EXTENSION_MANIFEST.id)).toBe(true);
    expect(store.contributedCommands().length).toBe(1);

    expect(store.uninstallExtension(STARTER_EXTENSION_MANIFEST.id)).toBe(true);
    expect(terminatedCount).toBe(2);
    expect(store.extensions()).toEqual([]);
  });
});
