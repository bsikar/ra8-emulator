import { findBoardPreset } from 'ra8-rpc-client';
import {
  exportRgbaToPngDataUrl,
  formatBoardMemorySummary,
  formatRtcReport,
  formatSiliconSummary,
  paintHiDpiPanelCanvas,
  resolveCameraSpec,
} from '../../../src/app/features/hardware/hardware-panel-helpers';

describe('hardware-panel-helpers', () => {
  it('formats RTC, silicon, memory, and camera source specs accurately', () => {
    expect(formatRtcReport(null)).toBe('Not sampled yet.');
    expect(
      formatRtcReport({
        running: true,
        valid: true,
        year: 2026,
        month: 11,
        day: 18,
        hour: 9,
        minute: 5,
        second: 2,
      })
    ).toBe('2026-11-18 09:05:02 (running, valid)');

    const ra8p1 = findBoardPreset('ra8p1')!;
    expect(formatSiliconSummary(ra8p1)).toContain('RA8P1');
    expect(formatSiliconSummary(ra8p1)).toContain('U55');
    expect(formatBoardMemorySummary(ra8p1.profile)).toBe('256 MB OSPI · 128 MB SDRAM');

    expect(resolveCameraSpec('gradient', 'ignored')).toBe('gradient');
    expect(resolveCameraSpec('video', 'clip.y4m,loop')).toBe('video:clip.y4m,loop');
    expect(resolveCameraSpec('webcam', '')).toBe('webcam');
    expect(resolveCameraSpec('webcam', '0')).toBe('webcam:0');
  });

  it('handles canvas helpers gracefully in headless jsdom environments', () => {
    const canvas = document.createElement('canvas');
    const rgba = new Uint8ClampedArray(16).fill(255);
    paintHiDpiPanelCanvas(canvas, rgba, 2, 2, { x: 1, y: 1 });
    expect(exportRgbaToPngDataUrl(rgba, 2, 2)).toBeNull();
  });
});
