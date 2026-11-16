import { CommonModule } from '@angular/common';
import { Component, HostListener, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Core } from 'ra8-rpc-client';
import { DebugTabComponent } from './components/debug-tab/debug-tab.component';
import { HardwareTabComponent } from './components/hardware-tab/hardware-tab.component';
import { ProfileTabComponent } from './components/profile-tab/profile-tab.component';
import { RewindTabComponent } from './components/rewind-tab/rewind-tab.component';
import { WorkspaceTabComponent } from './components/workspace-tab/workspace-tab.component';
import { EmulatorService, WorkbenchTab } from './services/emulator.service';

interface WorkbenchNavItem {
  id: WorkbenchTab;
  label: string;
}

interface CommandItem {
  id: string;
  label: string;
  shortcut: string;
  run: () => void | Promise<void>;
}

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    WorkspaceTabComponent,
    DebugTabComponent,
    RewindTabComponent,
    HardwareTabComponent,
    ProfileTabComponent,
  ],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent {
  public readonly emu = inject(EmulatorService);

  public readonly tabs: readonly WorkbenchNavItem[] = [
    { id: 'workspace', label: 'Workspace' },
    { id: 'debug', label: 'Debug' },
    { id: 'rewind', label: 'Rewind' },
    { id: 'hardware', label: 'Hardware' },
    { id: 'profile', label: 'Profile' },
  ];

  public readonly activeTab = signal<WorkbenchTab>('workspace');
  public readonly debugDrawerOpen = signal<boolean>(false);
  public readonly commandPaletteOpen = signal<boolean>(false);
  public readonly commandQuery = signal<string>('');
  public readonly isDragOver = signal<boolean>(false);

  public readonly commands = computed<CommandItem[]>(() => [
    { id: 'tab-ws', label: 'Go to Workspace', shortcut: '1', run: () => this.setTab('workspace') },
    { id: 'tab-dbg', label: 'Go to Debug (IDE / DAP)', shortcut: '2', run: () => this.setTab('debug') },
    { id: 'tab-rew', label: 'Go to Rewind (Time-Travel Tree)', shortcut: '3', run: () => this.setTab('rewind') },
    { id: 'tab-hw', label: 'Go to Hardware (HIL & Bus Signals)', shortcut: '4', run: () => this.setTab('hardware') },
    { id: 'tab-prof', label: 'Go to Profile (Compute & Flamegraph)', shortcut: '5', run: () => this.setTab('profile') },
    { id: 'run', label: 'Toggle Continue / Pause', shortcut: 'F5', run: () => this.toggleRunPause() },
    { id: 'step-over', label: 'Step Over', shortcut: 'F10', run: () => this.emu.stepOver() },
    { id: 'step-into', label: 'Step Into', shortcut: 'F11', run: () => this.emu.step() },
    { id: 'drawer', label: 'Toggle Registers / Locals / Memory Drawer', shortcut: 'Cmd+R', run: () => { this.setTab('debug'); this.debugDrawerOpen.update((v) => !v); } },
    { id: 'trace', label: 'Capture Profile Trace', shortcut: 'P', run: () => { this.setTab('profile'); return this.emu.captureProfileTrace(); } },
  ]);

  public readonly filteredCommands = computed<CommandItem[]>(() => {
    const q = this.commandQuery().trim().toLowerCase();
    if (!q) return this.commands();
    return this.commands().filter((c) => c.label.toLowerCase().includes(q));
  });

  public setTab(tab: WorkbenchTab): void {
    this.activeTab.set(tab);
  }

  public async toggleRunPause(): Promise<void> {
    if (this.emu.executionStatus() === 'running') {
      await this.emu.pause();
    } else {
      await this.emu.run();
    }
  }

  public onInspectFunction(fnName: string): void {
    this.emu.highlightedFunction.set(fnName);
    this.setTab('debug');
  }

  public runCommand(cmd: CommandItem): void {
    this.commandPaletteOpen.set(false);
    this.commandQuery.set('');
    void cmd.run();
  }

  @HostListener('window:keydown', ['$event'])
  public onKeyDown(evt: KeyboardEvent): void {
    const mod = evt.metaKey || evt.ctrlKey;
    if (mod && evt.key.toLowerCase() === 'k') {
      evt.preventDefault();
      this.commandPaletteOpen.update((v) => !v);
      return;
    }
    if (mod && evt.key.toLowerCase() === 'r' && this.activeTab() === 'debug') {
      evt.preventDefault();
      this.debugDrawerOpen.update((v) => !v);
      return;
    }
    if (evt.key === 'Escape' && this.commandPaletteOpen()) {
      evt.preventDefault();
      this.commandPaletteOpen.set(false);
      return;
    }
    if (evt.key === 'F5') {
      evt.preventDefault();
      void this.toggleRunPause();
    } else if (evt.key === 'F10') {
      evt.preventDefault();
      void this.emu.stepOver();
    } else if (evt.key === 'F11') {
      evt.preventDefault();
      void this.emu.step();
    }
  }

  public onDragOver(evt: DragEvent): void {
    evt.preventDefault();
    this.isDragOver.set(true);
  }

  public onDragLeave(evt: DragEvent): void {
    if (evt.currentTarget === evt.target) {
      this.isDragOver.set(false);
    }
  }

  public async onDrop(evt: DragEvent): Promise<void> {
    evt.preventDefault();
    this.isDragOver.set(false);
    const file = evt.dataTransfer?.files?.[0];
    if (!file) return;
    const lower = file.name.toLowerCase();
    if (lower.endsWith('.board')) {
      this.emu.importBoardText(file.name, await file.text());
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      await this.emu.importTimeTravelArchive(file.name, new Uint8Array(await file.arrayBuffer()));
      this.setTab('rewind');
    } else {
      await this.emu.loadElfFile(file.name, new Uint8Array(await file.arrayBuffer()), Core.Cpu0);
      this.setTab('debug');
    }
  }
}
