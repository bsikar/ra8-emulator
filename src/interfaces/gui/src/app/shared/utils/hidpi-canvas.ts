/**
 * HiDPI `<canvas>` backing-store synchronization (`ResizeObserver` + `devicePixelRatio`)
 * and aspect-locked inverse pointer mapping for native panel touch coordinates (`0x011F`).
 */

export interface HiDpiCanvasMetrics {
  cssWidth: number;
  cssHeight: number;
  widthPx: number;
  heightPx: number;
  dpr: number;
}

export interface AspectRect {
  x: number;
  y: number;
  width: number;
  height: number;
  scale: number;
}

export interface PanelCoordinateHit {
  x: number;
  y: number;
  inside: boolean;
}

export function resolveDevicePixelRatio(explicitDpr?: number): number {
  const raw = explicitDpr ?? (typeof window !== 'undefined' ? window.devicePixelRatio : 1);
  if (!Number.isFinite(raw) || raw <= 0) return 1;
  return Math.min(4, Math.max(1, raw));
}

/** Synchronizes a canvas's pixel buffer with its CSS box and `devicePixelRatio`. */
export function syncHiDpiCanvas(
  canvas: HTMLCanvasElement,
  cssWidth: number,
  cssHeight: number,
  explicitDpr?: number
): HiDpiCanvasMetrics {
  const dpr = resolveDevicePixelRatio(explicitDpr);
  const safeCssW = Math.max(1, Math.round(cssWidth));
  const safeCssH = Math.max(1, Math.round(cssHeight));
  const widthPx = Math.max(1, Math.round(safeCssW * dpr));
  const heightPx = Math.max(1, Math.round(safeCssH * dpr));
  if (canvas.width !== widthPx) canvas.width = widthPx;
  if (canvas.height !== heightPx) canvas.height = heightPx;
  return { cssWidth: safeCssW, cssHeight: safeCssH, widthPx, heightPx, dpr };
}

/** Observes a canvas element's CSS box and invokes `onResize` with updated HiDPI metrics. */
export function observeHiDpiCanvas(
  canvas: HTMLCanvasElement,
  onResize: (metrics: HiDpiCanvasMetrics) => void,
  explicitDpr?: number
): () => void {
  const measure = (): void => {
    const rect = canvas.getBoundingClientRect();
    const w = rect.width > 0 ? rect.width : canvas.clientWidth || canvas.width || 320;
    const h = rect.height > 0 ? rect.height : canvas.clientHeight || canvas.height || 200;
    onResize(syncHiDpiCanvas(canvas, w, h, explicitDpr));
  };
  measure();
  if (typeof ResizeObserver === 'undefined') {
    return () => undefined;
  }
  const ro = new ResizeObserver(() => measure());
  ro.observe(canvas);
  return () => ro.disconnect();
}

/** Computes a centered aspect-locked rectangle inside a viewport. */
export function computeAspectLockedRect(
  viewportWidth: number,
  viewportHeight: number,
  nativeWidth: number,
  nativeHeight: number
): AspectRect {
  const vw = Math.max(1, viewportWidth);
  const vh = Math.max(1, viewportHeight);
  const nw = Math.max(1, nativeWidth);
  const nh = Math.max(1, nativeHeight);
  const scale = Math.min(vw / nw, vh / nh);
  const width = nw * scale;
  const height = nh * scale;
  return {
    x: (vw - width) / 2,
    y: (vh - height) / 2,
    width,
    height,
    scale,
  };
}

/** Maps a CSS client coordinate back to clamped integer `[0..nativeW-1, 0..nativeH-1]` panel space. */
export function mapClientPointToPanel(
  clientX: number,
  clientY: number,
  bounds: { left: number; top: number; width: number; height: number },
  nativeWidth: number,
  nativeHeight: number,
  aspectLocked = true
): PanelCoordinateHit {
  const nw = Math.max(1, Math.round(nativeWidth));
  const nh = Math.max(1, Math.round(nativeHeight));
  const localX = clientX - bounds.left;
  const localY = clientY - bounds.top;
  const box = aspectLocked
    ? computeAspectLockedRect(bounds.width, bounds.height, nw, nh)
    : { x: 0, y: 0, width: Math.max(1, bounds.width), height: Math.max(1, bounds.height), scale: 1 };

  const relX = (localX - box.x) / Math.max(1, box.width);
  const relY = (localY - box.y) / Math.max(1, box.height);
  const inside = relX >= 0 && relX <= 1 && relY >= 0 && relY <= 1;
  const clampedX = Math.min(nw - 1, Math.max(0, Math.floor(relX * nw)));
  const clampedY = Math.min(nh - 1, Math.max(0, Math.floor(relY * nh)));
  return { x: clampedX, y: clampedY, inside };
}

/** Returns null cleanly in headless jsdom environments lacking 2D canvas support. */
export function get2dContext(canvas: HTMLCanvasElement): CanvasRenderingContext2D | null {
  if (typeof navigator !== 'undefined' && /jsdom/i.test(navigator.userAgent)) {
    return null;
  }
  return canvas.getContext('2d');
}
