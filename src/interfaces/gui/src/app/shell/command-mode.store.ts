import { Injectable, computed, signal } from '@angular/core';

export type TopMenuId = 'file' | 'edit' | 'view' | 'terminal' | 'help';
export type CommandCategory = 'navigation' | 'session' | 'execution' | 'file' | 'extensions' | 'help';

export interface ShortcutChord {
  mod?: boolean;
  shift?: boolean;
  key: string;
}

export interface CommandContext {
  connected: boolean;
  running: boolean;
  canReload: boolean;
  historySupported: boolean;
  workspaceSupported: boolean;
  artifactsSupported: boolean;
  activePath: string;
}

export interface CommandAction {
  id: string;
  label: string;
  category: CommandCategory;
  shortcut?: ShortcutChord;
  menu?: TopMenuId;
  isEnabled?: (ctx: CommandContext) => boolean;
  run: () => unknown;
}

export interface ResolvedCommand {
  action: CommandAction;
  enabled: boolean;
  shortcutLabel: string;
}

export interface MenuEntry {
  id: TopMenuId;
  label: string;
  items: ResolvedCommand[];
}

export function isMacPlatform(nav?: { platform?: string; userAgent?: string }): boolean {
  const target = nav ?? (typeof navigator !== 'undefined' ? navigator : undefined);
  if (!target) return false;
  const sig = `${target.platform ?? ''} ${target.userAgent ?? ''}`;
  return /mac|iphone|ipad/i.test(sig);
}

export function formatShortcut(chord: ShortcutChord | undefined, mac = isMacPlatform()): string {
  if (!chord) return '';
  const parts: string[] = [];
  if (chord.mod) parts.push(mac ? 'Cmd' : 'Ctrl');
  if (chord.shift) parts.push('Shift');
  parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key);
  return parts.join('+');
}

export function isEditableEventTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  return target.isContentEditable;
}

const DEFAULT_CTX: CommandContext = {
  connected: false,
  running: false,
  canReload: false,
  historySupported: false,
  workspaceSupported: false,
  artifactsSupported: false,
  activePath: '/launch',
};

@Injectable({ providedIn: 'root' })
export class CommandModeStore {
  public readonly paletteOpen = signal<boolean>(false);
  public readonly query = signal<string>('');
  public readonly activeMenu = signal<TopMenuId | null>(null);
  public readonly settingsOpen = signal<boolean>(false);
  public readonly helpOpen = signal<boolean>(false);
  public readonly extensionsOpen = signal<boolean>(false);
  public readonly context = signal<CommandContext>(DEFAULT_CTX);
  private readonly actions = signal<CommandAction[]>([]);
  private readonly macMode = signal<boolean>(isMacPlatform());
  private readonly routeModalDismiss = signal<(() => void) | null>(null);

  public readonly routeModalOpen = computed<boolean>(() => this.routeModalDismiss() !== null);
  public readonly hasOpenOverlay = computed<boolean>(
    () =>
      this.paletteOpen() ||
      this.settingsOpen() ||
      this.helpOpen() ||
      this.extensionsOpen() ||
      this.routeModalOpen()
  );

  public readonly resolvedCommands = computed<ResolvedCommand[]>(() => {
    const ctx = this.context();
    const mac = this.macMode();
    return this.actions().map((action) => ({
      action,
      enabled: action.isEnabled ? action.isEnabled(ctx) : true,
      shortcutLabel: formatShortcut(action.shortcut, mac),
    }));
  });

  public readonly filteredCommands = computed<ResolvedCommand[]>(() => {
    const raw = this.query().trim().replace(/^>/, '').trim().toLowerCase();
    const list = this.resolvedCommands();
    if (!raw) return list;
    return list.filter(
      (item) =>
        item.action.label.toLowerCase().includes(raw) ||
        item.action.category.toLowerCase().includes(raw) ||
        item.shortcutLabel.toLowerCase().includes(raw)
    );
  });

  public readonly menus = computed<MenuEntry[]>(() => {
    const list = this.resolvedCommands();
    const defs: Array<{ id: TopMenuId; label: string }> = [
      { id: 'file', label: 'File' },
      { id: 'edit', label: 'Edit' },
      { id: 'view', label: 'View' },
      { id: 'terminal', label: 'Terminal' },
      { id: 'help', label: 'Help' },
    ];
    return defs.map((def) => ({
      id: def.id,
      label: def.label,
      items: list.filter((item) => item.action.menu === def.id),
    }));
  });

  public setPlatformForTest(isMac: boolean): void {
    this.macMode.set(isMac);
  }

  public registerActions(next: readonly CommandAction[]): void {
    this.actions.set([...next]);
  }

  public updateContext(patch: Partial<CommandContext>): void {
    this.context.update((prev) => ({ ...prev, ...patch }));
  }

  public setRouteModalDismiss(dismiss: (() => void) | null): void {
    this.routeModalDismiss.set(dismiss);
  }

  public openPalette(initialQuery = ''): void {
    this.activeMenu.set(null);
    this.extensionsOpen.set(false);
    this.query.set(initialQuery);
    this.paletteOpen.set(true);
  }

  public closeOverlays(): void {
    this.paletteOpen.set(false);
    this.activeMenu.set(null);
    this.settingsOpen.set(false);
    this.helpOpen.set(false);
    this.extensionsOpen.set(false);
    const dismiss = this.routeModalDismiss();
    if (dismiss) {
      this.routeModalDismiss.set(null);
      dismiss();
    }
  }

  public toggleMenu(id: TopMenuId): void {
    this.activeMenu.update((cur) => (cur === id ? null : id));
  }

  public execute(cmd: ResolvedCommand): boolean {
    if (!cmd.enabled) return false;
    this.paletteOpen.set(false);
    this.activeMenu.set(null);
    this.query.set('');
    void cmd.action.run();
    return true;
  }

  public handleKeyDown(event: KeyboardEvent): boolean {
    const mod = event.metaKey || event.ctrlKey;
    const keyLower = event.key.toLowerCase();

    if (mod && keyLower === 'k') {
      event.preventDefault();
      if (this.paletteOpen()) {
        this.paletteOpen.set(false);
      } else {
        this.openPalette();
      }
      return true;
    }

    if (event.key === 'Escape' && (this.hasOpenOverlay() || this.activeMenu() !== null)) {
      event.preventDefault();
      this.closeOverlays();
      return true;
    }

    if (!mod && isEditableEventTarget(event.target)) {
      return false;
    }

    if (event.altKey) return false;

    const match = this.resolvedCommands().find((cmd) => {
      const s = cmd.action.shortcut;
      if (!s) return false;
      return Boolean(s.mod) === mod && Boolean(s.shift) === event.shiftKey && s.key.toLowerCase() === keyLower;
    });

    if (!match) return false;
    event.preventDefault();
    return this.execute(match);
  }
}
