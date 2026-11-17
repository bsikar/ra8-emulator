import { stepVimEngine } from '../../../src/app/core/vim/vim-engine';
import {
  type VimBufferState,
  type VimKeyInput,
  type VimKeyResult,
  createVimBufferState,
} from '../../../src/app/core/vim/vim-types';

function sendKeys(initial: VimBufferState, keys: Array<string | VimKeyInput>): VimKeyResult {
  let last: VimKeyResult = { handled: false, state: initial, actions: [{ type: 'none' }], selection: null };
  let cur = initial;
  for (const item of keys) {
    const input: VimKeyInput = typeof item === 'string' ? { key: item } : item;
    last = stepVimEngine(cur, input);
    cur = last.state;
  }
  return last;
}

describe('vim-engine', () => {
  it('supports numeric counts, motions, half-page scroll, and marks', () => {
    const initial = createVimBufferState({
      lines: ['line 1', 'line 2', 'line 3', '  indented word', 'line 5', 'line 6'],
      viewportHeight: 4,
      readOnly: true,
    });

    const moved = sendKeys(initial, ['l', 'l', 'l', '3', 'j']);
    expect(moved.state.cursor).toEqual({ line: 3, col: 3 });

    const jumped = sendKeys(moved.state, ['5', 'G']);
    expect(jumped.state.cursor).toEqual({ line: 4, col: 0 });

    const top = sendKeys(jumped.state, ['g', 'g']);
    expect(top.state.cursor).toEqual({ line: 0, col: 0 });

    const marked = sendKeys(top.state, ['3', 'j', 'w', 'm', 'a', 'g', 'g', "'", 'a']);
    expect(marked.state.cursor).toEqual({ line: 3, col: 2 });

    const halfDown = sendKeys(top.state, [{ key: 'd', ctrlKey: true }]);
    expect(halfDown.state.cursor.line).toBe(2);
    const halfUp = sendKeys(halfDown.state, [{ key: 'u', ctrlKey: true }]);
    expect(halfUp.state.cursor.line).toBe(0);
  });

  it('supports forward/backward search (/ ? n N), visual modes, and Escape', () => {
    const initial = createVimBufferState({
      lines: ['alpha one', 'beta target', 'gamma target', 'delta'],
      readOnly: true,
    });

    const search = sendKeys(initial, ['/', 't', 'a', 'r', 'g', 'e', 't', 'Enter']);
    expect(search.state.cursor).toEqual({ line: 1, col: 5 });

    const nextMatch = sendKeys(search.state, ['n']);
    expect(nextMatch.state.cursor).toEqual({ line: 2, col: 6 });

    const prevMatch = sendKeys(nextMatch.state, ['N']);
    expect(prevMatch.state.cursor).toEqual({ line: 1, col: 5 });

    const vis = sendKeys(prevMatch.state, ['V', 'j']);
    expect(vis.state.mode).toBe('visual-line');
    expect(vis.selection).toEqual({ start: { line: 1, col: 0 }, end: { line: 2, col: 11 }, linewise: true });

    const esc = sendKeys(vis.state, ['Escape']);
    expect(esc.state.mode).toBe('normal');
    expect(esc.selection).toBeNull();
  });

  it('enforces readOnly guard vs editable i/a/A/I/o/O/x/dd/yy/p and :ex execution', () => {
    const ro = createVimBufferState({ lines: ['alpha', 'beta'], readOnly: true });
    for (const key of ['i', 'a', 'A', 'I', 'o', 'O', 'x', 'p']) {
      const res = stepVimEngine(ro, { key });
      expect(res.state.mode).toBe('normal');
      expect(res.state.lines).toEqual(['alpha', 'beta']);
    }

    const rw = createVimBufferState({ lines: ['  alpha', 'beta'] });
    const edited = sendKeys(rw, ['I', '>', 'Escape', 'o', 'n', 'e', 'w', 'Escape', 'x']);
    expect(edited.state.lines).toEqual(['  >alpha', 'ne', 'beta']);

    const appendOps = sendKeys(edited.state, ['g', 'g', 'a', '*', 'Escape', 'A', '!', 'Escape', 'O', 't', 'o', 'p', 'Escape']);
    expect(appendOps.state.lines).toEqual(['top', '  >*alpha!', 'ne', 'beta']);

    const ddPaste = sendKeys(edited.state, ['g', 'g', 'y', 'y', 'j', 'd', 'd', 'p']);
    expect(ddPaste.state.lines).toEqual(['  >alpha', 'beta', 'ne']);

    const ex = sendKeys(ddPaste.state, [':', 'e', ' ', ...'main.c'.split(''), 'Enter']);
    expect(ex.state.mode).toBe('normal');
    expect(ex.actions).toContainEqual({
      type: 'ex-execute',
      command: { kind: 'edit', file: 'main.c' },
      raw: 'e main.c',
    });
  });

  it('passes through modifier-only keys and Alt/Meta chords unhandled', () => {
    const state = createVimBufferState({ lines: ['one'] });
    expect(stepVimEngine(state, { key: 'Shift' }).handled).toBe(false);
    expect(stepVimEngine(state, { key: 'k', metaKey: true }).handled).toBe(false);
    expect(stepVimEngine(state, { key: 'Tab', altKey: true }).handled).toBe(false);
  });
});
