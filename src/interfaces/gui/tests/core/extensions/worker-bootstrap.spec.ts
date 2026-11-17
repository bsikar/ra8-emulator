import { STARTER_EXTENSION_MANIFEST } from '../../../src/app/core/extensions/extension-manifest';
import { buildWorkerBootstrapScript } from '../../../src/app/core/extensions/worker-bootstrap';

describe('worker-bootstrap', () => {
  it('generates valid bootstrap JavaScript executing activation and command invocation', async () => {
    const script = buildWorkerBootstrapScript(STARTER_EXTENSION_MANIFEST);
    expect(script).toContain('ra8.commands');
    expect(script).toContain('ra8.debug');

    const inbound: unknown[] = [];
    const selfScope: {
      onmessage: ((event: { data: unknown }) => void) | null;
      postMessage: (data: unknown) => void;
    } = {
      onmessage: null,
      postMessage: (data: unknown) => inbound.push(data),
    };

    const bootFn = new Function('self', script) as (scope: typeof selfScope) => void;
    bootFn(selfScope);
    expect(selfScope.onmessage).not.toBeNull();

    selfScope.onmessage?.({ data: { jsonrpc: '2.0', id: 1, method: 'ra8.activate', params: {} } });
    await Promise.resolve();

    const registerReq = inbound[0] as { id: number; method: string; params: { command: string } };
    expect(registerReq.method).toBe('ra8.commands.registerCommand');
    expect(registerReq.params.command).toBe('ra8.targetInspector.snapshot');

    selfScope.onmessage?.({ data: { jsonrpc: '2.0', id: registerReq.id, result: { ok: true } } });
    await Promise.resolve();
    await Promise.resolve();

    const activateReply = inbound[1] as { id: number; result: { registeredCommands: string[] } };
    expect(activateReply.id).toBe(1);
    expect(activateReply.result.registeredCommands).toEqual(['ra8.targetInspector.snapshot']);
  });
});
