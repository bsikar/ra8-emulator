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
} from '../../../src/app/core/vim/vim-motions';

describe('vim-motions', () => {
  const lines = ['  alpha beta', 'gamma(delta)', '', '  omega'];

  it('handles line and viewport motions with proper clamping', () => {
    expect(clampCursor(lines, { line: -2, col: 99 })).toEqual({ line: 0, col: 11 });
    expect(moveHorizontal(lines, { line: 0, col: 2 }, 3)).toEqual({ line: 0, col: 5 });
    expect(moveVertical(lines, { line: 0, col: 8 }, 2)).toEqual({ line: 2, col: 0 });
    expect(moveLineStart({ line: 1, col: 7 })).toEqual({ line: 1, col: 0 });
    expect(moveFirstNonBlank(lines, { line: 0, col: 8 })).toEqual({ line: 0, col: 2 });
    expect(moveLineEnd(lines, { line: 0, col: 0 })).toEqual({ line: 0, col: 11 });
    expect(moveToLine(lines, 4)).toEqual({ line: 3, col: 2 });
    expect(moveHalfPage(lines, { line: 0, col: 0 }, 4, 'down', 1)).toEqual({ line: 2, col: 0 });
    expect(moveHalfPage(lines, { line: 3, col: 2 }, 4, 'up', 1)).toEqual({ line: 1, col: 2 });
  });

  it('steps forward, backward, and to word ends across tokens and empty lines', () => {
    expect(moveWordForward(lines, { line: 0, col: 2 }, 1)).toEqual({ line: 0, col: 8 });
    expect(moveWordForward(lines, { line: 0, col: 2 }, 2)).toEqual({ line: 1, col: 0 });
    expect(moveWordForward(lines, { line: 1, col: 6 }, 1)).toEqual({ line: 1, col: 11 });
    expect(moveWordBackward(lines, { line: 3, col: 2 }, 1)).toEqual({ line: 2, col: 0 });
    expect(moveWordBackward(lines, { line: 1, col: 6 }, 2)).toEqual({ line: 1, col: 0 });
    expect(moveWordEnd(lines, { line: 0, col: 0 }, 1)).toEqual({ line: 0, col: 6 });
    expect(moveWordEnd(lines, { line: 0, col: 8 }, 2)).toEqual({ line: 1, col: 4 });
  });

  it('finds wrapped pattern matches and normalizes visual selections', () => {
    const fwd = findPatternMatch(lines, { line: 2, col: 0 }, 'alpha', 'forward');
    expect(fwd).toEqual({ line: 0, col: 2 });
    const bwd = findPatternMatch(lines, { line: 0, col: 0 }, 'omega', 'backward');
    expect(bwd).toEqual({ line: 3, col: 2 });
    expect(findPatternMatch(lines, { line: 0, col: 0 }, 'missing', 'forward')).toBeNull();

    expect(computeVisualSelection('normal', { line: 0, col: 0 }, { line: 1, col: 2 }, lines)).toBeNull();
    expect(computeVisualSelection('visual', { line: 2, col: 0 }, { line: 0, col: 4 }, lines)).toEqual({
      start: { line: 0, col: 4 },
      end: { line: 2, col: 0 },
      linewise: false,
    });
    expect(computeVisualSelection('visual-line', { line: 3, col: 3 }, { line: 1, col: 4 }, lines)).toEqual({
      start: { line: 1, col: 0 },
      end: { line: 3, col: 6 },
      linewise: true,
    });
  });
});
