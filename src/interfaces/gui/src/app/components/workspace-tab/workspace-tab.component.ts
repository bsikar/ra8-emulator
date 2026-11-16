import { CommonModule } from '@angular/common';
import { Component, EventEmitter, Output, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Core } from 'ra8-rpc-client';
import { CoreArch, SiliconTopology } from '../../models/board-config';
import { EmulatorService } from '../../services/emulator.service';

@Component({
  selector: 'app-workspace-tab',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="ob-page">
      <div class="ob-card">
        <div class="ob-card-head">
          <div class="ob-row">
            <h2 class="ob-card-title">Workspace &amp; Flash Target</h2>
            <span class="ob-pill" [class.ob-pill-ok]="emu.connectionState() === 'connected'"
                  [class.ob-pill-warn]="emu.connectionState() !== 'connected'">
              <span class="ob-dot" [class.ob-dot-ok]="emu.connectionState() === 'connected'"
                    [class.ob-dot-warn]="emu.connectionState() !== 'connected'"></span>
              {{ emu.connectionState() === 'connected' ? 'RPC Connected' : 'Local Preview Ready' }}
            </span>
            <span class="ob-pill ob-pill-accent">{{ emu.transportCapabilitiesSummary }}</span>
          </div>
          <button
            type="button"
            class="ob-btn ob-btn-primary"
            data-testid="primary-cta"
            (click)="flashAndDebug()">
            Flash &amp; Debug (DAP)
          </button>
        </div>

        <div class="ob-card-body">
          <div class="ob-grid-3">
            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Workspace Origin</div>
              <div class="ob-seg" role="group" aria-label="Workspace origin mode">
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.workspaceMode() === 'local'"
                        (click)="emu.setWorkspaceMode('local')">
                  Local
                </button>
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.workspaceMode() === 'remote'"
                        (click)="emu.setWorkspaceMode('remote')">
                  Remote (ws://)
                </button>
              </div>
              <input
                type="text"
                class="ob-input mono"
                [ngModel]="emu.workspaceMode() === 'remote' ? wsUrl() : emu.projectPath()"
                (ngModelChange)="onWorkspacePathChange($event)"
                [placeholder]="emu.workspaceMode() === 'remote' ? 'ws://127.0.0.1:4567' : './build/firmware.elf'"
                aria-label="Workspace path or remote URL" />
            </div>

            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Flash Target</div>
              <div class="ob-seg" role="group" aria-label="Flash target mode">
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.flashTargetMode() === 'local'"
                        (click)="emu.setFlashTargetMode('local')">
                  Local Simulator
                </button>
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.flashTargetMode() === 'remote'"
                        (click)="emu.setFlashTargetMode('remote')">
                  Remote Target
                </button>
              </div>
              <div class="ob-row">
                <button type="button" class="ob-btn ob-btn-sm" (click)="connectTarget()">
                  {{ emu.connectionState() === 'connected' ? 'Reconnect WS' : 'Connect WS' }}
                </button>
                <span class="mono ob-muted">{{ emu.serverUrl() }}</span>
              </div>
            </div>

            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Portable Time-Travel Archive</div>
              <div class="ob-row">
                <button type="button" class="ob-btn ob-btn-sm" (click)="tarInput.click()">
                  Import Time-Travel Tarball (.tar.gz)
                </button>
                <input #tarInput type="file" accept=".tar.gz,.tgz" hidden (change)="onTarSelected($event)" />
              </div>
              <span class="ob-muted">
                {{ emu.lastArchiveSummary() ?? 'Load an exported checkpoint tree & board session archive.' }}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div class="ob-split-2">
        <div class="ob-card">
          <div class="ob-card-head">
            <h2 class="ob-card-title">Board Configuration (.board)</h2>
            <div class="ob-row">
              <button type="button" class="ob-btn ob-btn-sm" (click)="boardInput.click()">
                Import .board
              </button>
              <input #boardInput type="file" accept=".board,.txt,.cfg" hidden (change)="onBoardFileSelected($event)" />
            </div>
          </div>
          <div class="ob-card-body">
            <div class="ob-section-label">Saved Presets</div>
            <div class="ob-row">
              @for (preset of emu.boardPresets; track preset.id) {
                <button
                  type="button"
                  class="ob-btn ob-btn-sm"
                  [class.active]="emu.activeBoardConfig().id === preset.id"
                  (click)="emu.selectBoardPreset(preset.id)">
                  {{ preset.name }}
                </button>
              }
            </div>

            <div class="ob-section-label">Silicon Permutation</div>
            <div class="ob-row">
              <div class="ob-seg" role="group" aria-label="Silicon topology mode">
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.activeBoardConfig().topology === 'single'"
                        (click)="setTopology('single')">
                  Single-Core
                </button>
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.activeBoardConfig().topology === 'dual'"
                        (click)="setTopology('dual')">
                  Dual-Core
                </button>
                <button type="button" class="ob-seg-btn"
                        [class.active]="emu.activeBoardConfig().topology === 'multi'"
                        (click)="setTopology('multi')">
                  Multi-Core
                </button>
              </div>
              <button
                type="button"
                class="ob-btn ob-btn-sm"
                [class.active]="emu.activeBoardConfig().npuEnabled"
                (click)="emu.toggleBoardNpu()">
                Ethos-U55 NPU: {{ emu.activeBoardConfig().npuEnabled ? 'ON (500 MHz)' : 'OFF' }}
              </button>
            </div>

            <div class="ob-between">
              <span class="ob-section-label">
                Compute Cores ({{ emu.activeBoardConfig().cores.length }})
              </span>
              <div class="ob-row">
                <button type="button" class="ob-btn ob-btn-sm" (click)="addCore('Cortex-M85')">+ Cortex-M85</button>
                <button type="button" class="ob-btn ob-btn-sm" (click)="addCore('Cortex-M33')">+ Cortex-M33</button>
              </div>
            </div>

            <div class="ob-table-wrap">
              <table class="ob-table">
                <thead>
                  <tr>
                    <th>Core</th>
                    <th>Architecture</th>
                    <th>Clock</th>
                    <th>Role</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  @for (core of emu.activeBoardConfig().cores; track core.id; let i = $index) {
                    <tr>
                      <td class="mono">{{ core.id }}</td>
                      <td>{{ core.arch }}</td>
                      <td class="mono">{{ core.clockMhz }} MHz</td>
                      <td>{{ core.role }}</td>
                      <td>
                        @if (emu.activeBoardConfig().cores.length > 1) {
                          <button type="button" class="ob-btn ob-btn-sm ob-btn-ghost" (click)="emu.removeBoardCore(i)">
                            Remove
                          </button>
                        }
                      </td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>

            <div class="ob-row ob-muted">
              <span>OSPI: <strong class="mono">{{ emu.activeBoardConfig().ospiMiB }} MiB</strong></span>
              <span>SDRAM: <strong class="mono">{{ emu.activeBoardConfig().sdramMiB }} MiB</strong></span>
              <span>Panel: <strong class="mono">{{ emu.activeBoardConfig().panel }}</strong></span>
            </div>
          </div>
        </div>

        <div class="ob-card">
          <div class="ob-card-head">
            <h2 class="ob-card-title">Firmware ELF &amp; Decompiler Routing</h2>
            <span class="ob-pill ob-pill-accent">RA8EMU-1247 Auto-Detect</span>
          </div>
          <div class="ob-card-body">
            <div class="ob-subpanel ob-stack">
              <div class="ob-between">
                <div>
                  <strong>CPU0 Firmware ({{ emu.activeBoardConfig().cores.length > 0 ? emu.activeBoardConfig().cores[0].arch : 'Cortex-M85' }})</strong>
                  <div class="mono ob-muted">
                    {{ emu.cpu0ElfName() ?? 'firmware_vision_stripped.elf (Demo)' }}
                  </div>
                </div>
                <span class="ob-pill" [class.ob-pill-ok]="emu.cpu0HasDwarf()" [class.ob-pill-warn]="!emu.cpu0HasDwarf()">
                  {{ emu.cpu0HasDwarf() ? 'DWARF Source Ready' : 'Stripped ELF · Auto-Decompile' }}
                </span>
              </div>
              <div class="ob-row">
                <button type="button" class="ob-btn ob-btn-sm" (click)="elf0Input.click()">Load CPU0 ELF</button>
                <input #elf0Input type="file" accept=".elf,.axf,.out" hidden (change)="onElfSelected($event, Core.Cpu0)" />
              </div>
            </div>

            @if (emu.activeBoardConfig().cores.length > 1) {
              <div class="ob-subpanel ob-stack">
                <div class="ob-between">
                  <div>
                    <strong>CPU1 Firmware ({{ emu.activeBoardConfig().cores[1].arch }})</strong>
                    <div class="mono ob-muted">
                      {{ emu.cpu1ElfName() ?? 'companion_sensor_hub.elf' }}
                    </div>
                  </div>
                  <span class="ob-pill" [class.ob-pill-ok]="emu.cpu1HasDwarf()" [class.ob-pill-accent]="!emu.cpu1HasDwarf()">
                    {{ emu.cpu1HasDwarf() ? 'DWARF Source Ready' : 'Auto-Decompile Ready' }}
                  </span>
                </div>
                <div class="ob-row">
                  <button type="button" class="ob-btn ob-btn-sm" (click)="elf1Input.click()">Load CPU1 ELF</button>
                  <input #elf1Input type="file" accept=".elf,.axf,.out" hidden (change)="onElfSelected($event, Core.Cpu1)" />
                </div>
              </div>
            }

            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Active .board Manifest Preview</div>
              <pre class="mono ob-manifest">{{ emu.importedBoardRaw() }}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
  `,
  styles: [
    `:host { display: block; height: 100%; overflow: auto; font-size: 12px; }
     .ob-muted { color: var(--text-secondary); font-size: 12px; }
     .ob-manifest { margin: 0; font-size: 12px; color: var(--text-secondary); white-space: pre-wrap; }`,
  ],
})
export class WorkspaceTabComponent {
  public readonly emu = inject(EmulatorService);
  protected readonly Core = Core;

  @Output() public readonly enterDebug = new EventEmitter<void>();

  public readonly wsUrl = signal(this.emu.serverUrl());

  public setTopology(mode: SiliconTopology): void {
    this.emu.setBoardTopology(mode);
  }

  public addCore(arch: CoreArch): void {
    this.emu.addBoardCore(arch);
  }

  public onWorkspacePathChange(val: string): void {
    if (this.emu.workspaceMode() === 'remote') {
      this.wsUrl.set(val);
    } else {
      this.emu.projectPath.set(val);
    }
  }

  public async connectTarget(): Promise<void> {
    await this.emu.connect(this.wsUrl());
  }

  public async flashAndDebug(): Promise<void> {
    if (this.emu.workspaceMode() === 'remote' && this.emu.connectionState() !== 'connected') {
      await this.emu.connect(this.wsUrl());
    }
    this.enterDebug.emit();
  }

  public async onBoardFileSelected(evt: Event): Promise<void> {
    const file = (evt.target as HTMLInputElement).files?.[0];
    if (!file) return;
    const text = await file.text();
    this.emu.importBoardText(file.name, text);
  }

  public async onElfSelected(evt: Event, core: Core): Promise<void> {
    const file = (evt.target as HTMLInputElement).files?.[0];
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    await this.emu.loadElfFile(file.name, bytes, core);
  }

  public async onTarSelected(evt: Event): Promise<void> {
    const file = (evt.target as HTMLInputElement).files?.[0];
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    await this.emu.importTimeTravelArchive(file.name, bytes);
  }
}
