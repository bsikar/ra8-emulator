import { Injectable, computed, inject, signal } from '@angular/core';
import { CAP_TARGETS, type TargetEntry } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';

export type WorkbenchSchemeId =
  | 'editorial-slate-vivid'
  | 'tokyo-slate'
  | 'nordic-frost'
  | 'high-contrast-mono';

export type ProbeBindingIdentity = 'usb-serial-vid-pid' | 'uid-only' | 'os-port-path';
export type SwdConnectMode = 'under-reset' | 'normal' | 'hot-plug';
export type WorkbenchLayoutMode = 'split' | 'debugger' | 'board';

export interface WorkbenchSchemeSpec {
  id: WorkbenchSchemeId;
  name: string;
  subtitle: string;
  isDefault?: boolean;
  swatches: readonly [string, string, string, string, string, string];
  tokens: {
    tokKw: string;
    tokType: string;
    tokFn: string;
    tokNum: string;
    tokId: string;
    tokCmt: string;
    signalCursor: string;
    signalNominal: string;
    signalFault: string;
  };
}

export interface WorkbenchPreferences {
  colorScheme: WorkbenchSchemeId;
  codeFontSizePx: number;
  dimZeroRegisters: boolean;
  checkpointEveryRounds: number;
  autoRecordOnAttach: boolean;
  probeBindingIdentity: ProbeBindingIdentity;
  autoRebindVcom: boolean;
  defaultSwdConnectMode: SwdConnectMode;
  toolchainZigPath: string;
  toolchainGdbPort: number;
  workbenchLayout: WorkbenchLayoutMode;
}

const PREFS_STORAGE_KEY = 'ra8.preferences.v1';

export const WORKBENCH_SCHEMES: readonly WorkbenchSchemeSpec[] = [
  {
    id: 'editorial-slate-vivid',
    name: 'Editorial Slate Vivid',
    subtitle: 'Balanced architectural chroma · 9.5:1 contrast',
    isDefault: true,
    swatches: ['#95a6c8', '#7faab8', '#f2f5fc', '#c4aa84', '#7fa88d', '#d9776c'],
    tokens: {
      tokKw: '#95a6c8',
      tokType: '#7faab8',
      tokFn: '#f2f5fc',
      tokNum: '#c4aa84',
      tokId: '#c8cdd8',
      tokCmt: '#5a606d',
      signalCursor: '#b8c4d9',
      signalNominal: '#7fa88d',
      signalFault: '#d9776c',
    },
  },
  {
    id: 'tokyo-slate',
    name: 'Tokyo Slate',
    subtitle: 'Higher-saturation indigo, cyan, and warm amber',
    swatches: ['#9d8ec7', '#73b7c9', '#eef2fc', '#d4a672', '#82b39a', '#de7d78'],
    tokens: {
      tokKw: '#9d8ec7',
      tokType: '#73b7c9',
      tokFn: '#eef2fc',
      tokNum: '#d4a672',
      tokId: '#c6cee0',
      tokCmt: '#5c6375',
      signalCursor: '#a9b9de',
      signalNominal: '#82b39a',
      signalFault: '#de7d78',
    },
  },
  {
    id: 'nordic-frost',
    name: 'Nordic Frost',
    subtitle: 'Cool arctic blues, sage, and muted aurora accents',
    swatches: ['#88a4bf', '#8ebbb8', '#edf3f8', '#ccb28b', '#8fb59b', '#cf7975'],
    tokens: {
      tokKw: '#88a4bf',
      tokType: '#8ebbb8',
      tokFn: '#edf3f8',
      tokNum: '#ccb28b',
      tokId: '#d2dae4',
      tokCmt: '#616c7a',
      signalCursor: '#a7c0d4',
      signalNominal: '#8fb59b',
      signalFault: '#cf7975',
    },
  },
  {
    id: 'high-contrast-mono',
    name: 'High-Contrast Mono',
    subtitle: 'Achromatic weight & luminance hierarchy (WCAG AAA)',
    swatches: ['#ffffff', '#dce2ee', '#e4e8f2', '#adb4c2', '#96bfa4', '#e3887e'],
    tokens: {
      tokKw: '#ffffff',
      tokType: '#dce2ee',
      tokFn: '#ffffff',
      tokNum: '#e4e8f2',
      tokId: '#cad0dc',
      tokCmt: '#7e8594',
      signalCursor: '#e6ecf8',
      signalNominal: '#96bfa4',
      signalFault: '#e3887e',
    },
  },
];

export function defaultWorkbenchPreferences(): WorkbenchPreferences {
  return {
    colorScheme: 'editorial-slate-vivid',
    codeFontSizePx: 12.5,
    dimZeroRegisters: true,
    checkpointEveryRounds: 64,
    autoRecordOnAttach: false,
    probeBindingIdentity: 'usb-serial-vid-pid',
    autoRebindVcom: true,
    defaultSwdConnectMode: 'under-reset',
    toolchainZigPath: 'zig',
    toolchainGdbPort: 3333,
    workbenchLayout: 'split',
  };
}

function clampFontSize(px: unknown): number {
  const num = typeof px === 'number' ? px : Number.parseFloat(String(px));
  if (!Number.isFinite(num)) return 12.5;
  return Math.min(15, Math.max(12, num));
}

function loadPreferences(): WorkbenchPreferences {
  const base = defaultWorkbenchPreferences();
  if (typeof localStorage === 'undefined') return base;
  try {
    const raw = localStorage.getItem(PREFS_STORAGE_KEY);
    if (!raw) return base;
    const parsed = JSON.parse(raw) as Partial<WorkbenchPreferences>;
    const validScheme = WORKBENCH_SCHEMES.some((s) => s.id === parsed.colorScheme)
      ? (parsed.colorScheme as WorkbenchSchemeId)
      : base.colorScheme;
    return {
      ...base,
      ...parsed,
      colorScheme: validScheme,
      codeFontSizePx: clampFontSize(parsed.codeFontSizePx ?? base.codeFontSizePx),
    };
  } catch (err) {
    void err;
    return base;
  }
}

@Injectable({ providedIn: 'root' })
export class PreferencesStore {
  private readonly rpc = inject(RpcConnectionStore);

  public readonly schemes = WORKBENCH_SCHEMES;
  public readonly prefs = signal<WorkbenchPreferences>(loadPreferences());
  public readonly detectedProbes = signal<TargetEntry[]>([]);
  public readonly probeScanBusy = signal<boolean>(false);
  public readonly probeScanMessage = signal<string | null>(null);

  public readonly activeScheme = computed<WorkbenchSchemeSpec>(
    () => WORKBENCH_SCHEMES.find((s) => s.id === this.prefs().colorScheme) ?? WORKBENCH_SCHEMES[0]!
  );

  constructor() {
    this.applySchemeCssVars();
  }

  public patch(partial: Partial<WorkbenchPreferences>): void {
    this.prefs.update((cur) => {
      const next: WorkbenchPreferences = {
        ...cur,
        ...partial,
        codeFontSizePx:
          partial.codeFontSizePx !== undefined ? clampFontSize(partial.codeFontSizePx) : cur.codeFontSizePx,
      };
      this.persist(next);
      return next;
    });
    this.applySchemeCssVars();
  }

  public setWorkbenchLayout(mode: WorkbenchLayoutMode): void {
    this.patch({ workbenchLayout: mode });
  }

  public resetDefaults(): void {
    const defaults = defaultWorkbenchPreferences();
    this.prefs.set(defaults);
    this.persist(defaults);
    this.applySchemeCssVars();
  }

  public applySchemeCssVars(rootEl?: HTMLElement | null): void {
    const el = rootEl ?? (typeof document !== 'undefined' ? document.documentElement : null);
    if (!el) return;
    const scheme = this.activeScheme();
    const fontPx = this.prefs().codeFontSizePx;
    el.style.setProperty('--es-tok-kw', scheme.tokens.tokKw);
    el.style.setProperty('--es-tok-type', scheme.tokens.tokType);
    el.style.setProperty('--es-tok-fn', scheme.tokens.tokFn);
    el.style.setProperty('--es-tok-num', scheme.tokens.tokNum);
    el.style.setProperty('--es-tok-id', scheme.tokens.tokId);
    el.style.setProperty('--es-tok-cmt', scheme.tokens.tokCmt);
    el.style.setProperty('--es-signal-cursor', scheme.tokens.signalCursor);
    el.style.setProperty('--es-signal-nominal', scheme.tokens.signalNominal);
    el.style.setProperty('--es-signal-fault', scheme.tokens.signalFault);
    el.style.setProperty('--es-code-font-size', `${fontPx}px`);
  }

  public async rescanProbes(): Promise<TargetEntry[]> {
    const client = this.rpc.activeClient;
    if (!client || !this.rpc.isConnected()) {
      this.detectedProbes.set([]);
      this.probeScanMessage.set('Offline — connect to an emulator or HIL host to enumerate physical probes.');
      return [];
    }
    if (!this.rpc.hasCapability(CAP_TARGETS)) {
      this.detectedProbes.set([]);
      this.probeScanMessage.set('Connected session does not expose CAP_TARGETS physical probe enumeration.');
      return [];
    }
    this.probeScanBusy.set(true);
    try {
      const reply = await client.targetsList();
      this.detectedProbes.set(reply.targets);
      this.probeScanMessage.set(
        reply.targets.length > 0
          ? `Enumerated ${reply.targets.length} physical / remote target probe(s).`
          : 'No physical SWD / CMSIS-DAP / J-Link probes detected on host.'
      );
      return reply.targets;
    } catch (err) {
      this.rpc.reportError('Probe rescan failed', err);
      this.probeScanMessage.set(err instanceof Error ? err.message : String(err));
      return [];
    } finally {
      this.probeScanBusy.set(false);
    }
  }

  public exportSettingsJson(): string {
    return JSON.stringify(
      {
        version: 1,
        exportedAt: new Date().toISOString(),
        preferences: this.prefs(),
      },
      null,
      2
    );
  }

  private persist(value: WorkbenchPreferences): void {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(PREFS_STORAGE_KEY, JSON.stringify(value));
    } catch (err) {
      this.rpc.noteOptionalError(err, 'Preferences storage');
    }
  }
}
