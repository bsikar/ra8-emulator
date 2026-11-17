import { splitHighlightSegments } from '../../src/app/shell/search-highlight';

describe('splitHighlightSegments', () => {
  it('splits title into contiguous matched and unmatched spans', () => {
    expect(splitHighlightSegments('RA8P1 Vision', [0, 1, 6])).toEqual([
      { text: 'RA', matched: true },
      { text: '8P1 ', matched: false },
      { text: 'V', matched: true },
      { text: 'ision', matched: false },
    ]);
  });

  it('handles empty indices or empty text cleanly', () => {
    expect(splitHighlightSegments('', [0])).toEqual([]);
    expect(splitHighlightSegments('Debug', [])).toEqual([{ text: 'Debug', matched: false }]);
  });
});
