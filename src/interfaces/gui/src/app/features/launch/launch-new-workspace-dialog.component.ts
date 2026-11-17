import { ChangeDetectionStrategy, Component, computed, input, output, signal } from '@angular/core';
import { type BoardPreset, OFFICIAL_BOARD_PRESETS } from 'ra8-rpc-client';
import { SectionKickerComponent } from '../../shared/ui/section-kicker.component';
import { TonalButtonComponent } from '../../shared/ui/tonal-button.component';
import { formatPresetArchSummary } from './launch-commands';

export type WorkspaceExecutionMode = 'Emulator' | 'Hardware (SWD / HIL)' | 'Prebuilt .elf';

export interface NewWorkspacePayload {
  preset: BoardPreset;
  name: string;
  path: string;
  wsUrl: string;
  modeLabel: WorkspaceExecutionMode;
}

const MODES: readonly WorkspaceExecutionMode[] = ['Emulator', 'Hardware (SWD / HIL)', 'Prebuilt .elf'];

@Component({
  selector: 'app-launch-new-workspace-dialog',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, TonalButtonComponent],
  template: `
    @if (open()) {
      <div class="sheet-backdrop" (click)="closed.emit()">
        <div
          class="sheet-card"
          role="dialog"
          aria-modal="true"
          aria-label="New Workspace"
          data-testid="new-workspace-dialog"
          (click)="$event.stopPropagation()"
          (keydown.escape)="closed.emit()"
        >
          <div class="sheet-head">
            <app-section-kicker label="NEW WORKSPACE" />
            <button type="button" class="es-ghost-link" (click)="closed.emit()">Cancel</button>
          </div>

          <div class="field-group">
            <span class="es-kicker">TARGET BOARD PROFILE</span>
            <div class="preset-grid">
              @for (preset of presets; track preset.id) {
                <button
                  type="button"
                  class="preset-row"
                  [class.is-active]="preset.id === selectedPresetId()"
                  [attr.data-testid]="'preset-' + preset.targetId"
                  (click)="selectPreset(preset)"
                >
                  <span class="preset-name">{{ preset.targetId.toUpperCase() }}</span>
                  <span class="es-meta">{{ presetMeta(preset) }}</span>
                </button>
              }
            </div>
          </div>

          <div class="field-group">
            <span class="es-kicker">EXECUTION MODE</span>
            <div class="mode-strip" role="radiogroup" aria-label="Execution mode">
              @for (mode of modes; track mode) {
                <button
                  type="button"
                  role="radio"
                  class="mode-tab"
                  [class.is-active]="mode === selectedMode()"
                  [attr.aria-checked]="mode === selectedMode()"
                  (click)="selectedMode.set(mode)"
                >
                  {{ mode }}
                </button>
              }
            </div>
          </div>

          <label class="field-label">
            <span class="es-meta">Workspace Name</span>
            <input
              type="text"
              class="line-input"
              data-testid="new-ws-name"
              [value]="name()"
              (input)="onNameInput($event)"
              placeholder="EK-RA8D2 Debug Session"
            />
          </label>

          <label class="field-label">
            <span class="es-meta">Workspace Path or Artifact</span>
            <input
              type="text"
              class="line-input mono"
              data-testid="new-ws-path"
              [value]="path()"
              (input)="onPathInput($event)"
              placeholder="~/work/ra8d2-session"
            />
          </label>

          <label class="field-label">
            <span class="es-meta">WebSocket RPC Endpoint</span>
            <input
              type="text"
              class="line-input mono"
              data-testid="new-ws-url"
              [value]="wsUrl()"
              (input)="onUrlInput($event)"
              placeholder="ws://127.0.0.1:4567"
            />
          </label>

          <div class="sheet-actions">
            <app-tonal-button variant="ghost" (pressed)="closed.emit()">Cancel</app-tonal-button>
            <app-tonal-button testId="new-ws-create-btn" [disabled]="!canSubmit()" (pressed)="submit()">
              Create Workspace
            </app-tonal-button>
          </div>
        </div>
      </div>
    }
  `,
  styles: [
    `
      .sheet-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(11, 14, 21, 0.78);
        backdrop-filter: blur(8px);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 72;
      }
      .sheet-card {
        width: min(560px, calc(100vw - 32px));
        background: var(--es-container);
        border: 1px solid var(--es-border);
        border-radius: var(--es-radius-xl);
        padding: 20px 22px;
        display: flex;
        flex-direction: column;
        gap: 14px;
      }
      .sheet-head,
      .sheet-actions {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
      }
      .sheet-actions {
        justify-content: flex-end;
        padding-top: 8px;
        border-top: 1px solid var(--es-divider);
      }
      .field-group,
      .field-label {
        display: flex;
        flex-direction: column;
        gap: 6px;
      }
      .preset-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 8px;
      }
      .preset-row {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        gap: 2px;
        padding: 9px 12px;
        border: 1px solid var(--es-border);
        border-left: 2px solid transparent;
        border-radius: var(--es-radius-md);
        background: var(--es-chrome);
        color: var(--es-text-secondary);
        text-align: left;
        cursor: pointer;
      }
      .preset-row.is-active,
      .preset-row:hover {
        background: var(--es-interactive);
        border-left-color: var(--es-signal-cursor);
        color: var(--es-text-primary);
      }
      .preset-name {
        font-size: 13px;
        font-weight: 500;
      }
      .mode-strip {
        display: flex;
        gap: 14px;
        border-bottom: 1px solid var(--es-divider);
      }
      .mode-tab {
        padding: 6px 2px;
        border: 0;
        border-bottom: 1px solid transparent;
        background: transparent;
        color: var(--es-text-muted);
        font-family: var(--font-sans);
        font-size: 12px;
        cursor: pointer;
      }
      .mode-tab.is-active {
        color: var(--es-text-primary);
        border-bottom-color: var(--es-signal-cursor);
      }
      .line-input {
        height: 32px;
        border: 0;
        border-bottom: 1px solid var(--es-border);
        background: transparent;
        color: var(--es-text-primary);
        font-family: var(--font-sans);
        font-size: 13px;
        outline: none;
      }
      .line-input:focus {
        border-bottom-color: var(--es-text-kicker);
      }
    `,
  ],
})
export class LaunchNewWorkspaceDialogComponent {
  public readonly open = input<boolean>(false);
  public readonly defaultWsUrl = input<string>('ws://127.0.0.1:4567');
  public readonly closed = output<void>();
  public readonly created = output<NewWorkspacePayload>();

  protected readonly presets = OFFICIAL_BOARD_PRESETS;
  protected readonly modes = MODES;
  protected readonly selectedPresetId = signal<string>(OFFICIAL_BOARD_PRESETS[0]!.id);
  protected readonly selectedMode = signal<WorkspaceExecutionMode>('Emulator');
  protected readonly name = signal<string>('EK-RA8D2 Session');
  protected readonly path = signal<string>('~/work/ra8d2-session');
  protected readonly wsUrl = signal<string>('ws://127.0.0.1:4567');
  private userEditedName = false;

  protected readonly selectedPreset = computed<BoardPreset>(
    () => this.presets.find((p) => p.id === this.selectedPresetId()) ?? this.presets[0]!
  );
  protected readonly canSubmit = computed(() => this.name().trim().length > 0 && this.wsUrl().trim().length > 0);

  protected presetMeta(preset: BoardPreset): string {
    return formatPresetArchSummary(preset);
  }

  protected selectPreset(preset: BoardPreset): void {
    this.selectedPresetId.set(preset.id);
    if (!this.userEditedName) {
      this.name.set(`${preset.targetId.toUpperCase()} Session`);
      this.path.set(`~/work/${preset.targetId}-session`);
    }
  }

  protected onNameInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) {
      this.userEditedName = true;
      this.name.set(target.value);
    }
  }

  protected onPathInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) this.path.set(target.value);
  }

  protected onUrlInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLInputElement) this.wsUrl.set(target.value);
  }

  protected submit(): void {
    if (!this.canSubmit()) return;
    this.created.emit({
      preset: this.selectedPreset(),
      name: this.name().trim(),
      path: this.path().trim() || `~/work/${this.selectedPreset().targetId}`,
      wsUrl: this.wsUrl().trim() || this.defaultWsUrl(),
      modeLabel: this.selectedMode(),
    });
  }
}
