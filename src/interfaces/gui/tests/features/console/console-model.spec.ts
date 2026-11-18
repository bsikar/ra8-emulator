import { Core } from 'ra8-rpc-client';
import {
  applyLineEnding,
  classifyConsoleStream,
  compileConsoleSearch,
  computeConsoleByteStats,
  decodeHexSymbolsInText,
  evaluateWatchTriggers,
  filterConsoleEntries,
  formatBytesAsHex,
  formatConsoleCopyText,
  formatEntryTimestamp,
  resolveAddressDetail,
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

  it('resolves ELF symbols and file:line details and evaluates alert/marker triggers', () => {
    const syms = new Map<number, string>([
      [0x0200_0100, 'Reset_Handler'],
      [0x0200_0200, 'uart_irq'],
    ]);
    expect(resolveNearestElfSymbol(0x0200_0208, syms)).toBe('uart_irq+0x8');
    const detail = resolveAddressDetail(
      0x0200_0208,
      syms,
      { found: true, pc: 0x0200_0208, line: 42, path: 'src/uart.c' },
      []
    );
    expect(detail).toEqual({ symbol: 'uart_irq+0x8', fileLine: 'src/uart.c:42' });

    const segs = decodeHexSymbolsInText('PC=0x02000100 LR=0x02000204', syms);
    expect(segs.some((s) => s.symbol === 'Reset_Handler')).toBe(true);
    expect(segs.some((s) => s.symbol === 'uart_irq+0x4')).toBe(true);

    const evaluated = evaluateWatchTriggers('ERR at bus fault', [
      { id: 'r1', pattern: 'fault', action: 'alert_halt', pauseOnMatch: true, hits: 0 },
      { id: 'r2', pattern: 'err', action: 'marker', pauseOnMatch: false, hits: 2 },
    ]);
    expect(evaluated.shouldPause).toBe(true);
    expect(evaluated.shouldMark).toBe(true);
    expect(evaluated.updated[0]?.hits).toBe(1);
    expect(evaluated.updated[1]?.hits).toBe(3);
  });

  it('classifies UART/SWO/RTT streams, compiles regex safely, and formats clipboard text', () => {
    const entries = [
      { id: 1, core: Core.Cpu0, channel: 8, virtualNs: 100n, bytes: new TextEncoder().encode('boot ok'), text: 'boot ok', isInput: false },
      { id: 2, core: Core.Cpu0, channel: 10, virtualNs: 200n, bytes: new TextEncoder().encode('[swo] irq=12'), text: '[swo] irq=12', isInput: false },
      { id: 3, core: Core.Cpu0, channel: 11, virtualNs: 300n, bytes: new TextEncoder().encode('rtt ping'), text: 'rtt ping', isInput: true },
    ];
    expect(classifyConsoleStream(entries[0]!)).toBe('uart');
    expect(classifyConsoleStream(entries[1]!)).toBe('swo');
    expect(classifyConsoleStream(entries[2]!)).toBe('rtt');

    expect(filterConsoleEntries(entries, '', 'all', 'swo').length).toBe(1);
    expect(filterConsoleEntries(entries, 'irq=\\d+', 'all', 'all', true).length).toBe(1);
    expect(compileConsoleSearch('[unterminated', true).regexError).not.toBeNull();

    const copied = formatConsoleCopyText(entries, 'ascii', 'elapsed');
    expect(copied).toContain('[UART CH8 RX] boot ok');
    expect(copied).toContain('[SWO CH10 RX] [swo] irq=12');

    const stats = computeConsoleByteStats(entries);
    expect(stats).toEqual({ rxCount: 2, txCount: 1, rxBytes: 19, txBytes: 8 });
  });
});
