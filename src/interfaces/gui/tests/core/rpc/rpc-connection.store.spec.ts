import { TestBed } from '@angular/core/testing';
import { CAP_BUILD, CAP_PROJECT, CAP_TRANSPORT, CAP_WORKSPACE } from 'ra8-rpc-client';
import { RpcConnectionStore, resolveWsUrlFromSearch } from '../../../src/app/core/rpc/rpc-connection.store';

describe('RpcConnectionStore', () => {
  it('parses valid ws:// and wss:// URLs from query parameters', () => {
    expect(resolveWsUrlFromSearch('?ws=ws://127.0.0.1:4567')).toBe('ws://127.0.0.1:4567');
    expect(resolveWsUrlFromSearch('?ws=wss://emu.local:9000')).toBe('wss://emu.local:9000');
    expect(resolveWsUrlFromSearch('?ws=http://invalid')).toBeNull();
    expect(resolveWsUrlFromSearch('')).toBeNull();
  });

  it('starts disconnected with zero constructor network calls and tracks capabilities + toasts', () => {
    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    expect(rpc.connectionState()).toBe('disconnected');
    expect(rpc.isConnected()).toBe(false);

    rpc.serverCaps.set(CAP_TRANSPORT | CAP_WORKSPACE | CAP_BUILD | CAP_PROJECT);
    expect(rpc.hasCapability(CAP_WORKSPACE)).toBe(true);
    expect(rpc.capabilitiesSummary()).toContain('WORKSPACE');

    rpc.pushToast('Test notice', 'neutral', 60_000);
    expect(rpc.toasts().length).toBe(1);
    const id = rpc.toasts()[0]!.id;
    rpc.dismissToast(id);
    expect(rpc.toasts().length).toBe(0);
  });
});
