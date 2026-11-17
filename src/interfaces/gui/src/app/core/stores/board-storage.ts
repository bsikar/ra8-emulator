import { type BoardPreset } from 'ra8-rpc-client';

const CUSTOM_BOARDS_KEY = 'ra8.customBoards.v1';

/** Load user-created custom board presets persisted in browser storage. */
export function loadSavedBoards(onError: (err: unknown, context: string) => void): BoardPreset[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = localStorage.getItem(CUSTOM_BOARDS_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as BoardPreset[]) : [];
  } catch (err) {
    onError(err, 'Board presets storage');
    return [];
  }
}

/** Persist user-created custom board presets to browser storage. */
export function saveSavedBoards(list: readonly BoardPreset[], onError: (msg: string) => void): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(CUSTOM_BOARDS_KEY, JSON.stringify(list));
  } catch (err) {
    onError(`Board storage write failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}
