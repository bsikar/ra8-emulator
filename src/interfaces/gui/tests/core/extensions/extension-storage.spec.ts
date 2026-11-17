import { STARTER_EXTENSION_MANIFEST } from '../../../src/app/core/extensions/extension-manifest';
import {
  EXTENSIONS_STORAGE_KEY,
  loadStoredExtensions,
  saveStoredExtensions,
} from '../../../src/app/core/extensions/extension-storage';

describe('extension-storage', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('defaults to empty array, drops invalid entries, and round-trips valid records', () => {
    const errors: string[] = [];
    expect(loadStoredExtensions((m) => errors.push(m))).toEqual([]);

    localStorage.setItem(EXTENSIONS_STORAGE_KEY, '{broken');
    expect(loadStoredExtensions((m) => errors.push(m))).toEqual([]);
    expect(errors[0]).toContain('Extension storage read failed');

    saveStoredExtensions(
      [
        {
          manifest: STARTER_EXTENSION_MANIFEST,
          enabled: false,
          installedAtIso: '2026-11-17T00:00:00.000Z',
          workerStatus: 'idle',
          lastError: null,
          registeredWorkerCommands: [],
          panelStates: {},
        },
      ],
      (m) => errors.push(m)
    );

    const loaded = loadStoredExtensions((m) => errors.push(m));
    expect(loaded.length).toBe(1);
    expect(loaded[0]?.manifest.id).toBe('ra8.target-inspector');
    expect(loaded[0]?.enabled).toBe(false);
  });
});
