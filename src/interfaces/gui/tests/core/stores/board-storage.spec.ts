import { OFFICIAL_BOARD_PRESETS } from 'ra8-rpc-client';
import {
  loadCustomComponentLibrary,
  loadCustomSiliconPresets,
  loadSavedBoards,
  saveCustomComponentLibrary,
  saveCustomSiliconPresets,
  saveSavedBoards,
} from '../../../src/app/core/stores/board-storage';
import { BUILTIN_SILICON_CATALOG, buildSocketFromCatalog } from '../../../src/app/features/workspace/board-composer-catalog';

describe('board-storage', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('round-trips custom board presets, silicon presets, and custom components through localStorage', () => {
    const custom = { ...OFFICIAL_BOARD_PRESETS[0]!, id: 'custom-test-1', partNumber: 'CUSTOM' };
    saveSavedBoards([custom], () => {});
    const loaded = loadSavedBoards(() => {});
    expect(loaded.length).toBe(1);
    expect(loaded[0]?.id).toBe('custom-test-1');

    const mcu = buildSocketFromCatalog(BUILTIN_SILICON_CATALOG[0]!, 'U2', 'Companion');
    saveCustomSiliconPresets([mcu]);
    expect(loadCustomSiliconPresets().length).toBe(1);

    saveCustomComponentLibrary([
      {
        id: 'hall-1',
        name: 'Hall Sensor',
        category: 'Custom',
        isCustom: true,
        mountSocket: 'U2',
        endpointLabel: 'GPT0 / GPIO',
        fitSpec: null,
        interfaceKind: 'GPIO / Timer',
        pins: [{ signal: 'PHA', pin: 'P408', electrical: 'Input' }],
      },
    ]);
    expect(loadCustomComponentLibrary()[0]?.name).toBe('Hall Sensor');
  });

  it('handles corrupt localStorage JSON via error callback', () => {
    localStorage.setItem('ra8.customBoards.v1', '{bad-json');
    let seenCtx = '';
    const loaded = loadSavedBoards((_err, ctx) => {
      seenCtx = ctx;
    });
    expect(loaded).toEqual([]);
    expect(seenCtx).toBe('Board presets storage');
  });
});
