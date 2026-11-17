import { CommandModeStore, formatShortcut, isEditableEventTarget } from '../../src/app/shell/command-mode.store';

describe('CommandModeStore (RA8EMU-957 / RA8EMU-967)', () => {
  it('formats platform-aware shortcuts for macOS and non-macOS', () => {
    expect(formatShortcut({ mod: true, key: 'k' }, true)).toBe('Cmd+K');
    expect(formatShortcut({ mod: true, key: 'k' }, false)).toBe('Ctrl+K');
    expect(formatShortcut({ mod: true, shift: true, key: 'p' }, false)).toBe('Ctrl+Shift+P');
    expect(formatShortcut({ key: 'F5' }, true)).toBe('F5');
  });

  it('enforces session-state enablement predicates and <input>-safe shortcut dispatch', () => {
    const store = new CommandModeStore();
    let stepCount = 0;
    store.registerActions([
      {
        id: 'step-over',
        label: 'Step Over',
        category: 'execution',
        shortcut: { key: 'F10' },
        menu: 'view',
        isEnabled: (ctx) => ctx.connected && !ctx.running,
        run: () => {
          stepCount += 1;
        },
      },
      {
        id: 'open-launch',
        label: 'Launch',
        category: 'navigation',
        menu: 'view',
        run: () => undefined,
      },
    ]);

    const f10Disconnected = new KeyboardEvent('keydown', { key: 'F10', cancelable: true });
    expect(store.handleKeyDown(f10Disconnected)).toBe(false);
    expect(stepCount).toBe(0);

    store.updateContext({ connected: true, running: false });
    const inputEl = document.createElement('input');
    expect(isEditableEventTarget(inputEl)).toBe(true);
    const f10InsideInput = new KeyboardEvent('keydown', { key: 'F10', cancelable: true });
    Object.defineProperty(f10InsideInput, 'target', { value: inputEl });
    expect(store.handleKeyDown(f10InsideInput)).toBe(false);
    expect(stepCount).toBe(0);

    const cmdKInsideInput = new KeyboardEvent('keydown', { key: 'k', ctrlKey: true, cancelable: true });
    Object.defineProperty(cmdKInsideInput, 'target', { value: inputEl });
    expect(store.handleKeyDown(cmdKInsideInput)).toBe(true);
    expect(store.paletteOpen()).toBe(true);

    const altF10 = new KeyboardEvent('keydown', { key: 'F10', altKey: true, cancelable: true });
    expect(store.handleKeyDown(altF10)).toBe(false);
    expect(stepCount).toBe(0);

    const f10Ready = new KeyboardEvent('keydown', { key: 'F10', cancelable: true });
    expect(store.handleKeyDown(f10Ready)).toBe(true);
    expect(stepCount).toBe(1);
    expect(store.paletteOpen()).toBe(false);
  });

  it('filters commands cleanly with or without leading > prefix', () => {
    const store = new CommandModeStore();
    store.registerActions([
      { id: 'a', label: 'Connect Remote', category: 'session', run: () => undefined },
      { id: 'b', label: 'Open Debug', category: 'navigation', run: () => undefined },
    ]);
    store.query.set('>debug');
    expect(store.filteredCommands().map((c) => c.action.id)).toEqual(['b']);
  });

  it('tracks and dismisses registered route modals on Escape', () => {
    const store = new CommandModeStore();
    let dismissed = false;
    store.setRouteModalDismiss(() => {
      dismissed = true;
    });
    expect(store.hasOpenOverlay()).toBe(true);
    expect(store.handleKeyDown(new KeyboardEvent('keydown', { key: 'Escape', cancelable: true }))).toBe(true);
    expect(dismissed).toBe(true);
    expect(store.hasOpenOverlay()).toBe(false);
  });
});
