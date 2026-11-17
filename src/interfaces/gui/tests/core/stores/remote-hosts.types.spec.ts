import { describe, expect, it } from 'vitest';
import {
  SERVE_DISCOVER_COMMAND,
  buildSshTunnelCommand,
  deriveCtlAttachCommand,
  deriveGdbAttachCommand,
  deriveProfileName,
  deriveTransportLabel,
  parseRemoteEndpoint,
} from '../../../src/app/core/stores/remote-hosts.types';

describe('remote-hosts.types', () => {
  it('parses ws://, wss://, and ssh:// endpoints and rejects unsupported schemes', () => {
    const ws = parseRemoteEndpoint('ws://127.0.0.1:4567');
    expect(ws.valid).toBe(true);
    expect(ws.scheme).toBe('ws');
    expect(ws.isLoopback).toBe(true);
    expect(ws.wsUrl).toBe('ws://127.0.0.1:4567');

    const wss = parseRemoteEndpoint('wss://hil-rack-04.lab:8443/rpc');
    expect(wss.valid).toBe(true);
    expect(wss.scheme).toBe('wss');
    expect(wss.usesTls).toBe(true);
    expect(wss.isLoopback).toBe(false);
    expect(wss.wsUrl).toBe('wss://hil-rack-04.lab:8443/rpc');

    const ssh = parseRemoteEndpoint('ssh://build@10.0.4.18:4570', 4901);
    expect(ssh.valid).toBe(true);
    expect(ssh.scheme).toBe('ssh');
    expect(ssh.sshUserHost).toBe('build@10.0.4.18');
    expect(ssh.port).toBe(4570);
    expect(ssh.wsUrl).toBe('ws://127.0.0.1:4901');

    const bad = parseRemoteEndpoint('https://127.0.0.1:4567');
    expect(bad.valid).toBe(false);
    expect(bad.reason).toContain('ws://');
  });

  it('builds SSH forward commands, GDB attach strings, ctl discovery commands, and labels', () => {
    expect(SERVE_DISCOVER_COMMAND).toContain('--discover');
    expect(buildSshTunnelCommand('build@10.0.4.18', 4567, 4568)).toBe(
      'ssh -N -L 4567:127.0.0.1:4568 build@10.0.4.18'
    );
    expect(deriveGdbAttachCommand('ws://10.0.4.18:4567', 3339)).toBe(
      'arm-none-eabi-gdb -ex "target extended-remote 10.0.4.18:3339"'
    );
    expect(deriveCtlAttachCommand()).toBe('ra8_emulator ctl sessions');
    expect(deriveCtlAttachCommand('blink.elf')).toBe('ra8_emulator ctl gdb-address blink.elf');

    const ssh = parseRemoteEndpoint('ssh://build@10.0.4.18');
    expect(deriveProfileName(ssh)).toBe('10.0.4.18');
    expect(deriveTransportLabel(ssh, 'none')).toBe('SSH Tunnel · Remote Workspace');

    const wss = parseRemoteEndpoint('wss://hil-rack-04.lab:8443/rpc');
    expect(deriveTransportLabel(wss, 'token')).toBe('Token Auth · TLS');
  });
});
