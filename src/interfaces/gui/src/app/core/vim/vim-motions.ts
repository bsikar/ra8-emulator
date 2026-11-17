/**
 * Pure cursor motion, word boundary, pattern search, and visual selection helpers
 * for the Vim keymap engine.
 */

import type { VimCursor, VimMode, VimSearchDirection, VimSelection } from './vim-types';

type CharKind = 0 | 1 | 2;

function classifyChar(ch: string | undefined): CharKind {
  if (!ch || /\s/.test(ch)) return 0;
  if (/[A-Za-z0-9_]/.test(ch)) return 1;
  return 2;
}

/** Clamps a cursor to valid buffer coordinates for normal or insert mode. */
export function clampCursor(lines: readonly string[], cursor: VimCursor, allowEnd = false): VimCursor {
  const safeLines = lines.length > 0 ? lines : [''];
  const line = Math.max(0, Math.min(safeLines.length - 1, cursor.line));
  const text = safeLines[line] ?? '';
  const maxCol = allowEnd ? text.length : Math.max(0, text.length - 1);
  const col = Math.max(0, Math.min(maxCol, cursor.col));
  return { line, col };
}

/** Moves the cursor horizontally on the current line by `delta`. */
export function moveHorizontal(lines: readonly string[], cursor: VimCursor, delta: number, allowEnd = false): VimCursor {
  return clampCursor(lines, { line: cursor.line, col: cursor.col + delta }, allowEnd);
}

/** Moves the cursor vertically by `delta` lines while clamping the column. */
export function moveVertical(lines: readonly string[], cursor: VimCursor, delta: number): VimCursor {
  return clampCursor(lines, { line: cursor.line + delta, col: cursor.col }, false);
}

/** Moves half a viewport up or down (`Ctrl+u` / `Ctrl+d`). */
export function moveHalfPage(
  lines: readonly string[],
  cursor: VimCursor,
  viewportHeight: number,
  direction: 'up' | 'down',
  count: number
): VimCursor {
  const step = Math.max(1, Math.floor(viewportHeight / 2)) * Math.max(1, count);
  const delta = direction === 'up' ? -step : step;
  return moveVertical(lines, cursor, delta);
}

/** Moves to column 0 of the current line (`0`). */
export function moveLineStart(cursor: VimCursor): VimCursor {
  return { line: cursor.line, col: 0 };
}

/** Moves to the first non-whitespace character on the current line (`^`). */
export function moveFirstNonBlank(lines: readonly string[], cursor: VimCursor): VimCursor {
  const clamped = clampCursor(lines, cursor, false);
  const text = lines[clamped.line] ?? '';
  const match = /\S/.exec(text);
  return { line: clamped.line, col: match ? match.index : 0 };
}

/** Moves to the last character of the current line (`$`). */
export function moveLineEnd(lines: readonly string[], cursor: VimCursor): VimCursor {
  const clamped = clampCursor(lines, cursor, false);
  const text = lines[clamped.line] ?? '';
  return { line: clamped.line, col: Math.max(0, text.length - 1) };
}

/** Jumps to a 1-based line number (`gg` / `G`), resting on its first non-blank character. */
export function moveToLine(lines: readonly string[], oneBasedLine: number): VimCursor {
  const safeLines = lines.length > 0 ? lines : [''];
  const targetLine = Math.max(0, Math.min(safeLines.length - 1, oneBasedLine - 1));
  return moveFirstNonBlank(safeLines, { line: targetLine, col: 0 });
}

function stepSingleWordForward(lines: readonly string[], start: VimCursor): VimCursor {
  let line = start.line;
  let col = start.col;
  const currentText = lines[line] ?? '';
  const startKind = classifyChar(currentText[col]);
  if (startKind !== 0) {
    while (col < currentText.length && classifyChar(currentText[col]) === startKind) {
      col += 1;
    }
  }
  while (line < lines.length) {
    const text = lines[line] ?? '';
    while (col < text.length && classifyChar(text[col]) === 0) {
      col += 1;
    }
    if (col < text.length) return { line, col };
    if (line + 1 >= lines.length) break;
    line += 1;
    col = 0;
    if ((lines[line] ?? '').length === 0) return { line, col: 0 };
  }
  return clampCursor(lines, { line: lines.length - 1, col: Math.max(0, (lines[lines.length - 1] ?? '').length - 1) });
}

/** Advances forward by `count` Vim words (`w`). */
export function moveWordForward(lines: readonly string[], cursor: VimCursor, count: number): VimCursor {
  let pos = clampCursor(lines, cursor, false);
  const steps = Math.max(1, count);
  for (let i = 0; i < steps; i++) {
    pos = stepSingleWordForward(lines, pos);
  }
  return pos;
}

function stepSingleWordBackward(lines: readonly string[], start: VimCursor): VimCursor {
  let line = start.line;
  let col = start.col - 1;
  while (line >= 0) {
    const text = lines[line] ?? '';
    if (col < 0) {
      if (line === 0) return { line: 0, col: 0 };
      line -= 1;
      const prev = lines[line] ?? '';
      if (prev.length === 0) return { line, col: 0 };
      col = prev.length - 1;
      continue;
    }
    while (col >= 0 && classifyChar(text[col]) === 0) col -= 1;
    if (col < 0) continue;
    const kind = classifyChar(text[col]);
    while (col > 0 && classifyChar(text[col - 1]) === kind) col -= 1;
    return { line, col };
  }
  return { line: 0, col: 0 };
}

/** Moves backward by `count` Vim words (`b`). */
export function moveWordBackward(lines: readonly string[], cursor: VimCursor, count: number): VimCursor {
  let pos = clampCursor(lines, cursor, false);
  const steps = Math.max(1, count);
  for (let i = 0; i < steps; i++) {
    pos = stepSingleWordBackward(lines, pos);
  }
  return pos;
}

function stepSingleWordEnd(lines: readonly string[], start: VimCursor): VimCursor {
  let line = start.line;
  let col = start.col + 1;
  while (line < lines.length) {
    const text = lines[line] ?? '';
    while (col < text.length && classifyChar(text[col]) === 0) col += 1;
    if (col < text.length) {
      const kind = classifyChar(text[col]);
      while (col + 1 < text.length && classifyChar(text[col + 1]) === kind) col += 1;
      return { line, col };
    }
    if (line + 1 >= lines.length) break;
    line += 1;
    col = 0;
  }
  return clampCursor(lines, { line: lines.length - 1, col: Math.max(0, (lines[lines.length - 1] ?? '').length - 1) });
}

/** Advances to the end of the current or `count`-th next Vim word (`e`). */
export function moveWordEnd(lines: readonly string[], cursor: VimCursor, count: number): VimCursor {
  let pos = clampCursor(lines, cursor, false);
  const steps = Math.max(1, count);
  for (let i = 0; i < steps; i++) {
    pos = stepSingleWordEnd(lines, pos);
  }
  return pos;
}

/** Searches for `pattern` forward or backward with wrap-around across lines. */
export function findPatternMatch(
  lines: readonly string[],
  from: VimCursor,
  pattern: string,
  direction: VimSearchDirection,
  skipStart = true
): VimCursor | null {
  if (!pattern || lines.length === 0) return null;
  return direction === 'forward'
    ? searchForward(lines, from, pattern, skipStart)
    : searchBackward(lines, from, pattern, skipStart);
}

function searchForward(lines: readonly string[], from: VimCursor, pattern: string, skipStart: boolean): VimCursor | null {
  const n = lines.length;
  for (let offset = 0; offset <= n; offset++) {
    const lineIdx = (from.line + offset) % n;
    const text = lines[lineIdx] ?? '';
    const startCol = offset === 0 ? from.col + (skipStart ? 1 : 0) : 0;
    if (startCol > text.length) continue;
    const found = text.indexOf(pattern, startCol);
    if (found >= 0 && (offset < n || found <= from.col)) {
      return { line: lineIdx, col: found };
    }
  }
  return null;
}

function searchBackward(lines: readonly string[], from: VimCursor, pattern: string, skipStart: boolean): VimCursor | null {
  const n = lines.length;
  for (let offset = 0; offset <= n; offset++) {
    const lineIdx = (from.line - offset + n) % n;
    const text = lines[lineIdx] ?? '';
    const limitCol = offset === 0 ? from.col - (skipStart ? 1 : 0) : text.length;
    if (limitCol < 0) continue;
    const found = text.lastIndexOf(pattern, limitCol);
    if (found >= 0 && (offset < n || found >= from.col)) {
      return { line: lineIdx, col: found };
    }
  }
  return null;
}

/** Computes a normalized selection range when in `'visual'` or `'visual-line'` mode. */
export function computeVisualSelection(
  mode: VimMode,
  anchor: VimCursor | null,
  cursor: VimCursor,
  lines: readonly string[]
): VimSelection | null {
  if ((mode !== 'visual' && mode !== 'visual-line') || !anchor) return null;
  const a = clampCursor(lines, anchor, false);
  const b = clampCursor(lines, cursor, false);
  const aBeforeB = a.line < b.line || (a.line === b.line && a.col <= b.col);
  const start = aBeforeB ? { ...a } : { ...b };
  const end = aBeforeB ? { ...b } : { ...a };
  if (mode === 'visual-line') {
    start.col = 0;
    end.col = Math.max(0, (lines[end.line] ?? '').length - 1);
  }
  return { start, end, linewise: mode === 'visual-line' };
}
