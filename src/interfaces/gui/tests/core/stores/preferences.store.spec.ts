import { TestBed } from '@angular/core/testing';
import { CAP_TARGETS } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../../../src/app/core/rpc/rpc-connection.store';
import { PreferencesStore } from '../../../src/app/core/stores/preferences.store';

describe('PreferencesStore', () => {
  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({});
  });

  it('persists color scheme and applies only code-buffer / signal CSS variables', () => {
    const store = TestBed.inject(PreferencesStore);
    const root = document.createElement('div');
    store.patch({ colorScheme: 'tokyo-slate', codeFontSizePx: 14, dimZeroRegisters: false });
    store.applySchemeCssVars(root);

    expect(root.style.getPropertyValue('--es-tok-kw')).toBe('#9d8ec7');
    expect(root.style.getPropertyValue('--es-code-font-size')).toBe('14px');
    expect(root.style.getPropertyValue('--es-chrome')).toBe('');
    expect(store.prefs().dimZeroRegisters).toBe(false);

    const exported = JSON.parse(store.exportSettingsJson()) as { preferences: { colorScheme: string } };
    expect(exported.preferences.colorScheme).toBe('tokyo-slate');

    store.resetDefaults();
    expect(store.prefs().colorScheme).toBe('editorial-slate-vivid');
  });

  it('handles offline and CAP_TARGETS probe rescans honestly', async () => {
    const rpc = TestBed.inject(RpcConnectionStore);
    const store = TestBed.inject(PreferencesStore);

    const offline = await store.rescanProbes();
    expect(offline).toEqual([]);
    expect(store.probeScanMessage()).toContain('Offline');

    const mockClient = {
      targetsList: async () => ({
        json: '[]',
        targets: [
          {
            generation: 1,
            reserved: false,
            target: {
              host_id: 'local',
              probe_id: 'jlink-1',
              board_id: 'ek_ra8p1',
              probe_serial: '1050294812',
              board_serial: 'B1',
              vendor: 'Segger',
              model: 'J-Link OB',
              cores: 'M85+M33',
              transport: 'SWD',
              connection: 'connected' as const,
              disambiguation: 'usb',
              identity_verified: true,
              managed: true,
              operations: [],
              capabilities: { build: true, flash: true, hardware_debug: true, emulation: false, npu: true },
            },
          },
        ],
      }),
    };
    Object.defineProperty(rpc, 'activeClient', { get: () => mockClient });
    rpc.connectionState.set('connected');
    rpc.serverCaps.set(CAP_TARGETS);

    const found = await store.rescanProbes();
    expect(found.length).toBe(1);
    expect(store.detectedProbes()[0]?.target.probe_serial).toBe('1050294812');
  });
});
