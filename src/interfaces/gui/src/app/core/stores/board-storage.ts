import type {
  ComposerComponentAttachment,
  ComposerMcuSocket,
  StoredCustomBoardPreset,
} from './board-composer.types';

const CUSTOM_BOARDS_KEY = 'ra8.customBoards.v1';
const CUSTOM_SILICON_KEY = 'ra8.customSilicon.v1';
const CUSTOM_COMPONENTS_KEY = 'ra8.customComponents.v1';

function readJsonList<T>(
  key: string,
  context: string,
  onError?: (err: unknown, context: string) => void
): T[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch (err) {
    onError?.(err, context);
    return [];
  }
}

function writeJsonList<T>(key: string, label: string, list: readonly T[], onError?: (msg: string) => void): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(key, JSON.stringify(list));
  } catch (err) {
    onError?.(`${label} write failed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Load user-created custom board presets persisted in browser storage. */
export function loadSavedBoards(
  onError: (err: unknown, context: string) => void
): StoredCustomBoardPreset[] {
  return readJsonList<StoredCustomBoardPreset>(CUSTOM_BOARDS_KEY, 'Board presets storage', onError);
}

/** Persist user-created custom board presets to browser storage. */
export function saveSavedBoards(
  list: readonly StoredCustomBoardPreset[],
  onError: (msg: string) => void
): void {
  writeJsonList(CUSTOM_BOARDS_KEY, 'Board storage', list, onError);
}

/** Load reusable custom silicon presets. */
export function loadCustomSiliconPresets(
  onError?: (err: unknown, context: string) => void
): ComposerMcuSocket[] {
  return readJsonList<ComposerMcuSocket>(CUSTOM_SILICON_KEY, 'Custom silicon storage', onError);
}

/** Save reusable custom silicon presets. */
export function saveCustomSiliconPresets(
  list: readonly ComposerMcuSocket[],
  onError?: (msg: string) => void
): void {
  writeJsonList(CUSTOM_SILICON_KEY, 'Custom silicon storage', list, onError);
}

/** Load reusable custom component definitions. */
export function loadCustomComponentLibrary(
  onError?: (err: unknown, context: string) => void
): ComposerComponentAttachment[] {
  return readJsonList<ComposerComponentAttachment>(CUSTOM_COMPONENTS_KEY, 'Custom component storage', onError);
}

/** Save reusable custom component definitions. */
export function saveCustomComponentLibrary(
  list: readonly ComposerComponentAttachment[],
  onError?: (msg: string) => void
): void {
  writeJsonList(CUSTOM_COMPONENTS_KEY, 'Custom component storage', list, onError);
}
