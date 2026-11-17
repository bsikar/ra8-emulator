import { Injectable, computed, inject, signal } from '@angular/core';
import { CAP_TARGETS, Core, DEFAULT_RPC_URL, RA8RpcClient } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import {
  type LiveSessionItem,
  type RemoteAuthMode,
  type RemoteSessionStatus,
  type SavedHostProfile,
  deriveProfileName,
  deriveTransportLabel,
  parseRemoteEndpoint,
} from './remote-hosts.types';
import { WorkspaceStore } from './workspace.store';

export interface HostProbeResult {
  reachable: boolean;
  latencyMs: number;
  caps: number;
  title?: string;
  archSummary?: string;
  elfName?: string;
  reserved?: boolean;
  gdbPort?: number;
}

export type EndpointProbeFn = (wsUrl: string) => Promise<HostProbeResult>;

export interface SaveHostProfileInput {
  id?: string;
  endpointUrl: string;
  name?: string;
  authMode?: RemoteAuthMode;
  tokenHint?: string;
  sshLocalPort?: number;
  pinned?: boolean;
}

const HOST_PROFILES_KEY = 'ra8.hostProfiles.v1';

function roundLatencyMs(elapsedMs: number): number {
  return Math.max(0.1, Math.round(elapsedMs * 10) / 10);
}

async function readTargetSummary(client: RA8RpcClient): Promise<{ title?: string; archSummary?: string; reserved?: boolean }> {
  try {
    const res = await client.targetsList();
    const first = res.targets[0];
    if (!first) return {};
    return {
      title: `${first.target.model} (${first.target.board_id})`,
      archSummary: first.target.cores ? `${first.target.cores} core(s) · ${first.target.transport.toUpperCase()}` : undefined,
      reserved: first.reserved,
    };
  } catch {
    return {};
  }
}

async function defaultProbeWsEndpoint(wsUrl: string): Promise<HostProbeResult> {
  const client = new RA8RpcClient({ timeoutMs: 1200 });
  const t0 = typeof performance !== 'undefined' ? performance.now() : Date.now();
  try {
    const hello = await client.connect(wsUrl);
    const t1 = typeof performance !== 'undefined' ? performance.now() : Date.now();
    const meta = (hello.caps & CAP_TARGETS) !== 0 ? await readTargetSummary(client) : {};
    return {
      reachable: true,
      latencyMs: roundLatencyMs(t1 - t0),
      caps: hello.caps,
      ...meta,
    };
  } catch {
    return { reachable: false, latencyMs: 0, caps: 0 };
  } finally {
    client.disconnect();
  }
}

function sortProfiles(list: readonly SavedHostProfile[]): SavedHostProfile[] {
  return [...list].sort((a, b) => {
    if (a.pinned !== b.pinned) return Number(b.pinned) - Number(a.pinned);
    return (b.lastConnectedIso ?? '').localeCompare(a.lastConnectedIso ?? '');
  });
}

@Injectable({ providedIn: 'root' })
export class RemoteHostsStore {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly workspace = inject(WorkspaceStore);
  private customProbe: EndpointProbeFn | null = null;

  public readonly profiles = signal<SavedHostProfile[]>(this.loadProfiles());
  public readonly liveSessions = signal<LiveSessionItem[]>([]);
  public readonly rescanning = signal<boolean>(false);
  public readonly lastScanIso = signal<string | null>(null);

  public readonly pinnedProfiles = computed(() => this.profiles().filter((p) => p.pinned));

  public setProbeForTest(fn: EndpointProbeFn | null): void {
    this.customProbe = fn;
  }

  public saveProfile(input: SaveHostProfileInput): SavedHostProfile | null {
    const parsed = parseRemoteEndpoint(input.endpointUrl, input.sshLocalPort ?? 4567);
    if (!parsed.valid) return null;
    const authMode = input.authMode ?? 'none';
    const existing = this.profiles().find(
      (p) => (input.id && p.id === input.id) || p.endpointUrl === parsed.normalizedInput
    );
    const profile: SavedHostProfile = {
      id: existing?.id ?? input.id ?? `host-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
      name: deriveProfileName(parsed, input.name ?? existing?.name),
      endpointUrl: parsed.normalizedInput,
      wsUrl: parsed.wsUrl,
      transportLabel: deriveTransportLabel(parsed, authMode),
      pinned: input.pinned ?? existing?.pinned ?? false,
      authMode,
      tokenHint: input.tokenHint?.trim() || existing?.tokenHint,
      sshHost: parsed.scheme === 'ssh' ? parsed.sshUserHost : existing?.sshHost,
      sshRemotePort: parsed.scheme === 'ssh' ? parsed.port : existing?.sshRemotePort,
      sshLocalPort: parsed.scheme === 'ssh' ? (input.sshLocalPort ?? existing?.sshLocalPort ?? 4567) : undefined,
      lastConnectedIso: existing?.lastConnectedIso,
      lastStatus: existing?.lastStatus ?? 'offline',
      latencyMs: existing?.latencyMs,
      lastElf: existing?.lastElf,
      archSummary: existing?.archSummary,
    };
    this.profiles.update((prev) => {
      const next = sortProfiles([profile, ...prev.filter((p) => p.id !== profile.id)].slice(0, 24));
      this.persistProfiles(next);
      return next;
    });
    this.workspace.addSavedHost(profile.wsUrl);
    return profile;
  }

  public recordConnected(
    rawEndpoint: string,
    opts?: {
      name?: string;
      authMode?: RemoteAuthMode;
      tokenHint?: string;
      sshLocalPort?: number;
      latencyMs?: number;
      status?: RemoteSessionStatus;
      elfName?: string;
      archSummary?: string;
    }
  ): SavedHostProfile | null {
    const saved = this.saveProfile({
      endpointUrl: rawEndpoint,
      name: opts?.name,
      authMode: opts?.authMode,
      tokenHint: opts?.tokenHint,
      sshLocalPort: opts?.sshLocalPort,
    });
    if (!saved) return null;
    const nowIso = new Date().toISOString();
    const updated: SavedHostProfile = {
      ...saved,
      lastConnectedIso: nowIso,
      lastStatus: opts?.status ?? (parseRemoteEndpoint(saved.wsUrl).isLoopback ? 'loopback' : 'online'),
      latencyMs: opts?.latencyMs ?? saved.latencyMs,
      lastElf: opts?.elfName ?? saved.lastElf,
      archSummary: opts?.archSummary ?? saved.archSummary,
    };
    this.profiles.update((prev) => {
      const next = sortProfiles([updated, ...prev.filter((p) => p.id !== updated.id)]);
      this.persistProfiles(next);
      return next;
    });
    return updated;
  }

  public togglePinProfile(id: string): void {
    this.profiles.update((prev) => {
      const next = sortProfiles(prev.map((p) => (p.id === id ? { ...p, pinned: !p.pinned } : p)));
      this.persistProfiles(next);
      return next;
    });
    this.liveSessions.update((prev) =>
      [...prev.map((s) => (s.id === id || s.wsUrl === id ? { ...s, pinned: !s.pinned } : s))].sort(
        (a, b) => Number(b.pinned) - Number(a.pinned)
      )
    );
  }

  public removeProfile(id: string): void {
    this.profiles.update((prev) => {
      const next = prev.filter((p) => p.id !== id);
      this.persistProfiles(next);
      return next;
    });
  }

  public async rescanLiveSessions(extraCandidates: readonly string[] = []): Promise<LiveSessionItem[]> {
    this.rescanning.set(true);
    try {
      const candidates = this.collectProbeUrls(extraCandidates);
      const probed = await Promise.all(candidates.map(async (url) => ({ url, result: await this.probeUrl(url) })));
      const found: LiveSessionItem[] = [];
      const statusMap = new Map<string, HostProbeResult>();
      for (const entry of probed) {
        statusMap.set(entry.url, entry.result);
        if (entry.result.reachable) found.push(this.toLiveSessionItem(entry.url, entry.result));
      }
      found.sort((a, b) => Number(b.pinned) - Number(a.pinned) || a.latencyMs - b.latencyMs);
      this.liveSessions.set(found);
      this.syncProfileStatuses(statusMap);
      this.lastScanIso.set(new Date().toISOString());
      return found;
    } finally {
      this.rescanning.set(false);
    }
  }

  private collectProbeUrls(extraCandidates: readonly string[]): string[] {
    const urls = new Set<string>();
    const add = (raw: string): void => {
      const parsed = parseRemoteEndpoint(raw);
      if (parsed.valid) urls.add(parsed.wsUrl);
    };
    if (this.rpc.isConnected()) add(this.rpc.serverUrl());
    for (const c of extraCandidates) add(c);
    for (const p of this.profiles()) urls.add(p.wsUrl);
    for (const h of this.workspace.savedHosts()) add(h);
    if (urls.size === 0) urls.add(DEFAULT_RPC_URL);
    return [...urls];
  }

  private async probeUrl(wsUrl: string): Promise<HostProbeResult> {
    if (this.customProbe) return this.customProbe(wsUrl);
    if (this.rpc.isConnected() && this.rpc.serverUrl() === wsUrl && this.rpc.activeClient) {
      const client = this.rpc.activeClient;
      const t0 = typeof performance !== 'undefined' ? performance.now() : Date.now();
      try {
        await client.now(Core.Cpu0);
        const t1 = typeof performance !== 'undefined' ? performance.now() : Date.now();
        const meta = this.rpc.hasCapability(CAP_TARGETS) ? await readTargetSummary(client) : {};
        return {
          reachable: true,
          latencyMs: roundLatencyMs(t1 - t0),
          caps: this.rpc.serverCaps(),
          ...meta,
        };
      } catch {
        return { reachable: false, latencyMs: 0, caps: 0 };
      }
    }
    return defaultProbeWsEndpoint(wsUrl);
  }

  private toLiveSessionItem(wsUrl: string, probe: HostProbeResult): LiveSessionItem {
    const profile = this.profiles().find((p) => p.wsUrl === wsUrl);
    const recent = this.workspace.recentWorkspaces().find((w) => w.wsUrl === wsUrl);
    const parsed = parseRemoteEndpoint(wsUrl);
    const isActiveObserved = this.rpc.isConnected() && this.rpc.serverUrl() === wsUrl && this.rpc.observeOnly();
    const status: LiveSessionItem['status'] =
      probe.reserved || isActiveObserved ? 'in-use' : parsed.isLoopback ? 'loopback' : 'online';
    return {
      id: profile?.id ?? `live-${wsUrl}`,
      title: probe.title ?? profile?.name ?? recent?.name ?? deriveProfileName(parsed),
      archSummary: probe.archSummary ?? profile?.archSummary ?? recent?.archSummary ?? 'Cortex-M85 + State',
      wsUrl,
      elfName: probe.elfName ?? profile?.lastElf ?? recent?.artifactSummary ?? 'live RPC session',
      checkpointCount: recent?.checkpointCount,
      latencyMs: probe.latencyMs,
      status,
      activeClientLabel: status === 'in-use' ? 'Observe' : undefined,
      pinned: profile?.pinned ?? recent?.pinned ?? false,
      caps: probe.caps,
      gdbPort: probe.gdbPort,
    };
  }

  private syncProfileStatuses(results: Map<string, HostProbeResult>): void {
    this.profiles.update((prev) => {
      const next = prev.map((profile) => {
        const res = results.get(profile.wsUrl);
        if (!res) return profile;
        if (!res.reachable) return { ...profile, lastStatus: 'offline' as const };
        const parsed = parseRemoteEndpoint(profile.wsUrl);
        const status: RemoteSessionStatus = res.reserved ? 'in-use' : parsed.isLoopback ? 'loopback' : 'online';
        return { ...profile, lastStatus: status, latencyMs: res.latencyMs };
      });
      this.persistProfiles(next);
      return next;
    });
  }

  private loadProfiles(): SavedHostProfile[] {
    if (typeof localStorage === 'undefined') return [];
    try {
      const raw = localStorage.getItem(HOST_PROFILES_KEY);
      if (!raw) return [];
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? sortProfiles(parsed as SavedHostProfile[]) : [];
    } catch {
      return [];
    }
  }

  private persistProfiles(list: readonly SavedHostProfile[]): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(HOST_PROFILES_KEY, JSON.stringify(list));
    } catch (err) {
      this.rpc.errorMessage.set(`Storage write error: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
