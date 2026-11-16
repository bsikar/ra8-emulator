# Current signed A/B boot fixture (RA8EMU-1271)

This fixture executes the current target firmware's software verification and
copy-to-run gate inside the emulator. It does not qualify an immutable ROM/FSBL,
RSIP silicon, provisioning ceremony, or durable anti-rollback storage. The
historical RA8EMU-776 fixture in the parent directory remains unchanged.

## Source and build identity

Firmware source: `ra8-firmware` commit
`506703b68104c4fa630a08ba3c12b457e0da8ef1`, the fetched `origin/dev` on
2026-11-15. The build used a disposable clone; no source or key in the
maintainer's working firmware checkout was changed or consumed. Initial
emulator test baseline: `f776b646`; the final emulator commit and executed test
results belong on RA8EMU-1271 and its PR.

`provenance.json` records full SHA-256 hashes of the original and built boot
entry, ROT verifier, launch gate, signer, CMake recipe and dependency pins. It
also records exact compiler, Zig, CMake, Ninja and OpenSSL versions and
executable hashes. `sha256.json` pins the committed ELF, bodies, signatures,
public keys, reproduction script and test build patch.

The target uses Arm GNU 13.3.Rel1 (`13.3.1 20240614`), CMake `MinSizeRel`, and
the firmware's CMake-selected Zig `ReleaseSmall` archives, with the genuine
TF-PSA-Crypto ECDSA-P256 backend. Only `--strip-debug` was applied to the ELF;
function symbols remain available for the verification gate probes. No fake
crypto, off-target backend, or verifier result substitution is used.

`test-build.patch` contains the complete disposable build delta:

1. Replace only `root_public_key`'s 65 public bytes in
   `libs/ra8_rot/src/rot_abi.zig` with the TEST identity below. The original
   source comment's provisioned-key fingerprint describes the original
   firmware, not this intentionally substituted test identity.
2. Select the documented `NO_NSC` application option. Current standalone DFU
   CMake otherwise refuses source collection because the implicit NSC path
   has not registered the migrated Zig archive. This Secure-only application
   needs no unrelated NSC veneer objects.
3. Link the GCC runtime after `tfpsa_dfu` to satisfy that library's actual
   `__aeabi_uldivmod` reference. The stock standalone link otherwise fails.

Neither build adjustment changes slot selection, launch, ROT parsing,
SHA-256, ECDSA verification, or anti-rollback policy. These are qualification
fixtures with an explicit test build delta, not a claim that the unmodified
standalone firmware CMake entry currently builds without repair.

## Disposable identities and signed images

The two private scalars are derived from public ASCII test labels by SHA-256:
`RA8EMU-1271-TEST-root` and `RA8EMU-1271-TEST-wrong-root`. They are deliberately
reconstructible TEST material, never production secrets or identities. The
reproducer creates temporary EC key files, signs only these fixture bodies,
and deletes the private files on exit. It never invokes the provisioning
ceremony or opens a personal signing key.

The embedded, uncompressed SEC1 `0x04 || X || Y` public key is
`root-public.bin` (65 bytes), SHA-256:
`948d34b43f468430ae5d050356e9ef4f2aae976cd33d33deba6eab4d039470e6`.
The different signer is `wrong-root-public.bin`, SHA-256:
`42e2cee1c85acee93cf82240691f42fa605a35510a13353e6a9bef5b9d2ab71b`.

The firmware's pinned `scripts/secrets/rot_sign.py` signs
`SHA256(img_version_le || SHA256(body))` with ECDSA-P256. Each 32-byte body is
followed by its 116-byte ROT1 trailer. A uses signed image version 1; B uses
version 2. `wrong_root_b.bin` has a valid signature from the different test
root over B's unchanged body and version. OpenSSL ECDSA signatures use fresh
nonces, so reproduction produces fresh valid signature bytes; the committed
bytes have their own exact hashes in `sha256.json`.

Both payloads have SP `0x22060000` and a Thumb reset vector into the SRAM run
base `0x22020000`. Their first store writes a distinct launch marker to
`0x22180000`: A writes `0x9710C0A1`, B writes `0x9710C0B2`. A heartbeat follows.
The test body mutation changes a later heartbeat instruction, so even a
mistakenly launched tampered body would still write its launch marker.

## Actual firmware policy and test oracle

The current boot entry first selects a slot by header/length/CRC and outer
sequence. Only that selected slot is passed to the authenticated launch gate.
A failed authentication returns to `main`, which enters DFU; it does not retry
the older authentic slot. The test explicitly pins this fail-closed recovery
policy for a newer CRC-valid, authentication-invalid B beside authentic A.
A debugger's CRC-only `boot_slots.Report` is asserted as a precondition and
never used as evidence of authentication.

The tests place a breakpoint at the real `ra8_rot_verify_image` entry, assert
its body length and selected slot, then break at its actual LR return address
to capture the firmware's return code in R0. They continue the real caller to
the distinct payload marker or the firmware's
`no bootable slot -- entering DFU` console message. Negative cases require no
payload marker, a verifier refusal, and the firmware's deterministic DFU path.
An explicit DFU trigger requires that the verifier is never entered.

Required matrix (`tests/session/boot_auth_test.zig`):

| Input | Firmware result / terminal observation |
| --- | --- |
| Authentic A selected; authentic B selected | Gate 0; distinct A/B launch marker; no DFU |
| Body changed, outer CRC recomputed (A and B) | Gate `0x502` body digest mismatch; DFU |
| ECDSA signature bit changed (A and B) | Gate `0x405`; DFU |
| Signature from the different root (A and B) | Gate `0x405`; DFU |
| Signed image version changed without re-signing | Gate `0x405`; DFU |
| Bad ROT1 magic or format version | Gate `0x501`; DFU |
| Trailer body length mismatch or signature length 65 | Gate `0x105`; DFU |
| Only the first 84 of 116 trailer bytes staged | Gate `0x405`; DFU |
| Neither slot authentic | Gate refuses selected B; DFU |
| Explicit one-shot DFU trigger with authentic slots | Gate not entered; DFU |

The truncated-tail case writes a short trailer into a fresh, zero-initialized,
fully mapped MRAM slot. The remaining bytes are unwritten zero padding, not a
memory-access exception. No partial trailer may launch; the firmware sees the
advertised signature length and rejects its incomplete signature. This does
not claim that the target API, which receives a mapped trailer pointer rather
than a byte-stream length, can distinguish every missing tail from malformed
padding. All staged negative cases retain valid outer body CRCs.

`0x405` is the pinned PSA facade's mapping of
`PSA_ERROR_INVALID_SIGNATURE`; it is not a claim that authentication consists
of a CRC check. The other error values come from the pinned ROT ABI.

## Reproduction and execution

Start with a clean disposable firmware clone at the pinned commit, with Zig,
CMake, Ninja, OpenSSL and the pinned Arm GNU 13.3 toolchain installed:

```sh
git clone --no-checkout git@github.com:bsikar/ra8-firmware.git /tmp/firmware-test
git -C /tmp/firmware-test checkout --detach 506703b68104c4fa630a08ba3c12b457e0da8ef1
python3 tests/fixtures/dfu/current/rebuild.py /tmp/firmware-test /tmp/firmware-test-build
zig build ra8_tests-exe -j1 -Doptimize=ReleaseFast -Dtest-filter=session.boot_auth_test --prefix /tmp/signed-boot-tests
bash tools/test_batch.sh /tmp/signed-boot-tests/bin/ra8_tests /tmp/signed-boot-tests.log
```

The script refuses a dirty firmware checkout and modifies only its supplied
clone. It uses the official current app CMake entry and the patch above. Its
successful outputs regenerate the manifests and fixtures.

These integration cases intentionally skip non-ReleaseFast builds because
real target ECDSA execution is expensive in the interpreter. The explicit
ReleaseFast CI step and direct batched command above are required evidence;
a skipped Debug case is not a passing qualification result. No hardware test
was performed by this matrix.
