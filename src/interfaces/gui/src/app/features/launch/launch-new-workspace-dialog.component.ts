import { ChangeDetectionStrategy, Component, computed, inject, input, output, signal } from '@angular/core';
import { type BoardPreset, OFFICIAL_BOARD_PRESETS, inspectElf } from 'ra8-rpc-client';
import { BoardStore } from '../../core/stores/board.store';
import { RemoteHostsStore } from '../../core/stores/remote-hosts.store';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { pickBrowserFile } from '../../shared/utils/file-picker';
import { formatByteSize } from '../bundles/bundle-summary';
import { BoardDetailsModalComponent } from '../workspace/board-details-modal.component';
import { formatPresetArchSummary } from './launch-commands';

export type WorkspaceExecutionMode = 'Emulator' | 'Hardware (SWD / HIL)' | 'Prebuilt .elf';
export type ProjectSourceKind = 'Source Project' | 'Prebuilt .elf' | 'Device Monitor';

export interface NewWorkspacePayload {
  preset: BoardPreset;
  name: string;
  path: string;
  wsUrl: string;
  modeLabel: WorkspaceExecutionMode;
  sourceKind?: ProjectSourceKind;
  recording?: boolean;
  cpu0ElfFile?: { name: string; bytes: Uint8Array } | null;
}

const MODES: readonly WorkspaceExecutionMode[] = ['Emulator', 'Hardware (SWD / HIL)', 'Prebuilt .elf'];
const SOURCES: readonly ProjectSourceKind[] = ['Source Project', 'Prebuilt .elf', 'Device Monitor'];

@Component({
  selector: 'app-launch-new-workspace-dialog',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent, BoardDetailsModalComponent],
  templateUrl: './launch-new-workspace-dialog.component.html',
  styleUrl: './launch-new-workspace-dialog.component.css',
})
export class LaunchNewWorkspaceDialogComponent {
  protected readonly boardStore = inject(BoardStore);
  protected readonly remoteHosts = inject(RemoteHostsStore);

  public readonly open = input<boolean>(false);
  public readonly standalone = input<boolean>(false);
  public readonly defaultWsUrl = input<string>('ws://127.0.0.1:4567');
  public readonly closed = output<void>();
  public readonly created = output<NewWorkspacePayload>();

  protected readonly modes = MODES;
  protected readonly sources = SOURCES;
  protected readonly boardQuery = signal<string>('');
  protected readonly selectedPresetId = signal<string>(OFFICIAL_BOARD_PRESETS[0]!.id);
  protected readonly selectedMode = signal<WorkspaceExecutionMode>('Emulator');
  protected readonly selectedSource = signal<ProjectSourceKind>('Source Project');
  protected readonly name = signal<string>('EK-RA8D2 Session');
  protected readonly path = signal<string>('~/work/ra8d2-session');
  protected readonly wsUrl = signal<string>('ws://127.0.0.1:4567');
  protected readonly recording = signal<boolean>(false);
  protected readonly pickedElf = signal<{ name: string; bytes: Uint8Array; entryHex: string } | null>(null);
  protected readonly elfError = signal<string | null>(null);
  protected readonly inspectedBoard = signal<BoardPreset | null>(null);
  private userEditedName = false;

  protected readonly allBoards = computed<BoardPreset[]>(() => [
    ...OFFICIAL_BOARD_PRESETS,
    ...this.boardStore.savedBoards(),
  ]);

  protected readonly filteredBoards = computed<BoardPreset[]>(() => {
    const q = this.boardQuery().trim().toLowerCase();
    const list = this.allBoards();
    if (!q) return list;
    return list.filter(
      (b) =>
        b.name.toLowerCase().includes(q) ||
        b.partNumber.toLowerCase().includes(q) ||
        b.targetId.toLowerCase().includes(q)
    );
  });

  protected readonly selectedPreset = computed<BoardPreset>(
    () => this.allBoards().find((p) => p.id === this.selectedPresetId()) ?? OFFICIAL_BOARD_PRESETS[0]!
  );

  protected readonly canSubmit = computed(() => this.name().trim().length > 0 && this.wsUrl().trim().length > 0);

  protected presetMeta(preset: BoardPreset): string {
    return formatPresetArchSummary(preset);
  }

  protected boardSpecSubline(preset: BoardPreset): string {
    const stem = `${preset.targetId.replace(/-/g, '_')}.board`;
    const ospiMb = Math.max(1, Math.round(preset.profile.memory.ospi.size / (1024 * 1024)));
    const sdramMb = Math.max(1, Math.round(preset.profile.memory.sdram.size / (1024 * 1024)));
    return `${stem} · ${ospiMb} MB OSPI · ${sdramMb} MB SDRAM`;
  }

  protected selectPreset(preset: BoardPreset): void {
    this.selectedPresetId.set(preset.id);
    if (!this.userEditedName) {
      this.name.set(`${preset.targetId.toUpperCase()} Session`);
      this.path.set(`~/work/${preset.targetId}-session`);
    }
  }

  protected onSearchInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.boardQuery.set(event.target.value);
  }

  protected onNameInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) {
      this.userEditedName = true;
      this.name.set(event.target.value);
    }
  }

  protected onPathInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.path.set(event.target.value);
  }

  protected onUrlInput(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.wsUrl.set(event.target.value);
  }

  protected onHostPresetSelect(event: Event): void {
    if (event.target instanceof HTMLSelectElement && event.target.value) {
      this.wsUrl.set(event.target.value);
    }
  }

  protected onRecordingToggle(event: Event): void {
    if (event.target instanceof HTMLInputElement) this.recording.set(event.target.checked);
  }

  protected duplicateBoard(preset: BoardPreset): void {
    const copy = this.boardStore.duplicateBoardPreset(preset);
    this.selectedPresetId.set(copy.id);
    this.inspectedBoard.set(null);
  }

  protected async importBoardFile(): Promise<void> {
    const file = await pickBrowserFile({
      accept: '.board',
      description: 'RA8 Board Profile (.board)',
      extensions: ['.board'],
    });
    if (!file) return;
    const text = await file.text();
    if (this.boardStore.importBoardProfileText(file.name, text)) {
      const base = this.boardStore.selectedPreset() ?? OFFICIAL_BOARD_PRESETS[0]!;
      const imported = this.boardStore.duplicateBoardPreset({
        ...base,
        name: file.name.replace(/\.board$/i, ''),
      });
      this.selectedPresetId.set(imported.id);
    }
  }

  protected async pickCpu0Elf(): Promise<void> {
    const file = await pickBrowserFile({
      accept: '.elf,.axf',
      description: 'ARM Firmware ELF (.elf / .axf)',
      extensions: ['.elf', '.axf'],
    });
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const header = inspectElf(bytes);
    if (!header.valid) {
      this.elfError.set(header.reason ?? 'Selected file is not a valid ARM32 ELF');
      return;
    }
    this.elfError.set(null);
    this.pickedElf.set({
      name: file.name,
      bytes,
      entryHex: `0x${(header.entry >>> 0).toString(16).padStart(8, '0')}`,
    });
  }

  protected formatBytes(bytes: number): string {
    return formatByteSize(bytes);
  }

  protected submit(): void {
    if (!this.canSubmit()) return;
    const elf = this.pickedElf();
    this.created.emit({
      preset: this.selectedPreset(),
      name: this.name().trim(),
      path: this.path().trim() || `~/work/${this.selectedPreset().targetId}`,
      wsUrl: this.wsUrl().trim() || this.defaultWsUrl(),
      modeLabel: this.selectedMode(),
      sourceKind: this.selectedSource(),
      recording: this.recording(),
      cpu0ElfFile: elf ? { name: elf.name, bytes: elf.bytes } : null,
    });
  }
}
