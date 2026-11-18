import { type DirtyRect, dirtyRectToRgba } from 'ra8-rpc-client';

export const MAX_LCD_SCRUB_FRAMES = 120;
export type LcdRatePreset = 'unthrottled' | 'hz60' | 'hz15' | 'scrubbing';
export type AdaptiveLcdMode = 'slow_0_1x' | 'rate_1x' | 'rate_100x' | 'rate_max';

export interface AdaptiveLcdPolicy {
  mode: AdaptiveLcdMode;
  label: string;
  subscribeRateHz: number;
  minFrameIntervalMs: number;
  captureEveryFrame: boolean;
}

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
  capturedCount: number;
  skippedCount: number;
  lastCaptureWallMs: number;
}

const ADAPTIVE_POLICIES: Record<AdaptiveLcdMode, AdaptiveLcdPolicy> = {
  slow_0_1x: {
    mode: 'slow_0_1x',
    label: '0.1x (Every Frame)',
    subscribeRateHz: 0,
    minFrameIntervalMs: 0,
    captureEveryFrame: true,
  },
  rate_1x: {
    mode: 'rate_1x',
    label: '1x (60 Hz)',
    subscribeRateHz: 60,
    minFrameIntervalMs: 16,
    captureEveryFrame: false,
  },
  rate_100x: {
    mode: 'rate_100x',
    label: '100x (15 Hz)',
    subscribeRateHz: 15,
    minFrameIntervalMs: 66,
    captureEveryFrame: false,
  },
  rate_max: {
    mode: 'rate_max',
    label: 'Max (5 Hz)',
    subscribeRateHz: 5,
    minFrameIntervalMs: 200,
    captureEveryFrame: false,
  },
};

export function computeAdaptiveLcdPolicy(mode: AdaptiveLcdMode): AdaptiveLcdPolicy {
  return ADAPTIVE_POLICIES[mode];
}

export function selectAdaptiveModeForSpeed(speedMilli: number): AdaptiveLcdMode {
  if (speedMilli > 0 && speedMilli <= 200) return 'slow_0_1x';
  if (speedMilli === 0 || speedMilli >= 500_000) return 'rate_max';
  if (speedMilli >= 10_000) return 'rate_100x';
  return 'rate_1x';
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
    capturedCount: 0,
    skippedCount: 0,
    lastCaptureWallMs: 0,
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

function compositeDirtyRect(state: LcdScrubberState, rect: DirtyRect): boolean {
  const rectW = Math.max(0, Math.round(rect.width));
  const rectH = Math.max(0, Math.round(rect.height));
  if (rectW === 0 || rectH === 0) return false;

  const rectX = Math.max(0, Math.round(rect.x));
  const rectY = Math.max(0, Math.round(rect.y));
  resizeBacking(state, rectX + rectW, rectY + rectH);

  const patchRgba = dirtyRectToRgba(rect);
  for (let row = 0; row < rectH; row++) {
    const srcOff = row * rectW * 4;
    const dstOff = ((rectY + row) * state.width + rectX) * 4;
    state.backingRgba.set(patchRgba.subarray(srcOff, srcOff + rectW * 4), dstOff);
  }
  return true;
}

export function pushDirtyRectAdaptive(
  state: LcdScrubberState,
  rect: DirtyRect,
  virtualNs: bigint,
  policy: AdaptiveLcdPolicy,
  nowWallMs: number
): LcdScrubberState {
  if (!compositeDirtyRect(state, rect)) return state;
  const shouldCapture =
    policy.captureEveryFrame ||
    state.lastCaptureWallMs === 0 ||
    nowWallMs - state.lastCaptureWallMs >= policy.minFrameIntervalMs;

  if (!shouldCapture) {
    return {
      ...state,
      skippedCount: state.skippedCount + 1,
    };
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
    capturedCount: state.capturedCount + 1,
    skippedCount: state.skippedCount,
    lastCaptureWallMs: nowWallMs,
  };
}

export function pushDirtyRectFrame(
  state: LcdScrubberState,
  rect: DirtyRect,
  virtualNs: bigint
): LcdScrubberState {
  return pushDirtyRectAdaptive(state, rect, virtualNs, ADAPTIVE_POLICIES.slow_0_1x, 0);
}

export function computeLcdSubscribeRateHz(preset: LcdRatePreset): number | null {
  if (preset === 'unthrottled') return 0;
  if (preset === 'hz60') return 60;
  if (preset === 'hz15') return 15;
  return null;
}
