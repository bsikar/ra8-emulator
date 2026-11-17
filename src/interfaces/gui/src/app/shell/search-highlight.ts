export interface TextHighlightSegment {
  text: string;
  matched: boolean;
}

/** Splits `text` into contiguous matched/unmatched segments using sorted fuzzy `matchIndices`. */
export function splitHighlightSegments(
  text: string,
  matchIndices: readonly number[]
): TextHighlightSegment[] {
  if (!text) return [];
  if (matchIndices.length === 0) return [{ text, matched: false }];

  const hitSet = new Set<number>(matchIndices);
  const out: TextHighlightSegment[] = [];
  let buf = '';
  let curMatched = hitSet.has(0);

  for (let i = 0; i < text.length; i++) {
    const isHit = hitSet.has(i);
    if (i > 0 && isHit !== curMatched) {
      out.push({ text: buf, matched: curMatched });
      buf = '';
      curMatched = isHit;
    }
    buf += text[i] ?? '';
  }
  if (buf.length > 0) {
    out.push({ text: buf, matched: curMatched });
  }
  return out;
}
