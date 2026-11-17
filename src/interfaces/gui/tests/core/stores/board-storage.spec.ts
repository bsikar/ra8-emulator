import { OFFICIAL_BOARD_PRESETS } from 'ra8-rpc-client';
import { loadSavedBoards, saveSavedBoards } from '../../../src/app/core/stores/board-storage';

describe('board-storage', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('round-trips custom board presets through localStorage', () => {
    const custom = { ...OFFICIAL_BOARD_PRESETS[0]!, id: 'custom-test-1', partNumber: 'CUSTOM' };
    saveSavedBoards([custom], () => {});
    const loaded = loadSavedBoards(() => {});
    expect(loaded.length).toBe(1);
    expect(loaded[0]?.id).toBe('custom-test-1');
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
