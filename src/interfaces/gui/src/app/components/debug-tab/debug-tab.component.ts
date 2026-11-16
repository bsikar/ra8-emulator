import { CommonModule } from '@angular/common';
import { Component, EventEmitter, Input, Output, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Core } from 'ra8-rpc-client';
import { CodeViewMode, EmulatorService } from '../../services/emulator.service';
import { CallStackComponent } from '../call-stack/call-stack.component';
import { DisassemblyViewComponent } from '../disassembly-view/disassembly-view.component';
import { LocalsWatchComponent } from '../locals-watch/locals-watch.component';
import { MemoryInspectorComponent } from '../memory-inspector/memory-inspector.component';
import { RegisterInspectorComponent } from '../register-inspector/register-inspector.component';
import { UartTerminalComponent } from '../uart-terminal/uart-terminal.component';
import { VirtualBoardComponent } from '../virtual-board/virtual-board.component';

export type DebugDrawerTab = 'registers' | 'locals' | 'memory';

@Component({
  selector: 'app-debug-tab',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    CallStackComponent,
    VirtualBoardComponent,
    UartTerminalComponent,
    DisassemblyViewComponent,
    RegisterInspectorComponent,
    LocalsWatchComponent,
    MemoryInspectorComponent,
  ],
  template: `
    <div class="ob-debug-wrap">
      <div class="ob-debug-grid ob-grow-pane">
        <!-- Left Rail (20%): Symbols & Breakpoints -->
        <aside class="ob-pane" aria-label="Workspace symbols and breakpoints">
          <div class="ob-card-head">
            <span class="ob-section-label">WORKSPACE &amp; SYMBOLS</span>
            <span class="mono ob-muted">DAP</span>
          </div>
          <div class="ob-pane-scroll ob-stack">
            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Loaded Target</div>
              <span class="mono">{{ emu.projectPath() }}</span>
              <span class="ob-muted">
                {{ emu.activeCore() === Core.Cpu1 ? (emu.cpu1ElfName() ?? 'companion_cpu1.elf') : (emu.cpu0ElfName() ?? 'vision_demo.elf') }}
              </span>
            </div>

            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Breakpoints ({{ emu.allBreakpoints().length }})</div>
              @if (emu.allBreakpoints().length === 0) {
                <span class="ob-muted">Click any address or source line to toggle a breakpoint.</span>
              } @else {
                @for (bp of emu.allBreakpoints(); track bp.address + ':' + bp.core) {
                  <div class="ob-between">
                    <span class="mono">{{ bp.label || ('0x' + bp.address.toString(16)) }}</span>
                    <button type="button" class="ob-btn ob-btn-sm ob-btn-ghost" (click)="emu.removeBreakpointEntry(bp)">
                      Clear
                    </button>
                  </div>
                }
              }
            </div>

            <div class="ob-subpanel ob-stack">
              <div class="ob-section-label">Watchpoints ({{ emu.watchpoints().length }})</div>
              @if (emu.watchpoints().length === 0) {
                <span class="ob-muted">No active memory watchpoints.</span>
              } @else {
                @for (wp of emu.watchpoints(); track wp.id) {
                  <div class="ob-between">
                    <span class="mono">0x{{ wp.first.toString(16) }}..0x{{ wp.last.toString(16) }}</span>
                    <button type="button" class="ob-btn ob-btn-sm ob-btn-ghost" (click)="emu.removeWatchpoint(wp)">
                      Clear
                    </button>
                  </div>
                }
              }
            </div>
          </div>
        </aside>

        <!-- Center Stage (52%): Core Switcher, Step Controls, Code View & Watch Bar -->
        <section class="ob-pane" aria-label="Code and disassembly viewport">
          <div class="ob-card-head">
            <div class="ob-row">
              <div class="ob-seg" role="group" aria-label="Core selector">
                @for (core of emu.activeBoardConfig().cores; track core.id; let idx = $index) {
                  <button
                    type="button"
                    class="ob-seg-btn"
                    [class.active]="emu.activeCore() === (idx === 1 ? Core.Cpu1 : Core.Cpu0)"
                    (click)="selectCore(idx)">
                    {{ core.id }} ({{ core.arch === 'Cortex-M85' ? 'M85' : 'M33' }})
                  </button>
                }
              </div>

              <div class="ob-seg" role="group" aria-label="Code view mode">
                <button type="button" class="ob-seg-btn" [class.active]="emu.codeViewMode() === 'source'"
                        (click)="setCodeMode('source')">Source</button>
                <button type="button" class="ob-seg-btn" [class.active]="emu.codeViewMode() === 'decompiled'"
                        (click)="setCodeMode('decompiled')">Decompiled C</button>
                <button type="button" class="ob-seg-btn" [class.active]="emu.codeViewMode() === 'disasm'"
                        (click)="setCodeMode('disasm')">Disasm</button>
              </div>
            </div>

            <div class="ob-row">
              <button type="button" class="ob-btn ob-btn-sm" (click)="emu.stepOver()">Over F10</button>
              <button type="button" class="ob-btn ob-btn-sm" (click)="emu.step()">Into F11</button>
              <button type="button" class="ob-btn ob-btn-sm" (click)="emu.stepOut()">Out</button>
              <button type="button" class="ob-btn ob-btn-sm" (click)="emu.reverseStep()">Reverse</button>
            </div>
          </div>

          @if (emu.codeViewMode() === 'decompiled' || !emu.isDwarfAvailable()) {
            <div class="ob-banner ob-banner-info ob-truth-bar">
              <span>
                <strong>RA8EMU-1247</strong>:
                {{ emu.isDwarfAvailable() ? 'DWARF symbols available alongside deterministic C view.' : 'Stripped ELF loaded (no DWARF lines) — displaying deterministic Thumb-2 C reconstruction.' }}
              </span>
              @if (emu.highlightedFunction()) {
                <span class="ob-pill ob-pill-accent">Focus: {{ emu.highlightedFunction() }}</span>
              }
            </div>
          }

          <div class="ob-pane-scroll">
            @switch (emu.codeViewMode()) {
              @case ('source') {
                <div class="ob-code-view">
                  @if (activeSourceLine()?.found) {
                    <div class="ob-code-line active">
                      <span class="ob-bp-dot set"></span>
                      <span class="ob-ln">{{ activeSourceLine()!.line }}</span>
                      <span>{{ activeSourceLine()!.path }}:{{ activeSourceLine()!.line }} (PC=0x{{ activeSourceLine()!.pc.toString(16) }})</span>
                    </div>
                  } @else {
                    <div class="ob-empty">
                      No DWARF line mapping at PC=0x{{ activePcHex() }}. Switch to Decompiled C or Disasm, or load an ELF built with -g.
                    </div>
                  }
                </div>
              }
              @case ('decompiled') {
                <div class="ob-stack">
                  <div class="ob-between">
                    <span class="mono"><strong>{{ activeDecompiled().functionName }}</strong> &#64; 0x{{ activeDecompiled().baseAddress.toString(16) }}</span>
                    <span class="ob-muted">{{ activeDecompiled().note }}</span>
                  </div>
                  <div class="ob-code-view">
                    @for (line of activeDecompiled().lines; track line.lineNumber) {
                      <div
                        class="ob-code-line"
                        [class.active]="line.lineNumber === activeDecompiled().activeLineNumber"
                        (click)="emu.toggleBreakpoint(line.address, emu.activeCore(), activeDecompiled().functionName)">
                        <span class="ob-bp-dot" [class.set]="hasBreakpoint(line.address)"></span>
                        <span class="ob-ln">{{ line.lineNumber }}</span>
                        <span>{{ line.code }}</span>
                      </div>
                    }
                  </div>
                </div>
              }
              @case ('disasm') {
                <app-disassembly-view />
              }
            }
          </div>

          <div class="ob-watch-bar">
            <input
              type="text"
              class="ob-input mono ob-grow"
              [(ngModel)]="watchInput"
              (keydown.enter)="addWatchSymbol()"
              placeholder="Add breakpoint symbol or watch expression (e.g. main)"
              aria-label="Breakpoint or watch expression input" />
            <button type="button" class="ob-btn ob-btn-sm" (click)="addWatchSymbol()">Pin</button>
            <button type="button" class="ob-btn ob-btn-sm" (click)="toggleDrawer()">
              {{ drawerOpen ? 'Hide Inspector' : 'Registers / Memory (Cmd+R)' }}
            </button>
          </div>
        </section>

        <!-- Right Rail (28%): CALL STACK + VIRTUAL BOARD + SCI8 SERIAL OUTPUT -->
        <aside class="ob-pane" aria-label="Call stack, virtual board, and serial output">
          <div class="ob-pane-scroll ob-stack">
            <div class="ob-card">
              <div class="ob-card-head">
                <span class="ob-section-label">CALL STACK</span>
              </div>
              <div class="ob-card-body">
                <app-call-stack />
              </div>
            </div>

            <div class="ob-card">
              <div class="ob-card-head">
                <span class="ob-section-label">VIRTUAL BOARD</span>
              </div>
              <div class="ob-card-body">
                <app-virtual-board />
              </div>
            </div>

            <div class="ob-card">
              <div class="ob-card-head">
                <span class="ob-section-label">SCI8 SERIAL OUTPUT</span>
              </div>
              <div class="ob-card-body">
                <app-uart-terminal />
              </div>
            </div>
          </div>
        </aside>
      </div>

      @if (drawerOpen) {
        <div class="ob-drawer" role="region" aria-label="Registers locals and memory inspector drawer">
          <div class="ob-between">
            <div class="ob-seg" role="tablist" aria-label="Inspector tabs">
              <button type="button" class="ob-seg-btn" [class.active]="drawerTab() === 'registers'"
                      (click)="drawerTab.set('registers')">Registers</button>
              <button type="button" class="ob-seg-btn" [class.active]="drawerTab() === 'locals'"
                      (click)="drawerTab.set('locals')">Locals</button>
              <button type="button" class="ob-seg-btn" [class.active]="drawerTab() === 'memory'"
                      (click)="drawerTab.set('memory')">Memory</button>
            </div>
            <button type="button" class="ob-btn ob-btn-sm ob-btn-ghost" (click)="toggleDrawer()">Close</button>
          </div>

          @switch (drawerTab()) {
            @case ('registers') { <app-register-inspector /> }
            @case ('locals') { <app-locals-watch /> }
            @case ('memory') { <app-memory-inspector /> }
          }
        </div>
      }
    </div>
  `,
  styles: [
    `:host { display: block; height: 100%; font-size: 12px; }
     .ob-debug-wrap { display: flex; flex-direction: column; height: 100%; min-height: 0; }
     .ob-grow-pane { flex: 1; min-height: 0; }
     .ob-muted { color: var(--text-secondary); font-size: 12px; }
     .ob-truth-bar { border-radius: 0; border-left: 0; border-right: 0; }
     .ob-watch-bar { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--border-hairline); background: var(--bg-panel); }`,
  ],
})
export class DebugTabComponent {
  public readonly emu = inject(EmulatorService);
  protected readonly Core = Core;

  @Input() public drawerOpen = false;
  @Output() public readonly drawerOpenChange = new EventEmitter<boolean>();

  public readonly drawerTab = signal<DebugDrawerTab>('registers');
  public watchInput = '';

  public readonly activeDecompiled = computed(() =>
    this.emu.activeCore() === Core.Cpu1 ? this.emu.decompiledCpu1() : this.emu.decompiledCpu0()
  );

  public readonly activeSourceLine = computed(() =>
    this.emu.activeCore() === Core.Cpu1 ? this.emu.cpu1SourceLine() : this.emu.cpu0SourceLine()
  );

  public activePcHex(): string {
    const pc = this.emu.activeCore() === Core.Cpu1 ? this.emu.cpu1Pc() : this.emu.cpu0Pc();
    return (pc >>> 0).toString(16).padStart(8, '0');
  }

  public selectCore(index: number): void {
    this.emu.activeCore.set(index === 1 ? Core.Cpu1 : Core.Cpu0);
  }

  public setCodeMode(mode: CodeViewMode): void {
    this.emu.setCodeViewMode(mode);
  }

  public hasBreakpoint(address: number): boolean {
    const map = this.emu.activeCore() === Core.Cpu1 ? this.emu.cpu1Breakpoints() : this.emu.cpu0Breakpoints();
    return map.has(address >>> 0);
  }

  public async addWatchSymbol(): Promise<void> {
    const sym = this.watchInput.trim();
    if (!sym) return;
    await this.emu.addNamedBreakpoint(sym, this.emu.activeCore());
    this.watchInput = '';
  }

  public toggleDrawer(): void {
    this.drawerOpenChange.emit(!this.drawerOpen);
  }
}
