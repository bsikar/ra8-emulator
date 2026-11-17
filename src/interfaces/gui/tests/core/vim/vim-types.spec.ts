import { createVimBufferState, parseExCommand } from '../../../src/app/core/vim/vim-types';

describe('vim-types', () => {
  it('creates initialized buffer state with clamped cursor and non-empty lines', () => {
    const empty = createVimBufferState({ lines: [] });
    expect(empty.lines).toEqual(['']);
    expect(empty.cursor).toEqual({ line: 0, col: 0 });
    expect(empty.mode).toBe('normal');

    const clamped = createVimBufferState({
      lines: ['abc', 'xy'],
      cursor: { line: 9, col: 99 },
      readOnly: true,
    });
    expect(clamped.cursor).toEqual({ line: 1, col: 1 });
    expect(clamped.readOnly).toBe(true);
  });

  it('parses standard :ex commands, addresses, line numbers, and custom commands', () => {
    expect(parseExCommand('   ')).toBeNull();
    expect(parseExCommand(':w')).toEqual({ kind: 'write', force: false });
    expect(parseExCommand(':q!')).toEqual({ kind: 'quit', force: true });
    expect(parseExCommand(':wq')).toEqual({ kind: 'write-quit' });
    expect(parseExCommand(':e src/main.c')).toEqual({ kind: 'edit', file: 'src/main.c' });
    expect(parseExCommand(':42')).toEqual({ kind: 'goto-line', line: 42 });
    expect(parseExCommand(':0x2000_0100')).toEqual({ kind: 'goto-address', address: 0x2000_0100 });
    expect(parseExCommand(':vim on')).toEqual({ kind: 'vim-toggle', enabled: true });
    expect(parseExCommand(':vim off')).toEqual({ kind: 'vim-toggle', enabled: false });
    expect(parseExCommand(':ext')).toEqual({ kind: 'extensions' });
    expect(parseExCommand(':help search')).toEqual({ kind: 'help', topic: 'search' });
    expect(parseExCommand(':connect ws://127.0.0.1:4567')).toEqual({
      kind: 'connect',
      url: 'ws://127.0.0.1:4567',
    });
    expect(parseExCommand(':set number')).toEqual({
      kind: 'custom',
      raw: 'set number',
      name: 'set',
      args: ['number'],
    });
  });
});
