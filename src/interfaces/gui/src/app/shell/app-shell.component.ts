import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  OnInit,
  computed,
  effect,
  inject,
  signal,
} from '@angular/core';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { CAP_ARTIFACTS, Core } from 'ra8-rpc-client';
import { filter } from 'rxjs/operators';
import { RpcConnectionStore } from '../core/rpc/rpc-connection.store';
import { BoardStore } from '../core/stores/board.store';
import { ExecutionStore } from '../core/stores/execution.store';
import { RewindStore } from '../core/stores/rewind.store';
import { WorkspaceStore } from '../core/stores/workspace.store';
import { SectionKickerComponent } from '../shared/ui/section-kicker.component';
import { StatusDotComponent } from '../shared/ui/status-dot.component';
import { TonalButtonComponent } from '../shared/ui/tonal-button.component';
import { CommandModeStore, formatShortcut } from './command-mode.store';
import { CommandPaletteComponent } from './command-palette.component';
import { DropVeilComponent } from './drop-veil.component';
import { ToastRegionComponent } from './toast-region.component';

interface NavRouteItem {
  path: string;
  label: string;
}

@Component({
  selector: 'app-shell',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [
    RouterOutlet,
    RouterLink,
    RouterLinkActive,
    CommandPaletteComponent,
    DropVeilComponent,
    ToastRegionComponent,
    StatusDotComponent,
    SectionKickerComponent,
    TonalButtonComponent,
  ],
  templateUrl: './app-shell.component.html',
  styleUrl: './app-shell.component.css',
})
export class AppShellComponent implements OnInit {
  protected readonly rpc = inject(RpcConnectionStore);
  protected readonly execution = inject(ExecutionStore);
  protected readonly board = inject(BoardStore);
  protected readonly rewind = inject(RewindStore);
  protected readonly workspace = inject(WorkspaceStore);
  protected readonly cmdMode = inject(CommandModeStore);
  private readonly router = inject(Router);

  protected readonly dragActive = signal<boolean>(false);
  protected readonly commandChordLabel = formatShortcut({ mod: true, key: 'k' });
  protected readonly viewLinks: readonly NavRouteItem[] = [
    { path: '/launch', label: 'Launch' },
    { path: '/debug', label: 'Debug' },
    { path: '/hardware', label: 'Hardware' },
    { path: '/rewind', label: 'Rewind' },
    { path: '/profile', label: 'Profile' },
    { path: '/console', label: 'Console' },
  ];

  protected readonly coreSummary = computed(() =>
    this.execution.cpu1Attached() ? 'CPU0 · CPU1' : 'CPU0'
  );

  protected readonly statusTone = computed(() => {
    if (this.rpc.isConnected()) return 'nominal' as const;
    if (this.rpc.errorMessage()) return 'fault' as const;
    return 'muted' as const;
  });

  constructor() {
    effect(() => {
      this.cmdMode.updateContext({
        connected: this.rpc.isConnected(),
        running: this.execution.isRunning(),
        historySupported: this.rewind.historySupported(),
        workspaceSupported: this.workspace.hasWorkspaceCap(),
        artifactsSupported: this.rpc.hasCapability(CAP_ARTIFACTS),
      });
    });

    this.router.events
      .pipe(filter((evt): evt is NavigationEnd => evt instanceof NavigationEnd))
      .subscribe((evt) => this.cmdMode.updateContext({ activePath: evt.urlAfterRedirects }));
  }

  public ngOnInit(): void {
    this.registerCommands();
  }

  @HostListener('window:keydown', ['$event'])
  protected onWindowKeyDown(event: KeyboardEvent): void {
    this.cmdMode.handleKeyDown(event);
  }

  protected onDragOver(event: DragEvent): void {
    event.preventDefault();
    this.dragActive.set(true);
  }

  protected onDragLeave(event: DragEvent): void {
    if (event.currentTarget === event.target) {
      this.dragActive.set(false);
    }
  }

  protected async onDrop(event: DragEvent): Promise<void> {
    event.preventDefault();
    this.dragActive.set(false);
    const file = event.dataTransfer?.files?.[0];
    if (!file) return;
    const lower = file.name.toLowerCase();
    if (lower.endsWith('.board')) {
      this.board.importBoardProfileText(file.name, await file.text());
      return;
    }
    if (lower.endsWith('.tar') || lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      const preview = await this.rewind.previewStagedArchive(new Uint8Array(await file.arrayBuffer()));
      if (preview) {
        this.rpc.pushToast(`Staged archive ${file.name} (${preview.entries.length} entries)`);
        await this.router.navigateByUrl('/rewind');
      }
      return;
    }
    const ok = await this.board.loadElfFile(file.name, new Uint8Array(await file.arrayBuffer()), Core.Cpu0);
    if (ok) await this.router.navigateByUrl('/debug');
  }

  protected toggleRunPause(): void {
    if (this.execution.isRunning()) {
      void this.execution.pause();
    } else {
      void this.execution.run();
    }
  }

  private registerCommands(): void {
    this.cmdMode.registerActions([
      { id: 'nav-launch', label: 'Go to Launch', category: 'navigation', menu: 'view', shortcut: { key: '1' }, run: () => this.router.navigateByUrl('/launch') },
      { id: 'nav-debug', label: 'Go to Debug', category: 'navigation', menu: 'view', shortcut: { key: '2' }, run: () => this.router.navigateByUrl('/debug') },
      { id: 'nav-hw', label: 'Go to Hardware', category: 'navigation', menu: 'view', shortcut: { key: '3' }, run: () => this.router.navigateByUrl('/hardware') },
      { id: 'nav-rewind', label: 'Go to Rewind', category: 'navigation', menu: 'view', shortcut: { key: '4' }, run: () => this.router.navigateByUrl('/rewind') },
      { id: 'nav-profile', label: 'Go to Profile', category: 'navigation', menu: 'view', shortcut: { key: '5' }, run: () => this.router.navigateByUrl('/profile') },
      { id: 'nav-console', label: 'Go to Console', category: 'navigation', menu: 'terminal', shortcut: { key: '6' }, run: () => this.router.navigateByUrl('/console') },
      { id: 'exec-run', label: 'Continue / Pause', category: 'execution', menu: 'file', shortcut: { key: 'F5' }, isEnabled: (c) => c.connected, run: () => this.toggleRunPause() },
      { id: 'exec-over', label: 'Step Over', category: 'execution', menu: 'edit', shortcut: { key: 'F10' }, isEnabled: (c) => c.connected && !c.running, run: () => this.execution.stepOver() },
      { id: 'exec-into', label: 'Step Into', category: 'execution', menu: 'edit', shortcut: { key: 'F11' }, isEnabled: (c) => c.connected && !c.running, run: () => this.execution.step() },
      { id: 'open-settings', label: 'Session Settings', category: 'session', menu: 'file', shortcut: { mod: true, key: ',' }, run: () => this.cmdMode.settingsOpen.set(true) },
      { id: 'open-help', label: 'Keyboard & Transport Help', category: 'help', menu: 'help', run: () => this.cmdMode.helpOpen.set(true) },
      { id: 'disconnect', label: 'Disconnect Session', category: 'session', menu: 'file', isEnabled: (c) => c.connected, run: () => this.rpc.disconnect(true) },
    ]);
  }
}
