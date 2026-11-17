/**
 * HTML5 Canvas LCD framebuffer rendering helper.
 * Decodes topic `0x0103` (`lcd_dirty`) `DirtyRect` pixel buffers into RGBA.
 */

import type { DirtyRect } from "../wire/session.js";

export type PixelFormat = "grayscale" | "rgb565" | "rgb24" | "argb32" | "rgba32";

/** Detect pixel format based on pixel buffer length and rectangle dimensions. */
export function detectPixelFormat(rect: DirtyRect): PixelFormat {
  const pixelCount = rect.width * rect.height;
  if (pixelCount === 0) return "grayscale";

  const bytes = rect.pixels.length;
  if (bytes === pixelCount) return "grayscale";
  if (bytes === pixelCount * 2) return "rgb565";
  if (bytes === pixelCount * 3) return "rgb24";
  if (bytes === pixelCount * 4) return "rgba32";
  return "grayscale";
}

function writeRgb565(src: Uint8Array, out: Uint8ClampedArray, pixelCount: number): void {
  for (let i = 0; i < pixelCount; i++) {
    const lo = src[i * 2] ?? 0;
    const hi = src[i * 2 + 1] ?? 0;
    const val = lo | (hi << 8);
    const outIdx = i * 4;
    out[outIdx] = (((val >> 11) & 0x1f) * 255) / 31;
    out[outIdx + 1] = (((val >> 5) & 0x3f) * 255) / 63;
    out[outIdx + 2] = ((val & 0x1f) * 255) / 31;
    out[outIdx + 3] = 255;
  }
}

/** Convert `DirtyRect` pixel buffer to RGBA `Uint8ClampedArray`. */
export function dirtyRectToRgba(
  rect: DirtyRect,
  targetRgba?: Uint8ClampedArray<ArrayBuffer>,
  forcedFormat?: PixelFormat
): Uint8ClampedArray<ArrayBuffer> {
  const pixelCount = rect.width * rect.height;
  const out = targetRgba ?? new Uint8ClampedArray(pixelCount * 4);
  const src = rect.pixels;
  const format = forcedFormat ?? detectPixelFormat(rect);

  if (format === "rgb565") {
    writeRgb565(src, out, pixelCount);
    return out;
  }

  for (let i = 0; i < pixelCount; i++) {
    const outIdx = i * 4;
    if (format === "grayscale") {
      const g = src[i] ?? 0;
      out[outIdx] = g;
      out[outIdx + 1] = g;
      out[outIdx + 2] = g;
      out[outIdx + 3] = 255;
    } else if (format === "rgb24") {
      const s = i * 3;
      out[outIdx] = src[s] ?? 0;
      out[outIdx + 1] = src[s + 1] ?? 0;
      out[outIdx + 2] = src[s + 2] ?? 0;
      out[outIdx + 3] = 255;
    } else if (format === "argb32") {
      const s = i * 4;
      out[outIdx] = src[s + 1] ?? 0;
      out[outIdx + 1] = src[s + 2] ?? 0;
      out[outIdx + 2] = src[s + 3] ?? 0;
      out[outIdx + 3] = src[s] ?? 0;
    } else {
      const s = i * 4;
      out[outIdx] = src[s] ?? 0;
      out[outIdx + 1] = src[s + 1] ?? 0;
      out[outIdx + 2] = src[s + 2] ?? 0;
      out[outIdx + 3] = src[s + 3] ?? 255;
    }
  }
  return out;
}

/** Create standard browser `ImageData` from `DirtyRect`. */
export function createImageDataFromDirtyRect(
  rect: DirtyRect,
  forcedFormat?: PixelFormat
): ImageData {
  if (typeof ImageData === "undefined") {
    throw new Error("ImageData is only supported in browser or canvas environments");
  }
  const rgba = dirtyRectToRgba(rect, undefined, forcedFormat);
  return new ImageData(rgba, rect.width, rect.height);
}

/** Paint a `DirtyRect` onto a standard 2D canvas rendering context. */
export function paintDirtyRect(
  ctx: CanvasRenderingContext2D,
  rect: DirtyRect,
  forcedFormat?: PixelFormat
): void {
  if (rect.width === 0 || rect.height === 0) return;
  ctx.putImageData(createImageDataFromDirtyRect(rect, forcedFormat), rect.x, rect.y);
}

/** High-level helper managing live LCD rendering on an HTML5 canvas. */
export class FramebufferRenderer {
  private readonly ctx: CanvasRenderingContext2D;
  private frameCount = 0;
  private lastFpsTimestamp = 0;
  private fps = 0;

  constructor(
    public readonly canvas: HTMLCanvasElement,
    options: { defaultWidth?: number; defaultHeight?: number } = {}
  ) {
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("Failed to get 2D rendering context for canvas");
    }
    this.ctx = context;
    if (options.defaultWidth && options.defaultHeight) {
      this.resize(options.defaultWidth, options.defaultHeight);
    }
  }

  public render(rect: DirtyRect, forcedFormat?: PixelFormat): void {
    if (rect.width === 0 || rect.height === 0) return;
    const requiredWidth = rect.x + rect.width;
    const requiredHeight = rect.y + rect.height;
    if (this.canvas.width < requiredWidth || this.canvas.height < requiredHeight) {
      this.resize(
        Math.max(this.canvas.width, requiredWidth),
        Math.max(this.canvas.height, requiredHeight)
      );
    }
    paintDirtyRect(this.ctx, rect, forcedFormat);
    this.updateMetrics();
  }

  public clear(color = "#000000"): void {
    this.ctx.fillStyle = color;
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  }

  public resize(width: number, height: number): void {
    this.canvas.width = width;
    this.canvas.height = height;
    this.clear();
  }

  public get currentFps(): number {
    return this.fps;
  }

  public get totalFrames(): number {
    return this.frameCount;
  }

  private updateMetrics(): void {
    this.frameCount++;
    const now = typeof performance !== "undefined" ? performance.now() : Date.now();
    if (this.lastFpsTimestamp === 0) {
      this.lastFpsTimestamp = now;
      return;
    }
    const elapsed = now - this.lastFpsTimestamp;
    if (elapsed >= 1000) {
      this.fps = Math.round((this.frameCount * 1000) / elapsed);
      this.frameCount = 0;
      this.lastFpsTimestamp = now;
    }
  }
}
