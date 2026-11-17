import { TestBed } from '@angular/core/testing';
import {
  CAP_BUILD,
  CAP_PROJECT,
  CAP_TRANSPORT,
  CAP_WORKSPACE,
  ErrorCode,
  RpcCallError,
} from 'ra8-rpc-client';
import {
  RpcConnectionStore,
  isExpectedRefusal,
  resolveWsUrlFromSearch,
} from '../../../src/app/core/rpc/rpc-connection.store';

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

  it('ignores expected AppRefused / AppNoCore / AppHistory / UnknownMethod capability refusals', () => {
    expect(isExpectedRefusal(new RpcCallError(ErrorCode.AppRefused, 0x012f, 1))).toBe(true);
    expect(isExpectedRefusal(new RpcCallError(ErrorCode.AppNoCore, 0x0105, 2))).toBe(true);
    expect(isExpectedRefusal(new RpcCallError(ErrorCode.AppHistory, 0x0128, 3))).toBe(true);
    expect(isExpectedRefusal(new RpcCallError(ErrorCode.UnknownMethod, 0x0190, 4))).toBe(true);
    expect(isExpectedRefusal(new Error('RPC error code 256 for call id 13'))).toBe(true);
    expect(isExpectedRefusal(new Error('RPC error code 259 for call id 9'))).toBe(true);
    expect(isExpectedRefusal(new RpcCallError(ErrorCode.Failed, 0x0100, 5))).toBe(false);

    TestBed.configureTestingModule({});
    const rpc = TestBed.inject(RpcConnectionStore);
    rpc.noteOptionalError(new RpcCallError(ErrorCode.AppRefused, 0x0128, 5), 'History');
    expect(rpc.errorMessage()).toBeNull();

    rpc.noteOptionalError(new RpcCallError(ErrorCode.Failed, 0x0128, 6), 'History');
    expect(rpc.errorMessage()).toContain('History:');
  });
});
