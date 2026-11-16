/**
 * POSIX USTAR + Gzip (.tar.gz) serializer/deserializer for portable
 * deterministic time-travel bundles across browser and Node.js runtimes.
 */
const TAR_BLOCK = 512;
function assertSafeArchivePath(entryPath) {
    const normalized = entryPath.trim();
    if (!normalized ||
        normalized.startsWith("/") ||
        normalized.startsWith("\\") ||
        normalized.includes("\0") ||
        normalized.includes("\\")) {
        throw new Error(`Unsafe archive entry path: ${entryPath}`);
    }
    const parts = normalized.split("/");
    if (parts.some((p) => p === "" || p === "." || p === "..")) {
        throw new Error(`Unsafe archive path traversal in entry: ${entryPath}`);
    }
    return normalized;
}
function writeOctalField(buf, offset, length, value) {
    const digits = Math.max(0, Math.floor(value))
        .toString(8)
        .padStart(length - 1, "0");
    if (digits.length > length - 1) {
        throw new Error(`Octal value overflow for TAR header field: ${value}`);
    }
    const encoded = new TextEncoder().encode(digits);
    buf.set(encoded, offset);
    buf[offset + length - 1] = 0;
}
function buildUstarEntry(name, data) {
    const safeName = assertSafeArchivePath(name);
    const nameBytes = new TextEncoder().encode(safeName);
    if (nameBytes.length > 100) {
        throw new Error(`TAR entry name exceeds 100 bytes: ${safeName}`);
    }
    const paddedDataLen = Math.ceil(data.length / TAR_BLOCK) * TAR_BLOCK;
    const out = new Uint8Array(TAR_BLOCK + paddedDataLen);
    out.set(nameBytes, 0);
    writeOctalField(out, 100, 8, 0o644);
    writeOctalField(out, 108, 8, 0);
    writeOctalField(out, 116, 8, 0);
    writeOctalField(out, 124, 12, data.length);
    writeOctalField(out, 136, 12, Math.floor(Date.now() / 1000));
    for (let i = 148; i < 156; i++) {
        out[i] = 0x20;
    }
    out[156] = 0x30; // '0' regular file
    out.set(new TextEncoder().encode("ustar\0"), 257);
    out.set(new TextEncoder().encode("00"), 263);
    let sum = 0;
    for (let i = 0; i < TAR_BLOCK; i++) {
        sum += out[i] ?? 0;
    }
    const chkStr = sum.toString(8).padStart(6, "0") + "\0 ";
    out.set(new TextEncoder().encode(chkStr), 148);
    out.set(data, TAR_BLOCK);
    return out;
}
function readCString(buf, offset, maxLen) {
    let end = offset;
    const limit = Math.min(buf.length, offset + maxLen);
    while (end < limit && buf[end] !== 0) {
        end++;
    }
    return new TextDecoder().decode(buf.subarray(offset, end));
}
function isZeroBlock(buf, offset) {
    for (let i = 0; i < TAR_BLOCK; i++) {
        if ((buf[offset + i] ?? 0) !== 0)
            return false;
    }
    return true;
}
function verifyUstarChecksum(header) {
    const raw = readCString(header, 148, 8).trim();
    const expected = Number.parseInt(raw, 8);
    if (!Number.isFinite(expected)) {
        throw new Error("Invalid TAR header checksum");
    }
    let actual = 0;
    for (let i = 0; i < TAR_BLOCK; i++) {
        actual += i >= 148 && i < 156 ? 0x20 : (header[i] ?? 0);
    }
    if (actual !== expected) {
        throw new Error(`Corrupt TAR header checksum (expected ${expected}, got ${actual})`);
    }
}
async function gzipCompress(raw) {
    const copy = new Uint8Array(raw.byteLength);
    copy.set(raw);
    const stream = new Blob([copy]).stream().pipeThrough(new CompressionStream("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}
async function gzipDecompress(gz) {
    const copy = new Uint8Array(gz.byteLength);
    copy.set(gz);
    const stream = new Blob([copy]).stream().pipeThrough(new DecompressionStream("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}
/** Export a deterministic time-travel manifest + snapshots into a `.tar.gz` byte buffer */
export async function exportTimeTravelTarball(bundle) {
    const serialized = {
        version: 1,
        exportedAtIso: bundle.manifest.exportedAtIso,
        boardName: bundle.manifest.boardName,
        boardSpec: bundle.manifest.boardSpec,
        activeBranchId: bundle.manifest.activeBranchId,
        branches: bundle.manifest.branches.map((b) => ({
            ...b,
            forkR: b.forkR.toString(),
        })),
        checkpoints: bundle.manifest.checkpoints.map((c) => ({
            ...c,
            round: c.round.toString(),
            virtualNs: c.virtualNs.toString(),
        })),
    };
    const parts = [
        buildUstarEntry("manifest.json", new TextEncoder().encode(JSON.stringify(serialized, null, 2))),
    ];
    const snapNames = Object.keys(bundle.snapshots).sort();
    for (const bareName of snapNames) {
        const safeBare = assertSafeArchivePath(bareName);
        if (safeBare.includes("/")) {
            throw new Error(`Snapshot filename must be a bare name: ${bareName}`);
        }
        const payload = bundle.snapshots[bareName];
        if (payload) {
            parts.push(buildUstarEntry(`snapshots/${safeBare}`, payload));
        }
    }
    parts.push(new Uint8Array(TAR_BLOCK * 2));
    const total = parts.reduce((acc, p) => acc + p.length, 0);
    const tar = new Uint8Array(total);
    let off = 0;
    for (const part of parts) {
        tar.set(part, off);
        off += part.length;
    }
    return gzipCompress(tar);
}
/** Parse and validate a time-travel `.tar.gz` archive produced by exportTimeTravelTarball */
export async function importTimeTravelTarball(tarGzBytes) {
    const tar = await gzipDecompress(tarGzBytes);
    const entries = new Map();
    let offset = 0;
    while (offset + TAR_BLOCK <= tar.length) {
        if (isZeroBlock(tar, offset)) {
            break;
        }
        const header = tar.subarray(offset, offset + TAR_BLOCK);
        verifyUstarChecksum(header);
        const namePart = readCString(header, 0, 100);
        const prefixPart = readCString(header, 345, 155);
        const fullName = prefixPart ? `${prefixPart}/${namePart}` : namePart;
        const safePath = assertSafeArchivePath(fullName);
        const sizeOctal = readCString(header, 124, 12).trim();
        const size = Number.parseInt(sizeOctal || "0", 8);
        if (!Number.isFinite(size) || size < 0) {
            throw new Error(`Invalid TAR entry size for ${safePath}`);
        }
        const dataStart = offset + TAR_BLOCK;
        if (dataStart + size > tar.length) {
            throw new Error(`Truncated TAR entry payload for ${safePath}`);
        }
        entries.set(safePath, tar.slice(dataStart, dataStart + size));
        const blocks = Math.ceil(size / TAR_BLOCK);
        offset = dataStart + blocks * TAR_BLOCK;
    }
    const manifestRaw = entries.get("manifest.json");
    if (!manifestRaw) {
        throw new Error("Missing manifest.json in time-travel archive");
    }
    const parsed = JSON.parse(new TextDecoder().decode(manifestRaw));
    if (parsed.version !== 1) {
        throw new Error(`Unsupported time-travel archive version: ${String(parsed.version)}`);
    }
    const branches = parsed.branches.map((b) => ({
        ...b,
        forkR: BigInt(b.forkR),
    }));
    const checkpoints = parsed.checkpoints.map((c) => ({
        ...c,
        round: BigInt(c.round),
        virtualNs: BigInt(c.virtualNs),
    }));
    const manifest = {
        version: 1,
        exportedAtIso: parsed.exportedAtIso,
        boardName: parsed.boardName,
        boardSpec: parsed.boardSpec,
        activeBranchId: parsed.activeBranchId,
        branches,
        checkpoints,
    };
    const snapshots = {};
    for (const [entryPath, payload] of entries.entries()) {
        if (entryPath.startsWith("snapshots/")) {
            const bareName = entryPath.slice("snapshots/".length);
            assertSafeArchivePath(bareName);
            snapshots[bareName] = payload;
        }
    }
    return { manifest, snapshots };
}
//# sourceMappingURL=tarball.js.map