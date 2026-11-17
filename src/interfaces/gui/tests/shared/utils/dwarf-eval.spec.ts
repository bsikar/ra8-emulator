import { LocalWhereKind, type LocalVariable } from 'ra8-rpc-client';
import { evaluateLocals } from '../../../src/app/shared/utils/dwarf-eval';

function u32le(val: number): Uint8Array {
  const buf = new Uint8Array(4);
  new DataView(buf.buffer).setUint32(0, val >>> 0, true);
  return buf;
}

describe('dwarf-eval', () => {
  it('evaluates register locals and batches memory reads concurrently via Promise.all', async () => {
    let activeCalls = 0;
    let peakConcurrent = 0;
    const readMem = async (addr: number): Promise<Uint8Array | null> => {
      activeCalls += 1;
      peakConcurrent = Math.max(peakConcurrent, activeCalls);
      await Promise.resolve();
      activeCalls -= 1;
      if (addr === 0x2000_0100) return u32le(42);
      if (addr === 0x2000_01f8) return u32le(-7);
      if (addr === 0x2000_0304) return u32le(0xdead_beef);
      return null;
    };

    const locals: LocalVariable[] = [
      { name: 'arg0', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.InRegister, whereA: 0n, whereB: 0n },
      { name: 'global_n', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.Address, whereA: 0x2000_0100n, whereB: 0n },
      { name: 'delta', typeName: 'int32_t', size: 4, whereKind: LocalWhereKind.Frame, whereA: -8n, whereB: 0n },
      { name: 'field', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.RegisterIndirect, whereA: 4n, whereB: 4n },
    ];

    const out = await evaluateLocals(locals, { r0: 9, sp: 0x2000_0200, r4: 0x2000_0300 }, readMem);
    expect(peakConcurrent).toBe(3);
    expect(out[0]?.valueDec).toBe('9');
    expect(out[1]?.valueDec).toBe('42');
    expect(out[2]?.valueDec).toBe('-7');
    expect(out[3]?.valueHex).toBe('0xdeadbeef');
  });

  it('uses explicit frameBase for unwound frames and avoids frame-0 sp fallback when absent', async () => {
    const locals: LocalVariable[] = [
      { name: 'outer_var', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.Frame, whereA: -4n, whereB: 0n },
      { name: 'reg_var', typeName: 'uint32_t', size: 4, whereKind: LocalWhereKind.InRegister, whereA: 1n, whereB: 0n },
    ];

    const missingBase = await evaluateLocals(
      locals,
      { sp: 0x2000_0100, r1: 77 },
      async () => u32le(123),
      { frameIndex: 1 }
    );
    expect(missingBase[0]?.valueHex).toBe('—');
    expect(missingBase[1]?.locationLabel).toContain('unwound');

    const withBase = await evaluateLocals(
      locals,
      { sp: 0x2000_0100, r1: 77 },
      async (addr) => (addr === 0x2000_04fc ? u32le(999) : null),
      { frameIndex: 1, frameBase: 0x2000_0500 }
    );
    expect(withBase[0]?.valueDec).toBe('999');
  });
});
