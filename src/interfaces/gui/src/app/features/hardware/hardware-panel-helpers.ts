import type { BoardPreset, BoardProfile, RtcReport } from 'ra8-rpc-client';
import { computeAspectLockedRect, get2dContext } from '../../shared/utils/hidpi-canvas';

export type CameraSourceKind = 'gradient' | 'image' | 'video' | 'pipe' | 'webcam';

export interface PanelCrosshair {
  x: number;
  y: number;
}

export function paintHiDpiPanelCanvas(
  canvas: HTMLCanvasElement,
  rgba: Uint8ClampedArray,
  nativeWidth: number,
  nativeHeight: number,
  crosshair: PanelCrosshair | null
): void {
  const ctx = get2dContext(canvas);
  if (!ctx) return;
  const cw = canvas.width;
  const ch = canvas.height;
  ctx.fillStyle = '#0b0e15';
  ctx.fillRect(0, 0, cw, ch);

  const box = computeAspectLockedRect(cw, ch, nativeWidth, nativeHeight);
  if (typeof ImageData !== 'undefined' && typeof document !== 'undefined' && rgba.length >= nativeWidth * nativeHeight * 4) {
    const off = document.createElement('canvas');
    off.width = nativeWidth;
    off.height = nativeHeight;
    const offCtx = get2dContext(off);
    if (offCtx) {
      offCtx.putImageData(
        new ImageData(new Uint8ClampedArray(rgba.subarray(0, nativeWidth * nativeHeight * 4)), nativeWidth, nativeHeight),
        0,
        0
      );
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(off, box.x, box.y, box.width, box.height);
    }
  }

  ctx.strokeStyle = '#21242b';
  ctx.lineWidth = 1;
  ctx.strokeRect(box.x + 0.5, box.y + 0.5, Math.max(1, box.width - 1), Math.max(1, box.height - 1));

  if (crosshair) {
    const px = box.x + ((crosshair.x + 0.5) / Math.max(1, nativeWidth)) * box.width;
    const py = box.y + ((crosshair.y + 0.5) / Math.max(1, nativeHeight)) * box.height;
    ctx.strokeStyle = 'rgba(184, 196, 217, 0.72)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(px, box.y);
    ctx.lineTo(px, box.y + box.height);
    ctx.moveTo(box.x, py);
    ctx.lineTo(box.x + box.width, py);
    ctx.stroke();
  }
}

export function exportRgbaToPngDataUrl(
  rgba: Uint8ClampedArray,
  nativeWidth: number,
  nativeHeight: number
): string | null {
  if (typeof document === 'undefined' || typeof ImageData === 'undefined') return null;
  if (rgba.length < nativeWidth * nativeHeight * 4) return null;
  const off = document.createElement('canvas');
  off.width = nativeWidth;
  off.height = nativeHeight;
  const ctx = get2dContext(off);
  if (!ctx) return null;
  ctx.putImageData(
    new ImageData(new Uint8ClampedArray(rgba.subarray(0, nativeWidth * nativeHeight * 4)), nativeWidth, nativeHeight),
    0,
    0
  );
  return off.toDataURL('image/png');
}

export function formatRtcReport(rtc: RtcReport | null): string {
  if (!rtc) return 'Not sampled yet.';
  const d = `${rtc.year.toString().padStart(4, '0')}-${String(rtc.month).padStart(2, '0')}-${String(rtc.day).padStart(2, '0')}`;
  const t = `${String(rtc.hour).padStart(2, '0')}:${String(rtc.minute).padStart(2, '0')}:${String(rtc.second).padStart(2, '0')}`;
  return `${d} ${t} (${rtc.running ? 'running' : 'stopped'}, ${rtc.valid ? 'valid' : 'unset'})`;
}

function formatSizeMb(bytes: number): string {
  const mb = bytes / (1024 * 1024);
  return mb >= 1 ? `${Math.round(mb)} MB` : `${Math.round(bytes / 1024)} KB`;
}

export function formatBoardMemorySummary(profile: BoardProfile | null): string {
  if (!profile) return 'No profile loaded';
  return `${formatSizeMb(profile.memory.ospi.size)} OSPI · ${formatSizeMb(profile.memory.sdram.size)} SDRAM`;
}

export function formatSiliconSummary(preset: BoardPreset | null): string {
  if (!preset) return 'Custom RA8 Target';
  const coreStr = preset.cores.map((c) => `${c.arch.replace('Cortex-', '')} ${c.clockMhz}MHz`).join(' + ');
  return preset.hasNpu ? `${preset.silicon.toUpperCase()} (${coreStr} + U55)` : `${preset.silicon.toUpperCase()} (${coreStr})`;
}

export function resolveCameraSpec(kind: CameraSourceKind, customArg: string): string {
  const arg = customArg.trim();
  if (kind === 'gradient') return 'gradient';
  if (kind === 'webcam') return arg ? `webcam:${arg}` : 'webcam';
  return arg ? `${kind}:${arg}` : kind;
}
