import {
  applyPaste,
  deleteBufferLines,
  enterInsertAt,
  handleInsertModeKey,
  yankBufferLines,
} from '../../../src/app/core/vim/vim-edits';
import { createVimBufferState } from '../../../src/app/core/vim/vim-types';

describe('vim-edits', () => {
  it('blocks buffer mutations in readOnly mode while permitting line yanks', () => {
    const ro = createVimBufferState({ lines: ['first', 'second'], readOnly: true });
    const ins = enterInsertAt(ro, { line: 0, col: 0 });
    expect(ins.state.mode).toBe('normal');
    expect(ins.actions[0]).toEqual({ type: 'message', text: 'Buffer is read-only', tone: 'fault' });

    const del = deleteBufferLines(ro, 0, 1);
    expect(del.state.lines).toEqual(['first', 'second']);
    expect(del.actions[0]).toEqual({ type: 'message', text: 'Buffer is read-only', tone: 'fault' });

    const yanked = yankBufferLines(ro, 0, 1);
    expect(yanked.state.yankRegister).toEqual({ text: 'first', linewise: true });
    const pasted = applyPaste(yanked.state, 1);
    expect(pasted.state.lines).toEqual(['first', 'second']);
  });

  it('handles insert typing, enter, backspace merge, delete, yank, and paste', () => {
    let state = createVimBufferState({ lines: ['hi', 'there'] });
    state = enterInsertAt(state, { line: 0, col: 2 }).state;
    state = handleInsertModeKey(state, { key: '!' }, false).state;
    state = handleInsertModeKey(state, { key: 'Enter' }, false).state;
    state = handleInsertModeKey(state, { key: 'Tab' }, false).state;
    expect(state.lines).toEqual(['hi!', '  ', 'there']);

    state = handleInsertModeKey(state, { key: 'Backspace' }, false).state;
    state = handleInsertModeKey(state, { key: 'Backspace' }, false).state;
    state = handleInsertModeKey(state, { key: 'Backspace' }, false).state;
    expect(state.lines).toEqual(['hi!', 'there']);

    state = handleInsertModeKey(state, { key: 'Escape' }, true).state;
    expect(state.mode).toBe('normal');

    const yanked = yankBufferLines(state, 0, 1).state;
    const pasted = applyPaste(yanked, 1).state;
    expect(pasted.lines).toEqual(['hi!', 'hi!', 'there']);

    const deleted = deleteBufferLines(pasted, 1, 1).state;
    expect(deleted.lines).toEqual(['hi!', 'there']);
  });
});
