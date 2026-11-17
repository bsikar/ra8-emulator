export type RemoteScheme = 'ws' | 'wss' | 'ssh' | 'unknown';
export type RemoteAuthMode = 'none' | 'token' | 'mtls';
export type RemoteSessionStatus = 'online' | 'loopback' | 'in-use' | 'offline';

export const SERVE_DISCOVER_COMMAND = 'ra8_emulator serve --discover --listen tcp:0.0.0.0:4567';

export interface SavedHostProfile {
  id: string;
  name: string;
  endpointUrl: string;
  wsUrl: string;
  transportLabel: string;
  pinned: boolean;
  authMode: RemoteAuthMode;
  tokenHint?: string;
  sshHost?: string;
  sshRemotePort?: number;
  sshLocalPort?: number;
  lastConnectedIso?: string;
  lastStatus?: RemoteSessionStatus;
  latencyMs?: number;
  lastElf?: string;
  archSummary?: string;
}

export interface LiveSessionItem {
  id: string;
  title: string;
  archSummary: string;
  wsUrl: string;
  elfName: string;
  checkpointCount?: number;
  latencyMs: number;
  status: Exclude<RemoteSessionStatus, 'offline'>;
  activeClientLabel?: string;
  pinned: boolean;
  caps: number;
  gdbPort?: number;
}

export interface ParsedRemoteEndpoint {
  valid: boolean;
  scheme: RemoteScheme;
  normalizedInput: string;
  wsUrl: string;
  sshUserHost: string;
  host: string;
  port: number;
  path: string;
  isLoopback: boolean;
  usesTls: boolean;
  reason?: string;
}

function invalidEndpoint(raw: string, reason: string): ParsedRemoteEndpoint {
  return {
    valid: false,
    scheme: 'unknown',
    normalizedInput: raw,
    wsUrl: '',
    sshUserHost: '',
    host: '',
    port: 0,
    path: '',
    isLoopback: false,
    usesTls: false,
    reason,
  };
}

export function isLoopbackHostname(host: string): boolean {
  const clean = host.trim().replace(/^\[|\]$/g, '').toLowerCase();
  return clean === '127.0.0.1' || clean === 'localhost' || clean === '::1' || clean.startsWith('127.');
}

function parseSshEndpoint(raw: string, localForwardPort: number): ParsedRemoteEndpoint {
  let parsed: URL;
  try {
    parsed = new URL(raw.replace(/^ssh:\/\//i, 'http://'));
  } catch {
    return invalidEndpoint(raw, 'Malformed ssh:// destination');
  }
  const host = parsed.hostname.trim();
  if (!host) return invalidEndpoint(raw, 'Missing SSH host');
  const remotePort = parsed.port ? Number.parseInt(parsed.port, 10) : 4567;
  if (!Number.isInteger(remotePort) || remotePort < 1 || remotePort > 65535) {
    return invalidEndpoint(raw, 'SSH remote RPC port must be 1..65535');
  }
  const user = parsed.username ? `${decodeURIComponent(parsed.username)}@` : '';
  const sshUserHost = `${user}${host}`;
  const fwdPort = Math.min(65535, Math.max(1, Math.round(localForwardPort || 4567)));
  return {
    valid: true,
    scheme: 'ssh',
    normalizedInput: raw,
    wsUrl: `ws://127.0.0.1:${fwdPort}`,
    sshUserHost,
    host,
    port: remotePort,
    path: parsed.pathname === '/' ? '' : parsed.pathname,
    isLoopback: true,
    usesTls: false,
  };
}

/** Parse a `ws://`, `wss://`, or `ssh://[user@]host[:port]` remote session endpoint. */
export function parseRemoteEndpoint(raw: string, localForwardPort = 4567): ParsedRemoteEndpoint {
  const trimmed = raw.trim();
  if (!trimmed) return invalidEndpoint(trimmed, 'Enter a ws://, wss://, or ssh:// endpoint');
  const lower = trimmed.toLowerCase();
  if (lower.startsWith('ssh://')) return parseSshEndpoint(trimmed, localForwardPort);
  if (!lower.startsWith('ws://') && !lower.startsWith('wss://')) {
    return invalidEndpoint(trimmed, 'Endpoint must start with ws://, wss://, or ssh://');
  }
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return invalidEndpoint(trimmed, 'Malformed WebSocket URL');
  }
  const host = parsed.hostname.trim();
  if (!host) return invalidEndpoint(trimmed, 'Missing host name or IP address');
  const scheme: RemoteScheme = parsed.protocol === 'wss:' ? 'wss' : 'ws';
  const defaultPort = scheme === 'wss' ? 443 : 4567;
  const port = parsed.port ? Number.parseInt(parsed.port, 10) : defaultPort;
  const path = parsed.pathname === '/' ? '' : parsed.pathname;
  const wsUrl = parsed.port ? `${scheme}://${parsed.host}${path}` : `${scheme}://${parsed.hostname}:${port}${path}`;
  return {
    valid: true,
    scheme,
    normalizedInput: trimmed,
    wsUrl,
    sshUserHost: '',
    host,
    port,
    path,
    isLoopback: isLoopbackHostname(host),
    usesTls: scheme === 'wss',
  };
}

/** Format an OpenSSH local port-forwarding command for remote `ra8_emulator serve`. */
export function buildSshTunnelCommand(sshHost: string, localPort = 4567, remotePort = 4567): string {
  const target = sshHost.trim() || 'user@remote-host';
  const cleanHost = target.replace(/^ssh:\/\//i, '').split('/')[0] ?? target;
  const lPort = Math.min(65535, Math.max(1, Math.round(localPort || 4567)));
  const rPort = Math.min(65535, Math.max(1, Math.round(remotePort || 4567)));
  return `ssh -N -L ${lPort}:127.0.0.1:${rPort} ${cleanHost}`;
}

/** Derive the GDB remote target attach command matching `ra8_emulator serve` / `ctl gdb-address`. */
export function deriveGdbAttachCommand(wsUrl: string, gdbPort?: number | null): string {
  const parsed = parseRemoteEndpoint(wsUrl);
  const host = parsed.valid ? parsed.host : '127.0.0.1';
  const port = gdbPort && gdbPort > 0 ? Math.round(gdbPort) : 3333;
  return `arm-none-eabi-gdb -ex "target extended-remote ${host}:${port}"`;
}

/** Derive the headless CLI discovery/control inspect command for the active daemon. */
export function deriveCtlAttachCommand(sessionElf?: string | null): string {
  const clean = sessionElf?.trim();
  return clean ? `ra8_emulator ctl gdb-address ${clean}` : 'ra8_emulator ctl sessions';
}

/** Derive a readable host profile title from an endpoint when none was specified. */
export function deriveProfileName(parsed: ParsedRemoteEndpoint, customName?: string): string {
  const clean = customName?.trim();
  if (clean) return clean;
  if (!parsed.valid) return parsed.normalizedInput || 'Remote Host';
  if (parsed.scheme === 'ssh') return parsed.host;
  if (parsed.isLoopback) return `Local Loopback (${parsed.port})`;
  return parsed.port === 4567 || parsed.port === 443 ? parsed.host : `${parsed.host}:${parsed.port}`;
}

/** Build the compact metadata subtitle for a saved host profile row. */
export function deriveTransportLabel(parsed: ParsedRemoteEndpoint, authMode: RemoteAuthMode): string {
  if (parsed.scheme === 'ssh') return 'SSH Tunnel · Remote Workspace';
  const authText = authMode === 'token' ? 'Token Auth' : authMode === 'mtls' ? 'mTLS Client Cert' : 'Direct RPC';
  return parsed.usesTls ? `${authText} · TLS` : `${authText} · WebSocket`;
}
