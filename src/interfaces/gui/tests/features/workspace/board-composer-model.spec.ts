import { OFFICIAL_BOARD_PRESETS, parseBoardProfile, serializeBoardProfile } from 'ra8-rpc-client';
import {
  BUILTIN_COMPONENT_CATALOG,
  BUILTIN_SILICON_CATALOG,
  buildSocketFromCatalog,
} from '../../../src/app/features/workspace/board-composer-catalog';
import {
  compileDraftToBoardPreset,
  createComposerDraft,
} from '../../../src/app/features/workspace/board-composer-model';

describe('board-composer-model & catalog', () => {
  it('builds inclusive SPI/I2C component catalog entries and silicon sockets', () => {
    const imu = BUILTIN_COMPONENT_CATALOG.find((c) => c.id === 'lsm6dso')!;
    expect(imu.defaultAttachment.interfaceKind).toBe('SPI (COPI / CIPO / CS)');
    expect(imu.defaultAttachment.pins.map((p) => p.signal)).toEqual(['SCK', 'COPI', 'CIPO', 'CS']);

    const u2 = buildSocketFromCatalog(BUILTIN_SILICON_CATALOG[3]!, 'U2', 'Companion', 'U1.SPI0 <-> U2.SPI0');
    expect(u2.designator).toBe('U2');
    expect(u2.silicon).toBe('ra4t1');
  });

  it('compiles a multi-MCU custom draft into a valid .board profile that round-trips cleanly', () => {
    const draft = createComposerDraft(null);
    draft.boardName = 'Dual-MCU Motor Carrier';
    draft.profileFile = 'ra8p1_ra4t1_hil.board';
    draft.mcus.push(buildSocketFromCatalog(BUILTIN_SILICON_CATALOG[3]!, 'U2', 'Companion'));

    const preset = compileDraftToBoardPreset(draft);
    expect(preset.partNumber).toBe('CUSTOM');
    expect(preset.name).toBe('Dual-MCU Motor Carrier');
    expect(preset.composer?.mcus.length).toBe(2);

    const text = serializeBoardProfile(preset.profile);
    expect(text).toContain('version=1');
    const reparsed = parseBoardProfile(text);
    expect(reparsed.version).toBe(1);

    const reopened = createComposerDraft(preset);
    expect(reopened.isExistingCustom).toBe(true);
    expect(reopened.mcus.length).toBe(2);

    const fromOfficial = createComposerDraft(OFFICIAL_BOARD_PRESETS[2]!);
    expect(fromOfficial.isExistingCustom).toBe(false);
    expect(fromOfficial.mcus[0]?.silicon).toBe('ra8e1');
  });
});
