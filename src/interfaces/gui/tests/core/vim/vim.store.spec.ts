import { TestBed } from '@angular/core/testing';
import { VimStore } from '../../../src/app/core/vim/vim.store';

describe('VimStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('persists enabled preference in localStorage and computes status labels', () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(VimStore);
    expect(store.enabled()).toBe(false);
    expect(store.statusLabel()).toBe('VIM: OFF');

    store.setEnabled(true);
    expect(localStorage.getItem('ra8.vim.enabled.v1')).toBe('true');
    expect(store.statusLabel()).toBe('VIM: NORMAL');

    TestBed.resetTestingModule();
    TestBed.configureTestingModule({});
    const reloaded = TestBed.inject(VimStore);
    expect(reloaded.enabled()).toBe(true);
  });

  it('tracks pendingKeys, commandBuffer, and executes built-in + custom :ex handlers', async () => {
    TestBed.configureTestingModule({});
    const store = TestBed.inject(VimStore);
    store.bindBuffer({ lines: ['row 1', 'row 2', 'row 3'], readOnly: true });

    expect(store.handleKeyDown({ key: 'j' }).handled).toBe(false);

    const calls: string[] = [];
    const unsubEdit = store.registerExHandler('edit', (cmd) => {
      if (cmd.kind === 'edit') calls.push(`edit:${cmd.file}`);
    });
    store.registerExHandler('goto-address', (cmd) => {
      if (cmd.kind === 'goto-address') calls.push(`addr:${cmd.address}`);
    });

    expect(await store.executeExCommand(':vim on')).toBe(true);
    expect(store.enabled()).toBe(true);

    store.handleKeyDown({ key: '3' });
    store.handleKeyDown({ key: 'g' });
    expect(store.pendingKeys()).toBe('3g');
    store.handleKeyDown({ key: 'g' });
    expect(store.cursor().line).toBe(2);

    store.handleKeyDown({ key: ':' });
    expect(store.mode()).toBe('command');
    for (const ch of ['e', ' ', 'a', '.', 'c']) store.handleKeyDown({ key: ch });
    expect(store.commandBuffer()).toBe('e a.c');
    expect(store.statusLabel()).toBe('VIM: :e a.c');
    store.handleKeyDown({ key: 'Enter' });

    await Promise.resolve();
    expect(calls).toEqual(['edit:a.c']);

    expect(await store.executeExCommand(':0x20000100')).toBe(true);
    expect(calls).toEqual(['edit:a.c', `addr:${0x2000_0100}`]);

    unsubEdit();
    expect(await store.executeExCommand(':e b.c')).toBe(false);
    expect(store.lastMessage()).toContain('Not an editor command');
  });
});
