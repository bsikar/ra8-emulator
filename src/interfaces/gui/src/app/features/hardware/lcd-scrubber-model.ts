import { type DirtyRect, dirtyRectToRgba } from 'ra8-rpc-client';

export const MAX_LCD_SCRUB_FRAMES = 120;
export type LcdRatePreset = 'unthrottled' | 'hz60' | 'hz15' | 'scrubbing';

export interface LcdFrameSnapshot {
  seq: number;
  virtualNs: bigint;
  width: number;
  height: number;
  rgba: Uint8ClampedArray;
}

export interface LcdScrubberState {
  width: number;
  height: number;
  backingRgba: Uint8ClampedArray;
  frames: LcdFrameSnapshot[];
  nextSeq: number;
}

export function createLcdScrubberState(width = 480, height = 272): LcdScrubberState {
  const safeW = Math.max(1, Math.round(width));
  const safeH = Math.max(1, Math.round(height));
  return {
    width: safeW,
    height: safeH,
    backingRgba: new Uint8ClampedArray(safeW * safeH * 4),
    frames: [],
    nextSeq: 1,
  };
}

function resizeBacking(state: LcdScrubberState, neededW: number, neededH: number): void {
  if (neededW <= state.width && neededH <= state.height) return;
  const nextW = Math.max(state.width, neededW);
  const nextH = Math.max(state.height, neededH);
  const nextBuf = new Uint8ClampedArray(nextW * nextH * 4);
  for (let row = 0; row < state.height; row++) {
    const srcOff = row * state.width * 4;
    const dstOff = row * nextW * 4;
    nextBuf.set(state.backingRgba.subarray(srcOff, srcOff + state.width * 4), dstOff);
  }
  state.width = nextW;
  state.height = nextH;
  state.backingRgba = nextBuf;
}

export function pushDirtyRectFrame(
  state: LcdScrubberState,
  rect: DirtyRect,
  virtualNs: bigint
): LcdScrubberState {
  const rectW = Math.max(0, Math.round(rect.width));
  const rectH = Math.max(0, Math.round(rect.height));
  if (rectW === 0 || rectH === 0) return state;

  const rectX = Math.max(0, Math.round(rect.x));
  const rectY = Math.max(0, Math.round(rect.y));
  resizeBacking(state, rectX + rectW, rectY + rectH);

  const patchRgba = dirtyRectToRgba(rect);
  for (let row = 0; row < rectH; row++) {
    const srcOff = row * rectW * 4;
    const dstOff = ((rectY + row) * state.width + rectX) * 4;
    state.backingRgba.set(patchRgba.subarray(srcOff, srcOff + rectW * 4), dstOff);
  }

  const snap: LcdFrameSnapshot = {
    seq: state.nextSeq,
    virtualNs,
    width: state.width,
    height: state.height,
    rgba: new Uint8ClampedArray(state.backingRgba),
  };
  const nextFrames =
    state.frames.length >= MAX_LCD_SCRUB_FRAMES
      ? [...state.frames.slice(state.frames.length - MAX_LCD_SCRUB_FRAMES + 1), snap]
      : [...state.frames, snap];

  return {
    width: state.width,
    height: state.height,
    backingRgba: state.backingRgba,
    frames: nextFrames,
    nextSeq: state.nextSeq + 1,
  };
}

export function computeLcdSubscribeRateHz(preset: LcdRatePreset): number | null {
  if (preset === 'unthrottled') return 0;
  if (preset === 'hz60') return 60;
  if (preset === 'hz15') return 15;
  return null;
}
