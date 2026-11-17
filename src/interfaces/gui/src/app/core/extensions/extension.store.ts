/**
 * Root Angular Signal store managing persisted extension manifests (`'ra8.extensions.v1'`),
 * sandboxed Web Worker hosts, and dynamic command/keybinding/panel contributions.
 */

import { Injectable, OnDestroy, computed, inject, signal } from '@angular/core';
import { Core } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { DebugStore } from '../stores/debug.store';
import { ExecutionStore } from '../stores/execution.store';
import {
  type ExtensionManifest,
  STARTER_EXTENSION_MANIFEST,
  parseExtensionManifestJson,
  validateExtensionManifest,
} from './extension-manifest';
import {
  type ContributedCommandEntry,
  type ContributedKeybindingEntry,
  type ContributedPanelEntry,
  type ExtensionMessageEntry,
  type ExtensionViewState,
  type ExtensionWorkerStatus,
  type InstallExtensionResult,
  type InstalledExtensionRecord,
  loadStoredExtensions,
  saveStoredExtensions,
} from './extension-storage';
import {
  type ExtensionHostAdapter,
  ExtensionWorkerBridge,
  type WorkerFactory,
} from './worker-host';

export { STARTER_EXTENSION_MANIFEST };
export type {
  ContributedCommandEntry,
  ContributedKeybindingEntry,
  ContributedPanelEntry,
  ExtensionMessageEntry,
  ExtensionViewState,
  ExtensionWorkerStatus,
  InstallExtensionResult,
  InstalledExtensionRecord,
};

@Injectable({ providedIn: 'root' })
export class ExtensionStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly debug = inject(DebugStore);

  private readonly bridges = new Map<string, ExtensionWorkerBridge>();
  private workerFactory: WorkerFactory | undefined;
  private externalCommandExecutor: ((command: string, args: unknown[]) => Promise<unknown>) | null = null;
  private rpcTimeoutMs = 3000;
  private nextMessageId = 1;

  public readonly lastError = signal<string | null>(null);
  public readonly extensions = signal<ExtensionViewState[]>(
    loadStoredExtensions((msg) => this.lastError.set(msg))
  );
  public readonly messages = signal<ExtensionMessageEntry[]>([]);

  public readonly contributedCommands = computed<ContributedCommandEntry[]>(() => {
    const out: ContributedCommandEntry[] = [];
    for (const ext of this.extensions()) {
      if (!ext.enabled) continue;
      const seen = new Set<string>();
      for (const cmd of ext.manifest.contributes.commands) {
        seen.add(cmd.command);
        out.push({ ...cmd, extensionId: ext.manifest.id, extensionName: ext.manifest.displayName });
      }
      for (const dynamicCmd of ext.registeredWorkerCommands) {
        if (!seen.has(dynamicCmd)) {
          out.push({
            command: dynamicCmd,
            title: dynamicCmd,
            extensionId: ext.manifest.id,
            extensionName: ext.manifest.displayName,
          });
        }
      }
    }
    return out;
  });

  public readonly contributedKeybindings = computed<ContributedKeybindingEntry[]>(() =>
    this.extensions()
      .filter((ext) => ext.enabled)
      .flatMap((ext) => ext.manifest.contributes.keybindings.map((kb) => ({ ...kb, extensionId: ext.manifest.id })))
  );

  public readonly contributedPanels = computed<ContributedPanelEntry[]>(() =>
    this.extensions()
      .filter((ext) => ext.enabled)
      .flatMap((ext) =>
        ext.manifest.contributes.panels.map((panel) => ({
          ...panel,
          extensionId: ext.manifest.id,
          state: ext.panelStates[panel.id] ?? null,
        }))
      )
  );

  constructor() {
    void this.activateStoredEnabled();
  }

  /** Configures a custom worker factory or RPC timeout (primarily for deterministic unit tests). */
  public configureRuntimeForTest(options: { workerFactory?: WorkerFactory; timeoutMs?: number }): void {
    this.workerFactory = options.workerFactory;
    if (options.timeoutMs !== undefined) this.rpcTimeoutMs = options.timeoutMs;
  }

  /** Registers an external command dispatcher used when a worker calls `ra8.commands.executeCommand`. */
  public setCommandExecutor(fn: ((command: string, args: unknown[]) => Promise<unknown>) | null): void {
    this.externalCommandExecutor = fn;
  }

  /** Validates and installs an extension from a JSON string or manifest object (enabled by default). */
  public async installExtension(
    rawOrJson: unknown,
    options: { enable?: boolean } = {}
  ): Promise<InstallExtensionResult> {
    const validation =
      typeof rawOrJson === 'string' ? parseExtensionManifestJson(rawOrJson) : validateExtensionManifest(rawOrJson);
    if (!validation.ok) {
      this.lastError.set(validation.errors.join('; '));
      return { ok: false, errors: validation.errors };
    }

    const manifest = validation.manifest;
    this.stopBridge(manifest.id);
    const shouldEnable = options.enable ?? true;
    const entry: ExtensionViewState = {
      manifest,
      enabled: shouldEnable,
      installedAtIso: new Date().toISOString(),
      workerStatus: 'idle',
      lastError: null,
      registeredWorkerCommands: [],
      panelStates: {},
    };

    this.extensions.update((prev) => [entry, ...prev.filter((item) => item.manifest.id !== manifest.id)]);
    saveStoredExtensions(this.extensions(), (msg) => this.lastError.set(msg));
    this.lastError.set(null);

    if (shouldEnable) await this.startExtensionBridge(manifest);
    return { ok: true, id: manifest.id };
  }

  /** Explicit user-triggered helper loading `STARTER_EXTENSION_MANIFEST`. */
  public installStarterExample(): Promise<InstallExtensionResult> {
    return this.installExtension(STARTER_EXTENSION_MANIFEST, { enable: true });
  }

  /** Enables an installed extension and boots its sandboxed Web Worker. */
  public async enableExtension(id: string): Promise<boolean> {
    const target = this.extensions().find((ext) => ext.manifest.id === id);
    if (!target) return false;
    this.updateExtension(id, (ext) => ({ ...ext, enabled: true, lastError: null }));
    saveStoredExtensions(this.extensions(), (msg) => this.lastError.set(msg));
    return this.startExtensionBridge(target.manifest);
  }

  /** Disables an extension and cleanly terminates its running Web Worker. */
  public disableExtension(id: string): boolean {
    const target = this.extensions().find((ext) => ext.manifest.id === id);
    if (!target) return false;
    this.stopBridge(id);
    this.updateExtension(id, (ext) => ({
      ...ext,
      enabled: false,
      workerStatus: 'idle',
      registeredWorkerCommands: [],
    }));
    saveStoredExtensions(this.extensions(), (msg) => this.lastError.set(msg));
    return true;
  }

  /** Uninstalls an extension, terminating its Web Worker and removing it from storage. */
  public uninstallExtension(id: string): boolean {
    const existed = this.extensions().some((ext) => ext.manifest.id === id);
    if (!existed) return false;
    this.stopBridge(id);
    this.extensions.update((prev) => prev.filter((ext) => ext.manifest.id !== id));
    saveStoredExtensions(this.extensions(), (msg) => this.lastError.set(msg));
    return true;
  }

  /** Executes a contributed command on the owning enabled extension's Web Worker. */
  public async executeContributedCommand(commandId: string, args: unknown[] = []): Promise<unknown> {
    const owner = this.extensions().find(
      (ext) =>
        ext.enabled &&
        (ext.registeredWorkerCommands.includes(commandId) ||
          ext.manifest.contributes.commands.some((c) => c.command === commandId))
    );
    if (!owner) {
      const msg = `No enabled extension provides command "${commandId}"`;
      this.lastError.set(msg);
      throw new Error(msg);
    }

    const bridge = this.bridges.get(owner.manifest.id);
    if (!bridge) {
      const msg = `Extension worker "${owner.manifest.id}" is not active`;
      this.lastError.set(msg);
      throw new Error(msg);
    }

    try {
      return await bridge.invokeCommand(commandId, args);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      this.updateExtension(owner.manifest.id, (ext) => ({ ...ext, lastError: detail }));
      this.lastError.set(detail);
      throw err;
    }
  }

  /** Clears recorded extension window messages. */
  public clearMessages(): void {
    this.messages.set([]);
  }

  public ngOnDestroy(): void {
    for (const id of Array.from(this.bridges.keys())) {
      this.stopBridge(id);
    }
  }

  private async activateStoredEnabled(): Promise<void> {
    const enabled = this.extensions().filter((ext) => ext.enabled);
    for (const ext of enabled) {
      await this.startExtensionBridge(ext.manifest);
    }
  }

  private async startExtensionBridge(manifest: ExtensionManifest): Promise<boolean> {
    this.stopBridge(manifest.id);
    this.updateExtension(manifest.id, (ext) => ({ ...ext, workerStatus: 'activating', lastError: null }));

    const bridge = new ExtensionWorkerBridge({
      manifest,
      adapter: this.createHostAdapter(manifest.id),
      workerFactory: this.workerFactory,
      timeoutMs: this.rpcTimeoutMs,
    });
    this.bridges.set(manifest.id, bridge);

    try {
      const registered = await bridge.start();
      this.updateExtension(manifest.id, (ext) => ({
        ...ext,
        workerStatus: 'active',
        lastError: null,
        registeredWorkerCommands: Array.from(new Set([...ext.registeredWorkerCommands, ...registered])),
      }));
      return true;
    } catch (err) {
      this.bridges.delete(manifest.id);
      const detail = err instanceof Error ? err.message : String(err);
      const unavailable = detail.includes('unavailable');
      this.updateExtension(manifest.id, (ext) => ({
        ...ext,
        workerStatus: unavailable ? 'unavailable' : 'error',
        lastError: detail,
      }));
      this.lastError.set(detail);
      return false;
    }
  }

  private createHostAdapter(extensionId: string): ExtensionHostAdapter {
    return {
      onRegisterCommand: (command) => {
        this.updateExtension(extensionId, (ext) => ({
          ...ext,
          registeredWorkerCommands: Array.from(new Set([...ext.registeredWorkerCommands, command])),
        }));
      },
      onExecuteCommand: async (command, args) => {
        const owns = this.extensions().some(
          (ext) => ext.enabled && ext.registeredWorkerCommands.includes(command)
        );
        if (owns) return this.executeContributedCommand(command, args);
        return this.externalCommandExecutor ? this.externalCommandExecutor(command, args) : null;
      },
      showInformationMessage: (text) => this.recordMessage(extensionId, 'info', text),
      showWarningMessage: (text) => this.recordMessage(extensionId, 'warning', text),
      getExecutionState: () => ({
        connected: this.rpc.isConnected(),
        executionStatus: this.execution.executionStatus(),
        activeCore: this.execution.activeCore(),
        cpu1Attached: this.execution.cpu1Attached(),
        virtualTimeNs: this.execution.virtualTimeNs().toString(),
      }),
      readRegisters: async (core) => {
        const cached = core === Core.Cpu1 ? this.debug.cpu1Registers() : this.debug.cpu0Registers();
        if (Object.keys(cached).length > 0) return { ...cached };
        const client = this.rpc.activeClient;
        if (!client) return {};
        return client.readExtendedRegisters(core === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0);
      },
      readMemory: async (core, address, length) => {
        const client = this.rpc.activeClient;
        if (!client) return [];
        const targetCore = core === Core.Cpu1 ? Core.Cpu1 : Core.Cpu0;
        const bytes = await client.readMemory(targetCore, address, length);
        return Array.from(bytes);
      },
      postPanelState: (panelId, state) => {
        this.updateExtension(extensionId, (ext) => ({
          ...ext,
          panelStates: { ...ext.panelStates, [panelId]: state },
        }));
      },
      onRuntimeError: (detail) => {
        this.updateExtension(extensionId, (ext) => ({ ...ext, workerStatus: 'error', lastError: detail }));
        this.lastError.set(detail);
      },
    };
  }

  private recordMessage(extensionId: string, tone: 'info' | 'warning', text: string): void {
    this.messages.update((prev) => [
      ...prev.slice(-49),
      { id: this.nextMessageId++, extensionId, tone, text, timestampIso: new Date().toISOString() },
    ]);
    this.rpc.pushToast(text, tone === 'warning' ? 'fault' : 'neutral');
  }

  private stopBridge(id: string): void {
    const existing = this.bridges.get(id);
    if (!existing) return;
    this.bridges.delete(id);
    existing.terminate();
  }

  private updateExtension(id: string, fn: (prev: ExtensionViewState) => ExtensionViewState): void {
    this.extensions.update((list) => list.map((item) => (item.manifest.id === id ? fn(item) : item)));
  }
}
