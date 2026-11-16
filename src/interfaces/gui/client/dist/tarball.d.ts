/**
 * POSIX USTAR + Gzip (.tar.gz) serializer/deserializer for portable
 * deterministic time-travel bundles across browser and Node.js runtimes.
 */
import type { TimeTravelArchiveBundle } from "./types.js";
/** Export a deterministic time-travel manifest + snapshots into a `.tar.gz` byte buffer */
export declare function exportTimeTravelTarball(bundle: TimeTravelArchiveBundle): Promise<Uint8Array>;
/** Parse and validate a time-travel `.tar.gz` archive produced by exportTimeTravelTarball */
export declare function importTimeTravelTarball(tarGzBytes: Uint8Array): Promise<TimeTravelArchiveBundle>;
//# sourceMappingURL=tarball.d.ts.map