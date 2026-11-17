/**
 * IEEE 802.3 CRC32 matching Zig `std.hash.Crc32.hash`.
 */

const CRC32_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c >>> 0;
  }
  return table;
})();

/** Compute standard IEEE 802.3 CRC32 checksum of `bytes`. */
export function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    const idx = (crc ^ (bytes[i] ?? 0)) & 0xff;
    crc = ((CRC32_TABLE[idx] ?? 0) ^ (crc >>> 8)) >>> 0;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
