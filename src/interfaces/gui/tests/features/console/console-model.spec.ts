import { Core } from 'ra8-rpc-client';
import {
  applyLineEnding,
  computeConsoleByteStats,
  decodeHexSymbolsInText,
  evaluateWatchTriggers,
  formatBytesAsHex,
  formatEntryTimestamp,
  resolveNearestElfSymbol,
} from '../../../src/app/features/console/console-model';

describe('console-model', () => {
  it('formats hex dumps, line endings, and elapsed vs virtual ns timestamps', () => {
    expect(applyLineEnding('at', 'lf')).toBe('at\n');
    expect(applyLineEnding('at\n', 'crlf')).toBe('at\r\n');
    expect(applyLineEnding('raw', 'none')).toBe('raw');
    expect(formatBytesAsHex(new Uint8Array([0x4f, 0x4b, 0x0a]))).toBe('4f 4b 0a  |OK.|');
    expect(formatEntryTimestamp(1_500_000n, 500_000n, 'elapsed')).toBe('+1.00ms');
    expect(formatEntryTimestamp(1_500_000n, 500_000n, 'virtual')).toBe('1500000 ns');
  });

  it('resolves nearest ELF symbols inline and evaluates watch trigger rules', () => {
    const syms = new Map<number, string>([
      [0x0200_0100, 'Reset_Handler'],
      [0x0200_0200, 'uart_irq'],
    ]);
    expect(resolveNearestElfSymbol(0x0200_0208, syms)).toBe('uart_irq+0x8');
    const segs = decodeHexSymbolsInText('PC=0x02000100 LR=0x02000204', syms);
    expect(segs.some((s) => s.symbol === 'Reset_Handler')).toBe(true);
    expect(segs.some((s) => s.symbol === 'uart_irq+0x4')).toBe(true);

    const evaluated = evaluateWatchTriggers('ERR at bus fault', [
      { id: 'r1', pattern: 'fault', pauseOnMatch: true, hits: 0 },
      { id: 'r2', pattern: 'ok', pauseOnMatch: false, hits: 2 },
    ]);
    expect(evaluated.shouldPause).toBe(true);
    expect(evaluated.updated[0]?.hits).toBe(1);
    expect(evaluated.updated[1]?.hits).toBe(2);

    const stats = computeConsoleByteStats([
      { id: 1, core: Core.Cpu0, channel: 0, virtualNs: 1n, bytes: new Uint8Array(3), text: 'abc', isInput: false },
      { id: 2, core: Core.Cpu0, channel: 0, virtualNs: 2n, bytes: new Uint8Array(2), text: 'hi', isInput: true },
    ]);
    expect(stats).toEqual({ rxCount: 1, txCount: 1, rxBytes: 3, txBytes: 2 });
  });
});
