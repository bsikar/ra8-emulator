import { Injectable, OnDestroy, inject, signal } from '@angular/core';
import { Subscription } from 'rxjs';
import {
  type BoardParts,
  type BoardPreset,
  type BoardProfile,
  Core,
  type DirtyRect,
  type ElfSymbol,
  EventKind,
  FramebufferRenderer,
  InputKind,
  OFFICIAL_BOARD_PRESETS,
  type SessionEvent,
  findBoardPreset,
  inspectElf,
  parseBoardProfile,
  parseElfSymbols,
  serializeBoardProfile,
} from 'ra8-rpc-client';
import { formatHex32 } from '../../shared/utils/hex';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { loadSavedBoards, saveSavedBoards } from './board-storage';
import { ExecutionStore } from './execution.store';

export interface UploadProgressState {
  active: boolean;
  fileName: string;
  core: Core;
  percent: number;
  statusText: string;
}

export interface LoadElfOptions {
  breakAtMain?: boolean;
}

export function decodeLedEvent(address: number): { index: number; on: boolean } {
  return {
    index: address & 0xff,
    on: (address & 0x100) !== 0,
  };
}

@Injectable({ providedIn: 'root' })
export class BoardStore implements OnDestroy {
  private readonly rpc = inject(RpcConnectionStore);
  private readonly execution = inject(ExecutionStore);
  private readonly subs = new Subscription();
  private renderer: FramebufferRenderer | null = null;

  public readonly boardParts = signal<BoardParts | null>(null);
  public readonly ledStates = signal<boolean[]>(Array<boolean>(8).fill(false));
  public readonly uploadProgress = signal<UploadProgressState | null>(null);
  public readonly cpu0ElfName = signal<string | null>(null);
  public readonly cpu1ElfName = signal<string | null>(null);
  public readonly cpu0ElfSymbols = signal<ElfSymbol[]>([]);
  public readonly cpu1ElfSymbols = signal<ElfSymbol[]>([]);
  public readonly cpu0HasDwarf = signal<boolean>(false);
  public readonly cpu1HasDwarf = signal<boolean>(false);
  public readonly memoryMapText = signal<string>('');
  public readonly savedBoards = signal<BoardPreset[]>(
    loadSavedBoards((err, ctx) => this.rpc.noteOptionalError(err, ctx))
  );
  public readonly boardPresets: readonly BoardPreset[] = OFFICIAL_BOARD_PRESETS;
  public readonly selectedPreset = signal<BoardPreset | null>(findBoardPreset('ra8d2') ?? null);
  public readonly boardProfile = signal<BoardProfile | null>(findBoardPreset('ra8d2')?.profile ?? null);
  public readonly cameraSource = signal<string>('none');
  public readonly boardProfileRaw = signal<string>('');
  public readonly boardProfileName = signal<string>('ra8d2');
  public readonly lcdFps = signal<number>(0);
  public readonly lcdFrames = signal<number>(0);

  constructor() {
    this.subs.add(this.rpc.connected$.subscribe(() => void this.refreshBoardParts()));
    this.subs.add(this.rpc.disconnected$.subscribe(() => this.resetBoardView()));
    this.subs.add(this.rpc.session$.subscribe((evt) => this.handleSessionEvent(evt)));
    this.subs.add(this.rpc.lcdDirty$.subscribe((rect) => this.renderDirtyRect(rect)));
  }

  public attachCanvas(canvas: HTMLCanvasElement, defaultWidth = 800, defaultHeight = 480): void {
    this.renderer = new FramebufferRenderer(canvas, { defaultWidth, defaultHeight });
  }

  public detachCanvas(): void {
    this.renderer = null;
  }

  public importBoardProfileText(fileName: string, rawText: string): boolean {
    try {
      const parsed = parseBoardProfile(rawText);
      const name = fileName.replace(/\.board$/i, '');
      this.boardProfileName.set(name);
      this.boardProfileRaw.set(rawText);
      this.boardProfile.set(parsed);
      this.selectedPreset.set(findBoardPreset(name) ?? null);
      this.rpc.pushToast(`Loaded board profile ${fileName}`);
      return true;
    } catch (err) {
      this.rpc.reportError(`Invalid board profile (${fileName})`, err);
      return false;
    }
  }

  public selectBoardPreset(idOrPartNumber: string): BoardPreset | null {
    const preset =
      findBoardPreset(idOrPartNumber) ??
      this.savedBoards().find(
        (b) => b.id.toLowerCase() === idOrPartNumber.trim().toLowerCase() || b.targetId.toLowerCase() === idOrPartNumber.trim().toLowerCase()
      );
    if (!preset) return null;
    this.selectedPreset.set(preset);
    this.boardProfileName.set(preset.targetId);
    this.boardProfile.set(preset.profile);
    this.boardProfileRaw.set(serializeBoardProfile(preset.profile));
    this.rpc.pushToast(`Selected preset ${preset.name}`);
    return preset;
  }

  public duplicateBoardPreset(preset: BoardPreset): BoardPreset {
    const id = `custom-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
    const copy: BoardPreset = {
      ...preset,
      id,
      partNumber: 'CUSTOM',
      targetId: `${preset.silicon}-${id.slice(-4)}`,
      name: `${preset.name.split('(')[0]!.trim()} Custom`,
      profile: {
        ...preset.profile,
        leds: preset.profile.leds.map((l) => ({ ...l })),
        switches: preset.profile.switches.map((s) => ({ ...s })),
        sensors: [...preset.profile.sensors],
        companions: [...preset.profile.companions],
      },
    };
    this.savedBoards.update((prev) => {
      const next = [copy, ...prev];
      saveSavedBoards(next, (msg) => this.rpc.errorMessage.set(msg));
      return next;
    });
    this.selectBoardPreset(copy.id);
    return copy;
  }

  public removeCustomBoard(id: string): void {
    this.savedBoards.update((prev) => {
      const next = prev.filter((b) => b.id !== id);
      saveSavedBoards(next, (msg) => this.rpc.errorMessage.set(msg));
      return next;
    });
  }

  public exportBoardProfileText(): string {
    const profile = this.boardProfile();
    return profile ? serializeBoardProfile(profile) : this.boardProfileRaw();
  }

  public async refreshBoardParts(): Promise<void> {
    const client = this.rpc.activeClient;
    if (!client) return;
    try {
      const parts = await client.getBoardParts();
      this.boardParts.set(parts);
      if (parts.ledNames.length > 0 && this.ledStates().length !== parts.ledNames.length) {
        this.ledStates.set(Array<boolean>(parts.ledNames.length).fill(false));
      }
    } catch (err) {
      this.rpc.reportError('Failed to fetch board parts', err);
    }
  }

  public async loadElfFile(
    fileName: string,
    bytes: Uint8Array,
    core: Core = Core.Cpu0,
    options: LoadElfOptions = { breakAtMain: false }
  ): Promise<boolean> {
    if (this.rpc.observeOnly()) {
      this.rpc.pushToast('Observe mode is read-only: ELF upload disabled', 'neutral');
      return false;
    }
    const client = this.rpc.activeClient;
    if (!client) {
      this.rpc.reportError('ELF upload skipped', new Error('Not connected to emulator RPC'));
      return false;
    }
    if (core === Core.Cpu1 && !this.execution.cpu1Attached()) {
      this.rpc.reportError('ELF upload refused', new Error('CPU1 is clock-gated in this session'));
      return false;
    }
    const header = inspectElf(bytes);
    if (!header.valid) {
      this.rpc.reportError('Invalid ELF image', new Error(header.reason ?? 'Not an ARM32 ELF'));
      return false;
    }
    if (this.execution.isRunning()) await this.execution.pause();

    this.uploadProgress.set({
      active: true,
      fileName,
      core,
      percent: 0,
      statusText: `Uploading ${fileName}...`,
    });
    try {
      const ok = await client.loadElf(core, bytes, (loaded, total) => {
        const percent = total > 0 ? Math.round((loaded * 100) / total) : 100;
        this.uploadProgress.set({ active: true, fileName, core, percent, statusText: `Uploading ${fileName} (${percent}%)` });
      });
      if (!ok) {
        this.uploadProgress.set(null);
        return false;
      }
      this.recordLoadedElfMetadata(core, fileName, bytes, header.hasDebugInfo);
      try {
        this.memoryMapText.set(await client.getMap(core, true));
      } catch (err) {
        this.rpc.noteOptionalError(err);
      }
      if (core === Core.Cpu0 && typeof document !== 'undefined') {
        document.title = `${fileName} — RA8 Emulator`;
      }
      this.execution.inspectionEpoch.update((n) => n + 1);

      if (options.breakAtMain) {
        const bp = await client.setBreakpointByName(core, 'main');
        if (!bp.deferred) {
          await client.continueRun(core, 2_000_000n);
          this.execution.inspectionEpoch.update((n) => n + 1);
          this.rpc.pushToast(`Loaded ${fileName} and halted at main (${formatHex32(bp.address)})`);
          this.uploadProgress.set(null);
          return true;
        }
      }
      this.uploadProgress.set(null);
      this.rpc.pushToast(`Loaded ${fileName} at reset`);
      return true;
    } catch (err) {
      this.uploadProgress.set(null);
      this.rpc.reportError(`ELF upload failed (${fileName})`, err);
      return false;
    }
  }

  public async sendTouch(
    kind: InputKind,
    x: number,
    y: number,
    toX = 0,
    toY = 0,
    durationNs = 0n
  ): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const atNs = this.execution.virtualTimeNs();
    try {
      return await client.sendInput({ core: Core.Cpu0, atNs, kind, x, y, toX, toY, durationNs });
    } catch (err) {
      this.rpc.reportError('Touch input failed', err);
      return false;
    }
  }

  public async sendButton(buttonIndex: number): Promise<boolean> {
    const client = this.rpc.activeClient;
    if (!client) return false;
    const atNs = this.execution.virtualTimeNs();
    try {
      return await client.sendInput({ core: Core.Cpu0, atNs, kind: InputKind.Button, button: buttonIndex });
    } catch (err) {
      this.rpc.reportError('Button input failed', err);
      return false;
    }
  }

  public async setCamera(spec: string, allowWebcam = false): Promise<boolean> {
    this.cameraSource.set(spec);
    const client = this.rpc.activeClient;
    if (!client) return false;
    try {
      return await client.setCameraSource(spec, allowWebcam);
    } catch (err) {
      this.rpc.reportError('Set camera source failed', err);
      return false;
    }
  }

  public ngOnDestroy(): void {
    this.subs.unsubscribe();
  }

  private recordLoadedElfMetadata(core: Core, fileName: string, bytes: Uint8Array, hasDwarf: boolean): void {
    const syms = parseElfSymbols(bytes);
    if (core === Core.Cpu0) {
      this.cpu0ElfName.set(fileName);
      this.cpu0ElfSymbols.set(syms);
      this.cpu0HasDwarf.set(hasDwarf);
    } else {
      this.cpu1ElfName.set(fileName);
      this.cpu1ElfSymbols.set(syms);
      this.cpu1HasDwarf.set(hasDwarf);
    }
  }

  private handleSessionEvent(evt: SessionEvent): void {
    if (evt.kind !== EventKind.LedChanged) return;
    const { index, on } = decodeLedEvent(evt.address);
    this.ledStates.update((leds) => {
      const next = [...leds];
      while (next.length <= index) next.push(false);
      next[index] = on;
      return next;
    });
  }

  private renderDirtyRect(rect: DirtyRect): void {
    if (!this.renderer) return;
    this.renderer.render(rect);
    this.lcdFps.set(this.renderer.currentFps);
    this.lcdFrames.set(this.renderer.totalFrames);
  }

  private resetBoardView(): void {
    this.boardParts.set(null);
    this.ledStates.set(Array<boolean>(8).fill(false));
    this.uploadProgress.set(null);
    this.memoryMapText.set('');
    if (typeof document !== 'undefined') {
      document.title = 'RA8 Emulator';
    }
  }
}
