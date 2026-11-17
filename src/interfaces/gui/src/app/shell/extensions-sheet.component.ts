import { ChangeDetectionStrategy, Component, inject, input, output, signal } from '@angular/core';
import {
  ExtensionStore,
  type ExtensionViewState,
  type ExtensionWorkerStatus,
  STARTER_EXTENSION_MANIFEST,
} from '../core/extensions/extension.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent, type StatusTone } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';

interface CommandDisplay {
  command: string;
  title: string;
}

interface PanelDisplay {
  id: string;
  title: string;
  stateJson: string;
}

function buildStarterJsonSnippet(): string {
  const { mainSource: _ignored, ...rest } = STARTER_EXTENSION_MANIFEST;
  return JSON.stringify(rest, null, 2);
}

@Component({
  selector: 'app-extensions-sheet',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [SectionKickerComponent, StatusDotComponent, TonalButtonComponent],
  styleUrl: './extensions-sheet.component.css',
  template: `
    @if (open()) {
      <div class="sheet-backdrop" (click)="closed.emit()">
        <div
          class="ext-sheet"
          role="dialog"
          aria-modal="true"
          aria-label="Extensions"
          data-testid="extensions-sheet-dialog"
          (click)="$event.stopPropagation()"
          (keydown.escape)="closed.emit()"
        >
          <div class="sheet-head">
            <div class="head-left">
              <app-section-kicker label="EXTENSIONS" />
              <span class="es-meta">{{ extStore.extensions().length }} installed</span>
            </div>
            <div class="head-actions">
              <app-tonal-button
                variant="ghost"
                testId="ext-toggle-install-drawer"
                (pressed)="toggleDrawer()"
              >
                + Install Extension
              </app-tonal-button>
              <app-tonal-button
                testId="ext-load-template"
                (pressed)="loadExampleTemplate()"
              >
                Load Example Template
              </app-tonal-button>
              <app-tonal-button variant="ghost" testId="ext-close-btn" (pressed)="closed.emit()">
                Close
              </app-tonal-button>
            </div>
          </div>

          @if (drawerError() || extStore.lastError()) {
            <p class="error-text" data-testid="ext-error">{{ drawerError() || extStore.lastError() }}</p>
          }

          @if (drawerOpen()) {
            <div class="drawer-box" data-testid="ext-install-drawer">
              <label class="drawer-field">
                <span class="es-meta">Manifest JSON (id, name, publisher, displayName, version, contributes)</span>
                <textarea
                  class="code-textarea mono"
                  data-testid="ext-manifest-json"
                  [value]="manifestJsonText()"
                  (input)="onManifestInput($event)"
                ></textarea>
              </label>

              <label class="drawer-field">
                <span class="es-meta">Worker Script (mainSource JS)</span>
                <textarea
                  class="code-textarea mono"
                  data-testid="ext-source-js"
                  [value]="workerJsText()"
                  (input)="onJsInput($event)"
                ></textarea>
              </label>

              <div class="drawer-actions">
                <button
                  type="button"
                  class="es-ghost-link"
                  data-testid="ext-prefill-template"
                  (click)="prefillTemplate()"
                >
                  Prefill Example Template
                </button>
                <div class="head-actions">
                  <app-tonal-button variant="ghost" (pressed)="drawerOpen.set(false)">Cancel</app-tonal-button>
                  <app-tonal-button testId="ext-install-submit" (pressed)="installFromDrawer()">
                    Install &amp; Activate
                  </app-tonal-button>
                </div>
              </div>
            </div>
          }

          <div class="ext-scroll" data-testid="ext-list">
            @for (ext of extStore.extensions(); track ext.manifest.id) {
              <div class="ext-row" [attr.data-testid]="'ext-row-' + ext.manifest.id">
                <div class="ext-top">
                  <div class="ext-title-wrap">
                    <span class="ext-name">{{ ext.manifest.displayName }}</span>
                    <span class="es-subline">{{ ext.manifest.id }} · v{{ ext.manifest.version }}</span>
                    <app-status-dot [tone]="workerTone(ext.workerStatus)" [label]="ext.workerStatus" />
                  </div>
                  <div class="ext-actions">
                    <app-tonal-button
                      variant="ghost"
                      [testId]="'ext-toggle-' + ext.manifest.id"
                      (pressed)="toggleEnabled(ext)"
                    >
                      {{ ext.enabled ? 'Disable' : 'Enable' }}
                    </app-tonal-button>
                    <app-tonal-button
                      variant="ghost"
                      [testId]="'ext-uninstall-' + ext.manifest.id"
                      (pressed)="extStore.uninstallExtension(ext.manifest.id)"
                    >
                      Uninstall
                    </app-tonal-button>
                  </div>
                </div>

                @if (ext.manifest.description) {
                  <p class="es-meta ext-desc">{{ ext.manifest.description }}</p>
                }
                @if (ext.lastError) {
                  <p class="error-text">{{ ext.lastError }}</p>
                }

                @if (commandsFor(ext).length > 0) {
                  <div class="cmd-list">
                    @for (cmd of commandsFor(ext); track cmd.command) {
                      <div class="cmd-row">
                        <div class="cmd-info">
                          <span class="cmd-title">{{ cmd.title }}</span>
                          <span class="es-subline">{{ cmd.command }}</span>
                        </div>
                        <app-tonal-button
                          [testId]="'ext-run-' + cmd.command"
                          [disabled]="!ext.enabled || ext.workerStatus !== 'active'"
                          (pressed)="runCommand(cmd.command)"
                        >
                          Run
                        </app-tonal-button>
                      </div>
                    }
                  </div>
                }

                @for (panel of panelsFor(ext); track panel.id) {
                  <pre class="panel-pre mono" [attr.data-testid]="'ext-panel-' + panel.id">{{ panel.title }}: {{ panel.stateJson }}</pre>
                }
              </div>
            } @empty {
              <div class="ext-empty" data-testid="ext-empty-state">
                <p class="es-meta">
                  No extensions installed. Install a sandboxed Web Worker extension or load the example template.
                </p>
                <div class="head-actions">
                  <app-tonal-button (pressed)="loadExampleTemplate()">Load Example Template</app-tonal-button>
                  <app-tonal-button variant="ghost" (pressed)="toggleDrawer()">+ Install Extension</app-tonal-button>
                </div>
              </div>
            }

            @if (extStore.messages().length > 0) {
              <div class="msg-box" data-testid="ext-messages">
                <div class="msg-head">
                  <span class="es-kicker">WORKER OUTPUT</span>
                  <button type="button" class="es-ghost-link" (click)="extStore.clearMessages()">Clear</button>
                </div>
                @for (msg of extStore.messages(); track msg.id) {
                  <div class="msg-line mono" [class.is-warn]="msg.tone === 'warning'">
                    [{{ msg.extensionId }}] {{ msg.text }}
                  </div>
                }
              </div>
            }
          </div>
        </div>
      </div>
    }
  `,
})
export class ExtensionsSheetComponent {
  public readonly open = input<boolean>(false);
  public readonly closed = output<void>();

  protected readonly extStore = inject(ExtensionStore);
  protected readonly drawerOpen = signal<boolean>(false);
  protected readonly manifestJsonText = signal<string>(buildStarterJsonSnippet());
  protected readonly workerJsText = signal<string>(STARTER_EXTENSION_MANIFEST.mainSource);
  protected readonly drawerError = signal<string | null>(null);

  protected toggleDrawer(): void {
    this.drawerError.set(null);
    this.drawerOpen.update((v) => !v);
  }

  protected prefillTemplate(): void {
    this.drawerError.set(null);
    this.manifestJsonText.set(buildStarterJsonSnippet());
    this.workerJsText.set(STARTER_EXTENSION_MANIFEST.mainSource);
  }

  protected async loadExampleTemplate(): Promise<void> {
    this.drawerError.set(null);
    await this.extStore.installStarterExample();
  }

  protected async installFromDrawer(): Promise<void> {
    this.drawerError.set(null);
    let parsed: unknown;
    try {
      parsed = JSON.parse(this.manifestJsonText());
    } catch (err) {
      this.drawerError.set(`Invalid manifest JSON: ${err instanceof Error ? err.message : String(err)}`);
      return;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      this.drawerError.set('Manifest JSON must be an object');
      return;
    }
    const record = { ...(parsed as Record<string, unknown>) };
    const js = this.workerJsText().trim();
    if (js.length > 0) {
      record['mainSource'] = js;
    }
    const res = await this.extStore.installExtension(record, { enable: true });
    if (!res.ok) {
      this.drawerError.set((res.errors ?? ['Extension installation failed']).join('; '));
      return;
    }
    this.drawerOpen.set(false);
  }

  protected toggleEnabled(ext: ExtensionViewState): void {
    if (ext.enabled) {
      this.extStore.disableExtension(ext.manifest.id);
    } else {
      void this.extStore.enableExtension(ext.manifest.id);
    }
  }

  protected runCommand(commandId: string): void {
    void this.extStore.executeContributedCommand(commandId);
  }

  protected commandsFor(ext: ExtensionViewState): CommandDisplay[] {
    const out: CommandDisplay[] = ext.manifest.contributes.commands.map((c) => ({
      command: c.command,
      title: c.title,
    }));
    const seen = new Set(out.map((c) => c.command));
    for (const dyn of ext.registeredWorkerCommands) {
      if (!seen.has(dyn)) out.push({ command: dyn, title: dyn });
    }
    return out;
  }

  protected panelsFor(ext: ExtensionViewState): PanelDisplay[] {
    const out: PanelDisplay[] = [];
    for (const panel of ext.manifest.contributes.panels) {
      const state = ext.panelStates[panel.id];
      if (state !== undefined) {
        out.push({ id: panel.id, title: panel.title, stateJson: JSON.stringify(state) });
      }
    }
    return out;
  }

  protected workerTone(status: ExtensionWorkerStatus): StatusTone {
    if (status === 'active') return 'nominal';
    if (status === 'activating') return 'cursor';
    if (status === 'error') return 'fault';
    return 'muted';
  }

  protected onManifestInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLTextAreaElement) this.manifestJsonText.set(target.value);
  }

  protected onJsInput(event: Event): void {
    const target = event.target;
    if (target instanceof HTMLTextAreaElement) this.workerJsText.set(target.value);
  }
}
