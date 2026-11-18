/**
 * Browser Fullscreen API helper (`View > Full Screen` / `F11` / `Ctrl+Cmd+F`).
 */

export interface FullscreenCapableElement {
  requestFullscreen?: () => Promise<void>;
}

export interface FullscreenCapableDocument {
  fullscreenElement?: Element | null;
  documentElement?: FullscreenCapableElement | null;
  exitFullscreen?: () => Promise<void>;
}

function defaultDoc(): FullscreenCapableDocument | null {
  return typeof document !== 'undefined' ? (document as unknown as FullscreenCapableDocument) : null;
}

export function isFullscreenActive(doc: FullscreenCapableDocument | null = defaultDoc()): boolean {
  return Boolean(doc?.fullscreenElement);
}

/** Toggles document fullscreen, returning `{ active, error }` without throwing on browser denial. */
export async function toggleDocumentFullscreen(
  doc: FullscreenCapableDocument | null = defaultDoc()
): Promise<{ active: boolean; error: string | null }> {
  if (!doc) return { active: false, error: 'Document unavailable' };
  try {
    if (doc.fullscreenElement) {
      if (typeof doc.exitFullscreen === 'function') {
        await doc.exitFullscreen();
        return { active: false, error: null };
      }
      return { active: true, error: 'Fullscreen exit API unavailable' };
    }
    const root = doc.documentElement;
    if (root && typeof root.requestFullscreen === 'function') {
      await root.requestFullscreen();
      return { active: true, error: null };
    }
    return { active: false, error: 'Fullscreen API unavailable in this browser' };
  } catch (err) {
    return {
      active: Boolean(doc.fullscreenElement),
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
