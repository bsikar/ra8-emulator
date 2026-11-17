/**
 * Standalone double-Shift gesture detector modeled after JetBrains Search Everywhere.
 * Triggers strictly on two clean Shift keydown -> keyup taps within 350ms with zero
 * intervening non-Shift keys, modifier chords, or auto-repeat holds.
 */

export type DoubleShiftPhase = 'idle' | 'first-down' | 'first-up' | 'second-down';

export interface DoubleShiftKeyInput {
  key: string;
  repeat?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
  shiftKey?: boolean;
}

export interface DoubleShiftEventInput extends DoubleShiftKeyInput {
  type: 'keydown' | 'keyup';
}

export interface DoubleShiftOptions {
  windowMs?: number;
  now?: () => number;
  onTrigger?: () => void;
}

export const DEFAULT_DOUBLE_SHIFT_WINDOW_MS = 350;

/** Stateful detector recognizing clean double-Shift taps while rejecting chords and holds. */
export class DoubleShiftDetector {
  private readonly windowMs: number;
  private readonly now: () => number;
  private readonly onTriggerCallback?: () => void;

  private phase: DoubleShiftPhase = 'idle';
  private downAt = 0;
  private firstUpAt = 0;

  constructor(options: DoubleShiftOptions = {}) {
    this.windowMs = options.windowMs ?? DEFAULT_DOUBLE_SHIFT_WINDOW_MS;
    this.now = options.now ?? (() => Date.now());
    this.onTriggerCallback = options.onTrigger;
  }

  /** Returns the current internal detector phase for inspection and testing. */
  public getPhase(): DoubleShiftPhase {
    return this.phase;
  }

  /** Resets all pending double-Shift tap state back to idle. */
  public reset(): void {
    this.phase = 'idle';
    this.downAt = 0;
    this.firstUpAt = 0;
  }

  /** Processes a keydown event; resets on repeats, modifiers, or non-Shift keys. */
  public onKeyDown(event: DoubleShiftKeyInput): void {
    if (event.repeat || event.key !== 'Shift' || event.ctrlKey || event.altKey || event.metaKey) {
      this.reset();
      return;
    }

    const timestamp = this.now();
    if (this.phase === 'first-up') {
      if (timestamp - this.firstUpAt <= this.windowMs) {
        this.phase = 'second-down';
        this.downAt = timestamp;
        return;
      }
      this.phase = 'first-down';
      this.downAt = timestamp;
      this.firstUpAt = 0;
      return;
    }

    if (this.phase === 'idle') {
      this.phase = 'first-down';
      this.downAt = timestamp;
      return;
    }

    this.reset();
  }

  /** Processes a keyup event; returns `true` only when the second clean Shift tap completes. */
  public onKeyUp(event: DoubleShiftKeyInput): boolean {
    if (event.key !== 'Shift' || event.ctrlKey || event.altKey || event.metaKey) {
      this.reset();
      return false;
    }

    const timestamp = this.now();
    const holdDuration = timestamp - this.downAt;

    if (this.phase === 'first-down') {
      if (holdDuration >= 0 && holdDuration <= this.windowMs) {
        this.phase = 'first-up';
        this.firstUpAt = timestamp;
      } else {
        this.reset();
      }
      return false;
    }

    if (this.phase === 'second-down') {
      const gapValid = this.downAt - this.firstUpAt <= this.windowMs;
      const holdValid = holdDuration >= 0 && holdDuration <= this.windowMs;
      this.reset();
      if (gapValid && holdValid) {
        this.onTriggerCallback?.();
        return true;
      }
      return false;
    }

    this.reset();
    return false;
  }

  /** Convenience entry point handling both `'keydown'` and `'keyup'` events. */
  public handleEvent(event: DoubleShiftEventInput): boolean {
    if (event.type === 'keydown') {
      this.onKeyDown(event);
      return false;
    }
    return this.onKeyUp(event);
  }
}
