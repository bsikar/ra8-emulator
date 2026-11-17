/**
 * Persisted extension registry storage helpers (`'ra8.extensions.v1'`) and
 * extension state type contracts.
 */

import {
  type ExtensionCommandContribution,
  type ExtensionKeybindingContribution,
  type ExtensionManifest,
  type ExtensionPanelContribution,
  validateExtensionManifest,
} from './extension-manifest';

export const EXTENSIONS_STORAGE_KEY = 'ra8.extensions.v1';

export type ExtensionWorkerStatus = 'idle' | 'activating' | 'active' | 'error' | 'unavailable';

export interface InstalledExtensionRecord {
  manifest: ExtensionManifest;
  enabled: boolean;
  installedAtIso: string;
}

export interface ExtensionViewState extends InstalledExtensionRecord {
  workerStatus: ExtensionWorkerStatus;
  lastError: string | null;
  registeredWorkerCommands: string[];
  panelStates: Record<string, unknown>;
}

export interface ContributedCommandEntry extends ExtensionCommandContribution {
  extensionId: string;
  extensionName: string;
}

export interface ContributedKeybindingEntry extends ExtensionKeybindingContribution {
  extensionId: string;
}

export interface ContributedPanelEntry extends ExtensionPanelContribution {
  extensionId: string;
  state: unknown;
}

export interface ExtensionMessageEntry {
  id: number;
  extensionId: string;
  tone: 'info' | 'warning';
  text: string;
  timestampIso: string;
}

export interface InstallExtensionResult {
  ok: boolean;
  id?: string;
  errors?: string[];
}

/** Reads and validates persisted extensions from `localStorage` (defaults to empty `[]`). */
export function loadStoredExtensions(onError: (message: string) => void): ExtensionViewState[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = localStorage.getItem(EXTENSIONS_STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const out: ExtensionViewState[] = [];
    for (const item of parsed) {
      if (typeof item !== 'object' || item === null) continue;
      const rec = item as Record<string, unknown>;
      const valid = validateExtensionManifest(rec['manifest']);
      if (!valid.ok) continue;
      out.push({
        manifest: valid.manifest,
        enabled: rec['enabled'] === true,
        installedAtIso: typeof rec['installedAtIso'] === 'string' ? rec['installedAtIso'] : '',
        workerStatus: 'idle',
        lastError: null,
        registeredWorkerCommands: [],
        panelStates: {},
      });
    }
    return out;
  } catch (err) {
    onError(`Extension storage read failed: ${err instanceof Error ? err.message : String(err)}`);
    return [];
  }
}

/** Persists installed extension manifests and enablement flags to `localStorage`. */
export function saveStoredExtensions(
  extensions: readonly ExtensionViewState[],
  onError: (message: string) => void
): void {
  if (typeof localStorage === 'undefined') return;
  try {
    const serialized: InstalledExtensionRecord[] = extensions.map((ext) => ({
      manifest: ext.manifest,
      enabled: ext.enabled,
      installedAtIso: ext.installedAtIso,
    }));
    localStorage.setItem(EXTENSIONS_STORAGE_KEY, JSON.stringify(serialized));
  } catch (err) {
    onError(`Extension storage write failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}
