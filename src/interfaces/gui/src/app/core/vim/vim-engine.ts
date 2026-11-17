/**
 * Pure Vim modal state machine processing key events across `'normal'`, `'insert'`,
 * `'visual'`, `'visual-line'`, and `'command'` (`:ex`) modes.
 */

import {
  applyPaste,
  buildVimResult,
  commitBufferEdit,
  deleteBufferLines,
  enterInsertAt,
  handleInsertModeKey,
  readOnlyError,
  yankBufferLines,
} from './vim-edits';
import {
  clampCursor,
  computeVisualSelection,
  findPatternMatch,
  moveFirstNonBlank,
  moveHalfPage,
  moveHorizontal,
  moveLineEnd,
  moveLineStart,
  moveToLine,
  moveVertical,
  moveWordBackward,
  moveWordEnd,
  moveWordForward,
} from './vim-motions';
import {
  type VimAction,
  type VimBufferState,
  type VimCursor,
  type VimKeyInput,
  type VimKeyResult,
  type VimMode,
  type VimSearchDirection,
  parseExCommand,
} from './vim-types';

const MODIFIER_ONLY_KEYS = new Set(['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'OS']);

function parseCount(countBuffer: string): { hasExplicit: boolean; count: number } {
  if (!countBuffer) return { hasExplicit: false, count: 1 };
  const parsed = Number.parseInt(countBuffer, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return { hasExplicit: false, count: 1 };
  return { hasExplicit: true, count: Math.min(10_000, parsed) };
}

function isEscapeKey(input: VimKeyInput): boolean {
  return input.key === 'Escape' || (Boolean(input.ctrlKey) && input.key === '[');
}

function moveState(state: VimBufferState, cursor: VimCursor, extraActions: VimAction[] = []): VimKeyResult {
  const clamped = clampCursor(state.lines, cursor, state.mode === 'insert');
  const next: VimBufferState = { ...state, cursor: clamped, countBuffer: '', pendingOperator: '' };
  return buildVimResult(true, next, [{ type: 'moved', cursor: clamped }, ...extraActions]);
}

function handleCommandKey(state: VimBufferState, input: VimKeyInput): VimKeyResult {
  if (isEscapeKey(input)) {
    const next: VimBufferState = { ...state, mode: 'normal', commandBuffer: '', countBuffer: '', pendingOperator: '' };
    return buildVimResult(true, next, [{ type: 'mode-changed', mode: 'normal' }]);
  }
  if (input.key === 'Backspace') {
    if (state.commandBuffer.length === 0) {
      const next: VimBufferState = { ...state, mode: 'normal', commandBuffer: '' };
      return buildVimResult(true, next, [{ type: 'mode-changed', mode: 'normal' }]);
    }
    return buildVimResult(true, { ...state, commandBuffer: state.commandBuffer.slice(0, -1) }, [{ type: 'none' }]);
  }
  if (input.key === 'Enter') {
    const raw = state.commandBuffer.trim();
    const parsed = parseExCommand(raw);
    const next: VimBufferState = { ...state, mode: 'normal', commandBuffer: '', countBuffer: '', pendingOperator: '' };
    const actions: VimAction[] = [{ type: 'mode-changed', mode: 'normal' }];
    if (parsed) actions.push({ type: 'ex-execute', command: parsed, raw });
    return buildVimResult(true, next, actions);
  }
  if (!input.ctrlKey && !input.altKey && !input.metaKey && input.key.length === 1) {
    return buildVimResult(true, { ...state, commandBuffer: state.commandBuffer + input.key }, [{ type: 'none' }]);
  }
  return buildVimResult(true, state, [{ type: 'none' }]);
}

function handleSearchPromptKey(state: VimBufferState, input: VimKeyInput): VimKeyResult {
  if (isEscapeKey(input)) {
    const next: VimBufferState = { ...state, searchPromptActive: false, searchBuffer: '' };
    return buildVimResult(true, next, [{ type: 'message', text: 'Search cancelled', tone: 'neutral' }]);
  }
  if (input.key === 'Backspace') {
    if (state.searchBuffer.length === 0) {
      return buildVimResult(true, { ...state, searchPromptActive: false, searchBuffer: '' }, [{ type: 'none' }]);
    }
    return buildVimResult(true, { ...state, searchBuffer: state.searchBuffer.slice(0, -1) }, [{ type: 'none' }]);
  }
  if (input.key === 'Enter') {
    const pattern = state.searchBuffer;
    const match = findPatternMatch(state.lines, state.cursor, pattern, state.searchDirection, true);
    const cursor = match ?? state.cursor;
    const next: VimBufferState = {
      ...state,
      searchPromptActive: false,
      searchBuffer: '',
      lastSearchPattern: pattern,
      lastSearchDirection: state.searchDirection,
      cursor,
    };
    const actions: VimAction[] = [{ type: 'search-match', cursor, pattern, found: Boolean(match) }];
    if (!match) actions.push({ type: 'message', text: `Pattern not found: ${pattern}`, tone: 'fault' });
    return buildVimResult(true, next, actions);
  }
  if (!input.ctrlKey && !input.altKey && !input.metaKey && input.key.length === 1) {
    return buildVimResult(true, { ...state, searchBuffer: state.searchBuffer + input.key }, [{ type: 'none' }]);
  }
  return buildVimResult(true, state, [{ type: 'none' }]);
}

function handlePendingOperator(state: VimBufferState, input: VimKeyInput): VimKeyResult {
  if (isEscapeKey(input)) {
    return buildVimResult(true, { ...state, pendingOperator: '', countBuffer: '' }, [{ type: 'none' }]);
  }
  const op = state.pendingOperator;
  const { hasExplicit, count } = parseCount(state.countBuffer);

  if (op === 'g' && input.key === 'g') {
    return moveState(state, moveToLine(state.lines, hasExplicit ? count : 1));
  }
  if (op === 'd' && input.key === 'd') return deleteBufferLines(state, state.cursor.line, count);
  if (op === 'y' && input.key === 'y') return yankBufferLines(state, state.cursor.line, count);
  if (op === 'm' && /^[a-z]$/.test(input.key)) {
    const marks = { ...state.marks, [input.key]: { ...state.cursor } };
    const next: VimBufferState = { ...state, marks, pendingOperator: '', countBuffer: '' };
    return buildVimResult(true, next, [{ type: 'message', text: `Mark '${input.key}' set`, tone: 'neutral' }]);
  }
  if (op === "'" && /^[a-z]$/.test(input.key)) {
    const mark = state.marks[input.key];
    if (!mark) {
      const next: VimBufferState = { ...state, pendingOperator: '', countBuffer: '' };
      return buildVimResult(true, next, [{ type: 'message', text: `Mark '${input.key}' not set`, tone: 'fault' }]);
    }
    return moveState(state, moveFirstNonBlank(state.lines, mark));
  }
  return buildVimResult(true, { ...state, pendingOperator: '', countBuffer: '' }, [{ type: 'none' }]);
}

function toggleVisualMode(state: VimBufferState, target: Extract<VimMode, 'visual' | 'visual-line'>): VimKeyResult {
  const exiting = state.mode === target;
  const nextMode: VimMode = exiting ? 'normal' : target;
  const next: VimBufferState = {
    ...state,
    mode: nextMode,
    visualAnchor: exiting ? null : state.visualAnchor ?? { ...state.cursor },
    countBuffer: '',
    pendingOperator: '',
  };
  return buildVimResult(true, next, [{ type: 'mode-changed', mode: nextMode }]);
}

function repeatLastSearch(state: VimBufferState, flip: boolean): VimKeyResult {
  if (!state.lastSearchPattern) {
    return buildVimResult(true, { ...state, countBuffer: '' }, [{ type: 'message', text: 'No previous search', tone: 'fault' }]);
  }
  const dir: VimSearchDirection = flip
    ? state.lastSearchDirection === 'forward' ? 'backward' : 'forward'
    : state.lastSearchDirection;
  const match = findPatternMatch(state.lines, state.cursor, state.lastSearchPattern, dir, true);
  const cursor = match ?? state.cursor;
  const actions: VimAction[] = [{ type: 'search-match', cursor, pattern: state.lastSearchPattern, found: Boolean(match) }];
  if (!match) actions.push({ type: 'message', text: `Pattern not found: ${state.lastSearchPattern}`, tone: 'fault' });
  return buildVimResult(true, { ...state, cursor, countBuffer: '' }, actions);
}

function resolveMotion(state: VimBufferState, key: string, count: number, hasExplicit: boolean): VimCursor | null {
  const { lines, cursor } = state;
  switch (key) {
    case 'h':
    case 'ArrowLeft':
      return moveHorizontal(lines, cursor, -count);
    case 'l':
    case 'ArrowRight':
      return moveHorizontal(lines, cursor, count);
    case 'j':
    case 'ArrowDown':
      return moveVertical(lines, cursor, count);
    case 'k':
    case 'ArrowUp':
      return moveVertical(lines, cursor, -count);
    case 'w':
      return moveWordForward(lines, cursor, count);
    case 'b':
      return moveWordBackward(lines, cursor, count);
    case 'e':
      return moveWordEnd(lines, cursor, count);
    case '0':
      return moveLineStart(cursor);
    case '^':
      return moveFirstNonBlank(lines, cursor);
    case '$':
      return moveLineEnd(lines, cursor);
    case 'G':
      return moveToLine(lines, hasExplicit ? count : lines.length);
    default:
      return null;
  }
}

function resolveCommandOrEdit(state: VimBufferState, key: string, count: number): VimKeyResult {
  if (key === 'n' || key === 'N') return repeatLastSearch(state, key === 'N');
  if (key === 'v') return toggleVisualMode(state, 'visual');
  if (key === 'V') return toggleVisualMode(state, 'visual-line');
  if (key === 'g' || key === 'm' || key === "'") {
    return buildVimResult(true, { ...state, pendingOperator: key }, [{ type: 'none' }]);
  }
  if (key === 'd' || key === 'y') {
    if (state.mode === 'visual' || state.mode === 'visual-line') {
      const sel = computeVisualSelection(state.mode, state.visualAnchor, state.cursor, state.lines);
      const startLine = sel ? sel.start.line : state.cursor.line;
      const lineCount = sel ? sel.end.line - sel.start.line + 1 : 1;
      return key === 'd' ? deleteBufferLines(state, startLine, lineCount) : yankBufferLines(state, startLine, lineCount);
    }
    return buildVimResult(true, { ...state, pendingOperator: key }, [{ type: 'none' }]);
  }
  return resolveInsertOrEditKey(state, key, count);
}

function resolveInsertOrEditKey(state: VimBufferState, key: string, count: number): VimKeyResult {
  const lineText = state.lines[state.cursor.line] ?? '';
  switch (key) {
    case 'i':
      return enterInsertAt(state, state.cursor);
    case 'a':
      return enterInsertAt(state, { line: state.cursor.line, col: Math.min(lineText.length, state.cursor.col + 1) });
    case 'I':
      return enterInsertAt(state, moveFirstNonBlank(state.lines, state.cursor));
    case 'A':
      return enterInsertAt(state, { line: state.cursor.line, col: lineText.length });
    case 'o':
      return enterInsertAt(state, state.cursor, 'below');
    case 'O':
      return enterInsertAt(state, state.cursor, 'above');
    case 'p':
      return applyPaste(state, count);
    case 'x': {
      if (state.readOnly) return readOnlyError(state);
      if (lineText.length === 0) return buildVimResult(true, { ...state, countBuffer: '' }, [{ type: 'none' }]);
      const lines = [...state.lines];
      lines[state.cursor.line] = lineText.slice(0, state.cursor.col) + lineText.slice(state.cursor.col + count);
      return commitBufferEdit(state, lines, state.cursor, false);
    }
    default:
      return buildVimResult(false, { ...state, countBuffer: '' }, [{ type: 'none' }]);
  }
}

function handleNormalOrVisualKey(state: VimBufferState, input: VimKeyInput): VimKeyResult {
  if (isEscapeKey(input)) {
    if (state.mode !== 'normal') {
      const next: VimBufferState = { ...state, mode: 'normal', visualAnchor: null, countBuffer: '', pendingOperator: '' };
      return buildVimResult(true, next, [{ type: 'mode-changed', mode: 'normal' }]);
    }
    return buildVimResult(state.countBuffer.length > 0, { ...state, countBuffer: '', pendingOperator: '' }, [{ type: 'none' }]);
  }

  const { hasExplicit, count } = parseCount(state.countBuffer);
  if (input.ctrlKey) {
    const k = input.key.toLowerCase();
    if (k === 'u') return moveState(state, moveHalfPage(state.lines, state.cursor, state.viewportHeight, 'up', count));
    if (k === 'd') return moveState(state, moveHalfPage(state.lines, state.cursor, state.viewportHeight, 'down', count));
    return buildVimResult(false, state, [{ type: 'none' }]);
  }

  const key = input.key;
  if ((key >= '1' && key <= '9') || (key === '0' && state.countBuffer.length > 0)) {
    return buildVimResult(true, { ...state, countBuffer: state.countBuffer + key }, [{ type: 'none' }]);
  }
  if (key === ':') {
    const next: VimBufferState = { ...state, mode: 'command', commandBuffer: '', countBuffer: '', pendingOperator: '' };
    return buildVimResult(true, next, [{ type: 'mode-changed', mode: 'command' }]);
  }
  if (key === '/' || key === '?') {
    const next: VimBufferState = {
      ...state,
      searchPromptActive: true,
      searchDirection: key === '/' ? 'forward' : 'backward',
      searchBuffer: '',
      countBuffer: '',
    };
    return buildVimResult(true, next, [{ type: 'none' }]);
  }

  const motion = resolveMotion(state, key, count, hasExplicit);
  if (motion) return moveState(state, motion);
  return resolveCommandOrEdit(state, key, count);
}

/** Processes a single key event against the current immutable Vim buffer state. */
export function stepVimEngine(state: VimBufferState, input: VimKeyInput): VimKeyResult {
  if (MODIFIER_ONLY_KEYS.has(input.key)) return buildVimResult(false, state, [{ type: 'none' }]);
  if (input.altKey || input.metaKey) return buildVimResult(false, state, [{ type: 'none' }]);
  if (state.mode === 'command') return handleCommandKey(state, input);
  if (state.searchPromptActive) return handleSearchPromptKey(state, input);
  if (state.mode === 'insert') return handleInsertModeKey(state, input, isEscapeKey(input));
  if (state.pendingOperator !== '') return handlePendingOperator(state, input);
  return handleNormalOrVisualKey(state, input);
}
