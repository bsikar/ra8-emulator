import {
  type ExtensionManifest,
  STARTER_EXTENSION_MANIFEST,
} from '../../../src/app/core/extensions/extension-manifest';
import {
  ExtensionWorkerBridge,
  type WorkerLike,
  type WorkerMessageEventLike,
  buildWorkerBootstrapScript,
} from '../../../src/app/core/extensions/worker-host';

function spawnSimulatedWorker(manifest: ExtensionManifest): WorkerLike {
  let terminated = false;
  const selfScope: {
    onmessage: ((event: WorkerMessageEventLike) => void) | null;
    postMessage: (data: unknown) => void;
  } = {
    onmessage: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (!terminated) bridgeWorker.onmessage?.({ data });
      });
    },
  };
  const run = new Function('self', buildWorkerBootstrapScript(manifest)) as (s: typeof selfScope) => void;
  run(selfScope);

  const bridgeWorker: WorkerLike = {
    onmessage: null,
    onerror: null,
    postMessage: (data: unknown) => {
      queueMicrotask(() => {
        if (!terminated) selfScope.onmessage?.({ data });
      });
    },
    terminate: () => {
      terminated = true;
    },
  };
  return bridgeWorker;
}

describe('ExtensionWorkerBridge', () => {
  it('handles missing global Worker cleanly without crashing', async () => {
    const bridge = new ExtensionWorkerBridge({
      manifest: STARTER_EXTENSION_MANIFEST,
      adapter: {},
    });
    await expect(bridge.start()).rejects.toThrow('Web Worker runtime unavailable');
  });

  it('proxies ra8.commands, ra8.window, ra8.debug, and ra8.views over JSON-RPC', async () => {
    const infoLogs: string[] = [];
    const panelUpdates: Array<{ id: string; state: unknown }> = [];
    const bridge = new ExtensionWorkerBridge({
      manifest: STARTER_EXTENSION_MANIFEST,
      workerFactory: (_url, manifest) => spawnSimulatedWorker(manifest),
      adapter: {
        getExecutionState: () => ({
          connected: true,
          executionStatus: 'halted',
          activeCore: 0,
          cpu1Attached: false,
          virtualTimeNs: '42000',
        }),
        readRegisters: () => ({ pc: 0x0200_0044 }),
        readMemory: (_core, _addr, len) => Array<number>(len).fill(0xaa),
        showInformationMessage: (msg) => {
          infoLogs.push(msg);
        },
        postPanelState: (id, state) => {
          panelUpdates.push({ id, state });
        },
      },
    });

    const cmds = await bridge.start();
    expect(cmds).toEqual(['ra8.targetInspector.snapshot']);

    const output = (await bridge.invokeCommand('ra8.targetInspector.snapshot')) as { pc: string };
    expect(output.pc).toBe('0x2000044');
    expect(infoLogs[0]).toContain('halted');
    expect(panelUpdates[0]?.id).toBe('ra8.targetInspector.panel');

    bridge.terminate();
    await expect(bridge.invokeCommand('ra8.targetInspector.snapshot')).rejects.toThrow('not running');
  });

  it('enforces RPC timeouts and terminates hung workers cleanly', async () => {
    let terminatedCalled = false;
    const hungWorker: WorkerLike = {
      onmessage: null,
      onerror: null,
      postMessage: () => undefined,
      terminate: () => {
        terminatedCalled = true;
      },
    };
    const bridge = new ExtensionWorkerBridge({
      manifest: STARTER_EXTENSION_MANIFEST,
      workerFactory: () => hungWorker,
      adapter: {},
      timeoutMs: 25,
    });

    await expect(bridge.start()).rejects.toThrow('timed out');
    expect(terminatedCalled).toBe(true);
  });
});
