import { expect, type Page } from '@playwright/test';

type OverlayLayer = 'base' | 'toast';

interface TextBox {
  text: string;
  tag: string;
  layer: OverlayLayer;
  x: number;
  y: number;
  right: number;
  bottom: number;
}

interface StyleSnapshot {
  title: string;
  bodyBg: string;
  topbarBg: string | null;
  statusbarBg: string | null;
  windowDotColors: string[];
  headerText: string;
  bodyText: string;
  scrollWidth: number;
  clientWidth: number;
  smallFonts: Array<{ tag: string; text: string; fontSize: number }>;
  neonHits: Array<{ tag: string; prop: string; value: string }>;
}

const BANNED_ANYWHERE = ['mas' + 'ter', 'sla' + 've'];
const BANNED_WORDS = [new RegExp('\\bMO' + 'SI\\b'), new RegExp('\\bMI' + 'SO\\b')];
const LEGACY_NEON_RGB = [
  'rgb(10, 132, 255)',
  'rgb(48, 209, 88)',
  'rgb(255, 214, 10)',
  'rgb(255, 69, 58)',
  'rgb(191, 90, 242)',
];

function boxesOverlap(a: TextBox, b: TextBox): boolean {
  const overlapX = Math.min(a.right, b.right) - Math.max(a.x, b.x);
  const overlapY = Math.min(a.bottom, b.bottom) - Math.max(a.y, b.y);
  return overlapX > 2 && overlapY > 2;
}

async function collectStyleSnapshot(page: Page): Promise<StyleSnapshot> {
  return page.evaluate((neonList) => {
    const neonSet = new Set(neonList);
    const isVisible = (el: Element): boolean => {
      const s = getComputedStyle(el);
      if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };

    const smallFonts: Array<{ tag: string; text: string; fontSize: number }> = [];
    const neonHits: Array<{ tag: string; prop: string; value: string }> = [];
    for (const el of Array.from(document.body.querySelectorAll('*'))) {
      if (!isVisible(el)) continue;
      const s = getComputedStyle(el);
      for (const prop of ['color', 'backgroundColor', 'borderColor'] as const) {
        if (neonSet.has(s[prop])) neonHits.push({ tag: el.tagName.toLowerCase(), prop, value: s[prop] });
      }
      const hasText = Array.from(el.childNodes).some((n) => n.nodeType === Node.TEXT_NODE && (n.textContent ?? '').trim().length > 0);
      if (hasText && !el.closest('.es-kicker, [data-allow-11px], .es-kbd, kbd')) {
        const fs = Number.parseFloat(s.fontSize || '0');
        if (fs > 0 && fs < 12) smallFonts.push({ tag: el.tagName.toLowerCase(), text: (el.textContent ?? '').trim().slice(0, 32), fontSize: fs });
      }
    }

    const topbar = document.querySelector('[data-testid="shell-topbar"]');
    const statusbar = document.querySelector('[data-testid="shell-statusbar"]');
    const dots = Array.from(document.querySelectorAll('[data-testid="window-dot"]'));
    return {
      title: document.title,
      bodyBg: getComputedStyle(document.body).backgroundColor,
      topbarBg: topbar ? getComputedStyle(topbar).backgroundColor : null,
      statusbarBg: statusbar ? getComputedStyle(statusbar).backgroundColor : null,
      windowDotColors: dots.map((d) => getComputedStyle(d).backgroundColor),
      headerText: topbar?.textContent ?? '',
      bodyText: document.body.innerText ?? '',
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      smallFonts,
      neonHits,
    };
  }, LEGACY_NEON_RGB);
}

async function collectTextBoxes(page: Page): Promise<TextBox[]> {
  return page.evaluate(() => {
    const activeDialog = document.querySelector('[role="dialog"], [data-testid="drop-veil"]');
    const scopeRoot = activeDialog ?? document.body;
    const isVisible = (el: Element): boolean => {
      const s = getComputedStyle(el);
      if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };

    const walker = document.createTreeWalker(scopeRoot, NodeFilter.SHOW_TEXT);
    const out: TextBox[] = [];
    let current = walker.nextNode();
    while (current) {
      const parent = current.parentElement;
      if (parent && isVisible(parent) && (current.textContent ?? '').trim().length > 0) {
        if (activeDialog || !parent.closest('[role="dialog"]')) {
          const range = document.createRange();
          range.selectNodeContents(current);
          const raw = range.getBoundingClientRect();
          let left = raw.left;
          let top = raw.top;
          let right = raw.right;
          let bottom = raw.bottom;
          for (let anc: HTMLElement | null = parent; anc && anc !== document.body; anc = anc.parentElement) {
            const st = getComputedStyle(anc);
            if (st.overflowX === 'hidden' || st.overflowX === 'auto' || st.overflowX === 'scroll' || st.overflowX === 'clip') {
              const b = anc.getBoundingClientRect();
              left = Math.max(left, b.left);
              right = Math.min(right, b.right);
            }
            if (st.overflowY === 'hidden' || st.overflowY === 'auto' || st.overflowY === 'scroll' || st.overflowY === 'clip') {
              const b = anc.getBoundingClientRect();
              top = Math.max(top, b.top);
              bottom = Math.min(bottom, b.bottom);
            }
          }
          if (right - left > 1 && bottom - top > 1) {
            const layer: OverlayLayer = parent.closest('.toast-stack') ? 'toast' : 'base';
            out.push({
              text: (current.textContent ?? '').trim().slice(0, 40),
              tag: parent.tagName.toLowerCase(),
              layer,
              x: left,
              y: top,
              right,
              bottom,
            });
          }
        }
      }
      current = walker.nextNode();
    }
    return out;
  });
}

export async function auditEditorialSlateScreen(page: Page, contextLabel: string): Promise<void> {
  const snap = await collectStyleSnapshot(page);
  const textBoxes = await collectTextBoxes(page);

  expect(snap.scrollWidth, `${contextLabel}: horizontal overflow`).toBeLessThanOrEqual(snap.clientWidth);
  expect(snap.smallFonts, `${contextLabel}: >= 12px font floor`).toEqual([]);
  expect(snap.neonHits, `${contextLabel}: forbidden neon palette`).toEqual([]);
  expect(snap.title, `${contextLabel}: anonymous title`).not.toMatch(/obsidian|ra8 workbench/i);
  expect(snap.headerText, `${contextLabel}: anonymous header`).not.toMatch(/obsidian|ra8 workbench/i);
  expect(snap.windowDotColors.length, `${contextLabel}: 3 window control dots`).toBe(3);
  for (const dotBg of snap.windowDotColors) {
    expect(dotBg, `${contextLabel}: window dot #242B35`).toBe('rgb(36, 43, 53)');
  }
  expect(snap.bodyBg, `${contextLabel}: canvas #10131A`).toBe('rgb(16, 19, 26)');
  expect(snap.topbarBg, `${contextLabel}: topbar #0B0E15`).toMatch(/^rgba?\(11, 14, 21/);
  expect(snap.statusbarBg, `${contextLabel}: statusbar #0B0E15`).toMatch(/^rgba?\(11, 14, 21/);

  const lowerBody = snap.bodyText.toLowerCase();
  for (const banned of BANNED_ANYWHERE) {
    expect(lowerBody, `${contextLabel}: banned word ${banned}`).not.toContain(banned);
  }
  for (const rx of BANNED_WORDS) {
    expect(snap.bodyText, `${contextLabel}: banned word ${rx}`).not.toMatch(rx);
  }

  const overlaps: Array<[string, string]> = [];
  for (let i = 0; i < textBoxes.length; i++) {
    for (let j = i + 1; j < textBoxes.length; j++) {
      const a = textBoxes[i]!;
      const b = textBoxes[j]!;
      if (a.layer === b.layer && boxesOverlap(a, b)) overlaps.push([a.text, b.text]);
    }
  }
  expect(overlaps, `${contextLabel}: zero text bounding-box overlap`).toEqual([]);
}
