/**
 * Pure immutable buffer editing helpers (insert mode typing, delete, yank, paste,
 * and read-only guard enforcement) for the Vim engine.
 */

import { clampCursor, computeVisualSelection, moveFirstNonBlank } from './vim-motions';
import type { VimAction, VimBufferState, VimCursor, VimKeyInput, VimKeyResult } from './vim-types';

/** Builds a standardized `VimKeyResult` with computed visual selection. */
export function buildVimResult(handled: boolean, state: VimBufferState, actions: VimAction[]): VimKeyResult {
  return {
    handled,
    state,
    actions,
    selection: computeVisualSelection(state.mode, state.visualAnchor, state.cursor, state.lines),
  };
}

/** Rejects mutating commands cleanly when the buffer is `readOnly`. */
export function readOnlyError(state: VimBufferState): VimKeyResult {
  const next: VimBufferState = { ...state, countBuffer: '', pendingOperator: '' };
  return buildVimResult(true, next, [{ type: 'message', text: 'Buffer is read-only', tone: 'fault' }]);
}

/** Commits updated lines and cursor while marking the buffer dirty. */
export function commitBufferEdit(
  state: VimBufferState,
  lines: string[],
  cursor: VimCursor,
  allowEnd: boolean,
  extraActions: VimAction[] = []
): VimKeyResult {
  const safeLines = lines.length > 0 ? lines : [''];
  const clamped = clampCursor(safeLines, cursor, allowEnd);
  const next: VimBufferState = {
    ...state,
    lines: safeLines,
    cursor: clamped,
    dirty: true,
    countBuffer: '',
    pendingOperator: '',
  };
  return buildVimResult(true, next, [{ type: 'buffer-changed', lines: safeLines, cursor: clamped }, ...extraActions]);
}

/** Handles all keystrokes while inside `'insert'` mode. */
export function handleInsertModeKey(state: VimBufferState, input: VimKeyInput, isEscape: boolean): VimKeyResult {
  if (isEscape) {
    const targetCol = Math.max(0, state.cursor.col - 1);
    const cursor = clampCursor(state.lines, { line: state.cursor.line, col: targetCol }, false);
    const next: VimBufferState = { ...state, mode: 'normal', cursor, countBuffer: '', pendingOperator: '' };
    return buildVimResult(true, next, [{ type: 'mode-changed', mode: 'normal' }]);
  }
  if (state.readOnly) return readOnlyError(state);
  if (input.ctrlKey || input.altKey || input.metaKey) return buildVimResult(false, state, [{ type: 'none' }]);

  const lines = [...state.lines];
  const lineIdx = state.cursor.line;
  const col = state.cursor.col;
  const current = lines[lineIdx] ?? '';

  if (input.key === 'Enter') {
    lines.splice(lineIdx, 1, current.slice(0, col), current.slice(col));
    return commitBufferEdit(state, lines, { line: lineIdx + 1, col: 0 }, true);
  }
  if (input.key === 'Backspace') {
    if (col > 0) {
      lines[lineIdx] = current.slice(0, col - 1) + current.slice(col);
      return commitBufferEdit(state, lines, { line: lineIdx, col: col - 1 }, true);
    }
    if (lineIdx > 0) {
      const prev = lines[lineIdx - 1] ?? '';
      lines.splice(lineIdx - 1, 2, prev + current);
      return commitBufferEdit(state, lines, { line: lineIdx - 1, col: prev.length }, true);
    }
    return buildVimResult(true, state, [{ type: 'none' }]);
  }
  const inserted = input.key === 'Tab' ? '  ' : input.key.length === 1 ? input.key : null;
  if (inserted === null) return buildVimResult(false, state, [{ type: 'none' }]);

  lines[lineIdx] = current.slice(0, col) + inserted + current.slice(col);
  return commitBufferEdit(state, lines, { line: lineIdx, col: col + inserted.length }, true);
}

/** Deletes `count` lines starting at `startLine`, storing them in `yankRegister`. */
export function deleteBufferLines(state: VimBufferState, startLine: number, count: number): VimKeyResult {
  if (state.readOnly) return readOnlyError(state);
  const lines = [...state.lines];
  const deleteCount = Math.min(lines.length - startLine, Math.max(1, count));
  const removed = lines.splice(startLine, deleteCount);
  const safeLines = lines.length > 0 ? lines : [''];
  const nextLine = Math.min(startLine, safeLines.length - 1);
  const cursor = moveFirstNonBlank(safeLines, { line: nextLine, col: 0 });
  const nextState: VimBufferState = {
    ...state,
    mode: 'normal',
    visualAnchor: null,
    yankRegister: { text: removed.join('\n'), linewise: true },
  };
  return commitBufferEdit(nextState, safeLines, cursor, false);
}

/** Yanks `count` lines starting at `startLine` into `yankRegister` (allowed when read-only). */
export function yankBufferLines(state: VimBufferState, startLine: number, count: number): VimKeyResult {
  const endLine = Math.min(state.lines.length - 1, startLine + Math.max(1, count) - 1);
  const yanked = state.lines.slice(startLine, endLine + 1);
  const next: VimBufferState = {
    ...state,
    mode: 'normal',
    visualAnchor: null,
    countBuffer: '',
    pendingOperator: '',
    yankRegister: { text: yanked.join('\n'), linewise: true },
  };
  const label = yanked.length === 1 ? '1 line yanked' : `${yanked.length} lines yanked`;
  return buildVimResult(true, next, [{ type: 'message', text: label, tone: 'neutral' }]);
}

/** Pastes the active `yankRegister` contents `count` times below or after the cursor. */
export function applyPaste(state: VimBufferState, count: number): VimKeyResult {
  if (state.readOnly) return readOnlyError(state);
  if (!state.yankRegister) {
    return buildVimResult(true, { ...state, countBuffer: '' }, [{ type: 'message', text: 'Register empty', tone: 'neutral' }]);
  }
  const lines = [...state.lines];
  if (state.yankRegister.linewise) {
    const chunk = state.yankRegister.text.split('\n');
    const pastedLines = Array.from({ length: count }, () => chunk).flat();
    lines.splice(state.cursor.line + 1, 0, ...pastedLines);
    const cursor = moveFirstNonBlank(lines, { line: state.cursor.line + 1, col: 0 });
    return commitBufferEdit(state, lines, cursor, false);
  }
  const text = state.yankRegister.text.repeat(count);
  const line = lines[state.cursor.line] ?? '';
  const insertAt = Math.min(line.length, state.cursor.col + 1);
  lines[state.cursor.line] = line.slice(0, insertAt) + text + line.slice(insertAt);
  return commitBufferEdit(state, lines, { line: state.cursor.line, col: insertAt + text.length - 1 }, false);
}

/** Transitions to `'insert'` mode, optionally opening a blank line `'above'` or `'below'`. */
export function enterInsertAt(state: VimBufferState, cursor: VimCursor, insertNewLine?: 'above' | 'below'): VimKeyResult {
  if (state.readOnly) return readOnlyError(state);
  const lines = [...state.lines];
  let nextCursor = cursor;
  if (insertNewLine === 'below') {
    lines.splice(state.cursor.line + 1, 0, '');
    nextCursor = { line: state.cursor.line + 1, col: 0 };
  } else if (insertNewLine === 'above') {
    lines.splice(state.cursor.line, 0, '');
    nextCursor = { line: state.cursor.line, col: 0 };
  }
  const clamped = clampCursor(lines, nextCursor, true);
  const next: VimBufferState = {
    ...state,
    lines,
    cursor: clamped,
    mode: 'insert',
    dirty: insertNewLine ? true : state.dirty,
    countBuffer: '',
    pendingOperator: '',
    visualAnchor: null,
  };
  const actions: VimAction[] = [{ type: 'mode-changed', mode: 'insert' }];
  if (insertNewLine) actions.push({ type: 'buffer-changed', lines, cursor: clamped });
  return buildVimResult(true, next, actions);
}
