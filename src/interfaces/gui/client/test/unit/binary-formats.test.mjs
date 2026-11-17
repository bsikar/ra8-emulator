import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import {
  BoardProfileError,
  OFFICIAL_BOARD_PRESETS,
  SHIPPED_PANELS,
  crc32,
  detectElfDwarfSections,
  findBoardPreset,
  inspectElf,
  isGzipBuffer,
  parseBoardProfile,
  parseElfSymbols,
  parseUstarEntries,
  previewBundleArchive,
  serializeBoardProfile,
} from "../../dist/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../../../../..");

function buildSyntheticArmElf() {
  const shstr = "\0.shstrtab\0.symtab\0.strtab\0.debug_info\0";
  const strtab = "\0main\0sensor_buf\0$t\0";
  const enc = new TextEncoder();
  const shstrBytes = enc.encode(shstr);
  const strtabBytes = enc.encode(strtab);
  // 2 symbols (main FUNC@0x02000101 size=32, sensor_buf OBJECT@0x22000000 size=16) + $t ignored
  const symtab = new Uint8Array(4 * 16);
  const sv = new DataView(symtab.buffer);
  const writeSym = (idx, nameOff, val, size, type, shndx) => {
    const b = idx * 16;
    sv.setUint32(b, nameOff, true);
    sv.setUint32(b + 4, val, true);
    sv.setUint32(b + 8, size, true);
    symtab[b + 12] = (1 << 4) | type;
    sv.setUint16(b + 14, shndx, true);
  };
  writeSym(1, 1, 0x0200_0101, 32, 2, 1);
  writeSym(2, 6, 0x2200_0000, 16, 1, 1);
  writeSym(3, 17, 0x0200_0120, 4, 2, 1);

  const shstrOff = 52;
  const strOff = shstrOff + shstrBytes.length;
  const symOff = strOff + strtabBytes.length;
  const shOff = symOff + symtab.length;
  const buf = new Uint8Array(shOff + 5 * 40);
  buf.set([0x7f, 0x45, 0x4c, 0x46, 1, 1, 1], 0);
  const dv = new DataView(buf.buffer);
  dv.setUint16(16, 2, true);
  dv.setUint16(18, 40, true); // EM_ARM
  dv.setUint32(20, 1, true);
  dv.setUint32(24, 0x0200_0101, true);
  dv.setUint32(32, shOff, true);
  dv.setUint16(46, 40, true);
  dv.setUint16(48, 5, true);
  dv.setUint16(50, 1, true);
  buf.set(shstrBytes, shstrOff);
  buf.set(strtabBytes, strOff);
  buf.set(symtab, symOff);

  const writeSh = (idx, nameOff, type, off, size, link, entsize) => {
    const b = shOff + idx * 40;
    dv.setUint32(b, nameOff, true);
    dv.setUint32(b + 4, type, true);
    dv.setUint32(b + 16, off, true);
    dv.setUint32(b + 20, size, true);
    dv.setUint32(b + 24, link, true);
    dv.setUint32(b + 36, entsize, true);
  };
  writeSh(1, 1, 3, shstrOff, shstrBytes.length, 0, 0);
  writeSh(2, 11, 2, symOff, symtab.length, 3, 16);
  writeSh(3, 19, 3, strOff, strtabBytes.length, 0, 0);
  writeSh(4, 27, 1, shstrOff, 0, 0, 0);
  return buf;
}

function buildUstarEntry(name, bodyBytes, typeflag = 0x30) {
  const blockLen = Math.ceil(bodyBytes.length / 512) * 512;
  const out = new Uint8Array(512 + blockLen);
  const enc = new TextEncoder();
  out.set(enc.encode(name), 0);
  out.set(enc.encode("0000644\0"), 100);
  out.set(enc.encode(bodyBytes.length.toString(8).padStart(11, "0") + "\0"), 124);
  out.fill(0x20, 148, 156);
  out[156] = typeflag;
  out.set(enc.encode("ustar\0"), 257);
  out.set(enc.encode("00"), 263);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += out[i];
  out.set(enc.encode(sum.toString(8).padStart(6, "0") + "\0 "), 148);
  out.set(bodyBytes, 512);
  return out;
}

function registerElfAndUstarTests(t) {
  t.section("CRC32 & ARM ELF32");
  t.test("crc32 computes IEEE 802.3 vector", () => {
    assert.equal(crc32(new TextEncoder().encode("123456789")), 0xcbf43926);
  });

  t.test("inspectElf & parseElfSymbols extract ARM Thumb entry, DWARF, symbols", () => {
    const elf = buildSyntheticArmElf();
    const info = inspectElf(elf);
    assert.equal(info.valid, true);
    assert.equal(info.machine, 40);
    assert.equal(info.entry, 0x0200_0101);
    assert.equal(info.hasDebugInfo, true);
    assert.equal(detectElfDwarfSections(elf), true);

    const syms = parseElfSymbols(elf);
    assert.deepEqual(
      syms.map((s) => [s.name, s.address, s.kind]),
      [
        ["main", 0x0200_0100, "func"],
        ["sensor_buf", 0x2200_0000, "object"],
      ]
    );
    assert.equal(inspectElf(new Uint8Array(10)).valid, false);
  });
}

async function registerBundlePreviewTests(t) {
  t.section("USTAR / Gzip Bundle Preview");
  await t.testAsync("previewBundleArchive reads .tar and .tar.gz session bundles", async () => {
    const manifestJson = JSON.stringify({
      format: "ra8-session-bundle",
      version: 1,
      snapshot_version: 2,
      board: "ek_ra8d2",
      elf0: { name: "app.elf", identity: "abc123", size: 4096 },
      elf1: null,
      recording: true,
    });
    const e1 = buildUstarEntry("manifest.json", new TextEncoder().encode(manifestJson));
    const e2 = buildUstarEntry("snapshot.bin", new Uint8Array([1, 2, 3, 4]));
    const tar = new Uint8Array(e1.length + e2.length + 1024);
    tar.set(e1, 0);
    tar.set(e2, e1.length);

    assert.equal(isGzipBuffer(tar), false);
    assert.equal(parseUstarEntries(tar).length, 2);

    const gz = new Uint8Array(gzipSync(tar));
    assert.equal(isGzipBuffer(gz), true);
    const preview = await previewBundleArchive(gz);
    assert.equal(preview.compressed, true);
    assert.equal(preview.entries.length, 2);
    assert.equal(preview.manifest?.board, "ek_ra8d2");
    assert.equal(preview.manifest?.snapshotVersion, 2);
    assert.equal(preview.manifest?.recording, true);
  });

  t.test("parseUstarEntries rejects path traversal, bad checksum, and symlinks", () => {
    const trav = buildUstarEntry("../etc/passwd", new Uint8Array(1));
    assert.throws(() => parseUstarEntries(trav), /traversal/i);
    const badSym = buildUstarEntry("link", new Uint8Array(0), 0x32);
    assert.throws(() => parseUstarEntries(badSym), /type/i);
    const badSum = buildUstarEntry("good.bin", new Uint8Array(1));
    badSum[0] ^= 0xff;
    assert.throws(() => parseUstarEntries(badSum), /checksum/i);
  });
}

function registerBoardProfileTests(t) {
  t.section("Board Profile & Presets");
  t.test("parseBoardProfile round-trips src/board/ek_ra8d2.board", () => {
    const boardPath = path.join(REPO_ROOT, "src/board/ek_ra8d2.board");
    const raw = fs.readFileSync(boardPath, "utf8");
    const parsed = parseBoardProfile(raw);
    assert.equal(parsed.version, 1);
    assert.equal(parsed.panel, "ek_ra8d2");
    assert.equal(parsed.leds.length, 3);
    assert.equal(parsed.switches.length, 2);
    assert.deepEqual(parsed.companions, ["c6@uart:sci2"]);
    assert.equal(parsed.memory.ospi.size, 268_435_456);
    assert.equal(parsed.memory.sdram.width, 32);

    const roundTripped = parseBoardProfile(serializeBoardProfile(parsed));
    assert.deepEqual(roundTripped, parsed);
  });

  t.test("official Renesas presets and validation limits", () => {
    assert.equal(OFFICIAL_BOARD_PRESETS.length, 4);
    for (const id of [
      "RTK7EKA8D2S01001BE",
      "RTK7EKA8P1S01001BE",
      "RTK7FPA8E1S00001BE",
      "RTK7FPA4T1S00001BE",
    ]) {
      const preset = findBoardPreset(id);
      assert.ok(preset);
      assert.ok(preset.cores.length >= 1 && preset.cores.length <= 2);
      assert.deepEqual(parseBoardProfile(serializeBoardProfile(preset.profile)), preset.profile);
    }
    assert.equal(SHIPPED_PANELS.ek_ra8d2.width, 1024);
    assert.throws(() => parseBoardProfile("panel=none\n"), (e) => e instanceof BoardProfileError && e.code === "BadVersion");
    assert.throws(
      () => parseBoardProfile("version=1\nled=P101,0x001F,CUSTOM\n"),
      (e) => e instanceof BoardProfileError && e.code === "UntrackedLed"
    );
    const nonStrict = parseBoardProfile("version=1\nled=P101,0x001F,CUSTOM\n", { strictTrackedPads: false });
    assert.equal(nonStrict.leds[0]?.pin, "P101");
    assert.throws(
      () => parseBoardProfile(
        "version=1\n" +
        "sensor=lsm6dso@i2c:riic@0x6a\n" +
        "sensor=max17048@i2c:riic@0x36\n" +
        "sensor=eink@spi:spi0@ssl0\n" +
        "companion=c6@uart:sci2\n" +
        "companion=modem@uart:sci1\n"
      ),
      (e) => e instanceof BoardProfileError && e.code === "TooManyFits"
    );
  });
}

export async function run(t) {
  registerElfAndUstarTests(t);
  await registerBundlePreviewTests(t);
  registerBoardProfileTests(t);
}
