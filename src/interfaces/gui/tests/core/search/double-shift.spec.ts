import { DoubleShiftDetector } from '../../../src/app/core/search/double-shift';

describe('DoubleShiftDetector', () => {
  it('triggers ONLY on two clean standalone Shift taps within 350ms', () => {
    let clock = 1000;
    let triggerCount = 0;
    const detector = new DoubleShiftDetector({
      windowMs: 350,
      now: () => clock,
      onTrigger: () => {
        triggerCount += 1;
      },
    });

    detector.onKeyDown({ key: 'Shift' });
    clock += 40;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    expect(detector.getPhase()).toBe('first-up');

    clock += 180;
    detector.onKeyDown({ key: 'Shift' });
    clock += 30;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(true);
    expect(triggerCount).toBe(1);
    expect(detector.getPhase()).toBe('idle');

    // A third tap must NOT trigger until a fresh pair is completed.
    clock += 80;
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    expect(triggerCount).toBe(1);
  });

  it('never false-triggers on Shift+A, Shift+Tab, modifier chords, repeats, or held Shift', () => {
    let clock = 1000;
    const detector = new DoubleShiftDetector({ windowMs: 350, now: () => clock });

    // Shift+A chord
    detector.onKeyDown({ key: 'Shift', shiftKey: true });
    clock += 15;
    detector.onKeyDown({ key: 'A', shiftKey: true });
    expect(detector.getPhase()).toBe('idle');
    expect(detector.onKeyUp({ key: 'A', shiftKey: true })).toBe(false);
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);

    // Shift+Tab chord followed immediately by one clean Shift tap (must NOT pair!)
    detector.onKeyDown({ key: 'Shift', shiftKey: true });
    detector.onKeyDown({ key: 'Tab', shiftKey: true });
    expect(detector.onKeyUp({ key: 'Tab' })).toBe(false);
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    clock += 50;
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);

    // Intervening printable key resets pending first tap
    clock += 50;
    detector.onKeyDown({ key: 'x' });
    detector.onKeyUp({ key: 'x' });
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);

    // Auto-repeat / held Shift
    clock += 100;
    detector.onKeyDown({ key: 'Shift' });
    clock += 250;
    detector.onKeyDown({ key: 'Shift', repeat: true });
    expect(detector.getPhase()).toBe('idle');
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);

    // Ctrl+Shift chord
    detector.onKeyDown({ key: 'Shift', ctrlKey: true });
    expect(detector.onKeyUp({ key: 'Shift', ctrlKey: true })).toBe(false);
  });

  it('rejects gaps > 350ms and excessively long holds without repeat', () => {
    let clock = 0;
    const detector = new DoubleShiftDetector({ windowMs: 350, now: () => clock });

    // Hold longer than 350ms without repeat event
    detector.onKeyDown({ key: 'Shift' });
    clock += 420;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    expect(detector.getPhase()).toBe('idle');

    // Gap > 350ms between tap 1 and tap 2
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    clock += 360;
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(false);
    expect(detector.getPhase()).toBe('first-up');

    // Subsequent fast tap 3 pairs with tap 2
    clock += 100;
    detector.onKeyDown({ key: 'Shift' });
    clock += 20;
    expect(detector.onKeyUp({ key: 'Shift' })).toBe(true);
  });
});
