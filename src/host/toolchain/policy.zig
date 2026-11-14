//! Versioned distribution decision, consumed by the CLI and future provisioning.
pub const version: u32 = 1;
pub const decision = .{
    .default_install = "backend plus setup-provisioned, verified, immutable Zig cache; no compiler embedded in backend executable",
    .offline_install = "planned offline kit must carry the same pinned complete compiler archive and every project dependency; offline execution must forbid implicit fetching (enforcement belongs to provisioning)",
    .bundled_tradeoff = "complete Zig archive permits first build offline at higher download/disk cost; keep its library tree and all license/third-party notices",
    .managed_tradeoff = "smaller app distribution; online setup required for an empty cache; archive size/hash verified before safe extraction and activation",
    .explicit_tradeoff = "supports user/vendor toolchains without repackaging; exact executable/version/digest must be recorded and compatibility remains project-specific",
    .precedence = "explicit project override, explicit backend override, verified pinned managed cache; never ambient PATH or fallback after an invalid explicit override",
    .cache_owner = "backend service user on the execution host; per-user by default, never writable by unrelated clients; no workspace-owned tool cache",
    .cache_layout = "<cache-root>/zig/0.17.0/<host>/<archive-sha256>/<archive-directory>/zig[.exe]",
    .cache_integrity = "1286 must record and verify installed file hashes/permissions, not trust a directory name, version string or marker alone",
    .activation = "stage exclusive candidate, verify archive and extracted tree, test version/build, atomically activate; failed setup leaves previous generation selected",
    .updates = "explicit pinned manifest update, never latest; retain previous verified generation for rollback; do not mutate or delete in-use generations",
    .runtime = "backend executable is a separate signed/checksummed release artifact; Zig is a compiler plus lib tree, not an installed runtime for the backend",
    .debug = "Session/DAP require no external GDB executable; real GDB client and hardware probe server are separate optional/user-installed tools",
    .vendor = "no automatic vendor SDK, driver, probe or model-tool redistribution; require target pins, hashes, licenses and validation before managed eligibility",
    .offline = "works only after compiler tree, project/build dependencies, SDK/startup/linker files, debug/flash tools, drivers and model inputs required for that operation are present and verified",
    .remote = "resolve tools/cache on build host; probe tools/drivers on probe host; phone/PWA is a client and needs no compiler; physical USB access and reservation remain separate gates",
    .provisioning = "decision/plan only; automatic fetching, extraction, cache activation and doctor checks belong to RA8EMU-1286",
};
