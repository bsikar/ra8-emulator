/**
 * @file test_emu_mve_vmov.c
 * @brief Encoding contract for the hand-decoded VMOV.I32 Qd, #imm seam
 * @details The MVE immediate form used to be decoded through capstone with
 * CS_OPT_DETAIL, which put an unpinned library on the emulation path: its
 * operands drove the emulated register writes, so its version could change a
 * run's verdict. The decode is now taken from the raw encoding, and this test
 * is what holds it to the instruction set: every accepted vector below was
 * cross-checked against capstone 5.0.7, and every rejected one names a
 * neighbouring encoding that must be left to fault rather than executed as a
 * VMOV.
 *
 * @copyright Copyright (c) 2026 Brighton Sikarskie
 * SPDX-License-Identifier: MIT
 * @since 0.1.0
 */

#include <stdio.h>

/* White-box: the decoder is module-private, so the translation unit under test
 * is compiled into this binary directly. */
#include "emu_seam_mve.c"

/** @brief One encoding the seam must decode, with the fields it must produce. */
typedef struct {
  uint16_t hw1;   /**< First instruction halfword.        */
  uint16_t hw2;   /**< Second instruction halfword.       */
  uint32_t qd;    /**< Expected destination Q register.   */
  uint32_t imm32; /**< Expected 32-bit lane value.        */
} vmov_accept_t;

/** @brief One encoding the seam must refuse, so it faults instead of running. */
typedef struct {
  uint16_t hw1; /**< First instruction halfword.  */
  uint16_t hw2; /**< Second instruction halfword. */
} vmov_reject_t;

/**
 * @brief Check every accepted encoding decodes to the documented fields.
 * @details Check every accepted encoding decodes to the documented fields; this step is contained within the test and uses bounded caller or module-owned storage.
 * @return Zero on success, else the failing source line.
 * @retval 0 Every vector decoded to its expected register and immediate.
 * @pre None. @pre The call executes on the test's single owning thread.
 * @post No emulated state is touched; decode is pure. @post Ownership of caller-supplied storage is unchanged.
 * @note The operation is synchronous and does not transfer heap ownership.
 * @since 0.1.0
 */
static int test_accepts(void)
{
  static const vmov_accept_t k_vectors[] = {
    {0xEF80U, 0x0050U, 0U, 0x00000000U}, /* vmov.i32 q0, #0 */
    {0xFF87U, 0x005FU, 0U, 0x000000FFU}, /* vmov.i32 q0, #0xff */
    {0xEF85U, 0x205AU, 1U, 0x0000005AU}, /* vmov.i32 q1, #0x5a */
    {0xFF82U, 0x625BU, 3U, 0x0000AB00U}, /* vmov.i32 q3, #0xab00 */
    {0xEF80U, 0xA451U, 5U, 0x00010000U}, /* vmov.i32 q5, #0x10000 */
    {0xFF80U, 0xE650U, 7U, 0x80000000U}, /* vmov.i32 q7, #0x80000000 */
    {0xEF81U, 0x4C52U, 2U, 0x000012FFU}, /* vmov.i32 q2, #0x12ff */
    {0xEF83U, 0xCD54U, 6U, 0x0034FFFFU}, /* vmov.i32 q6, #0x34ffff */
  };
  for (size_t idx = 0U; idx < (sizeof(k_vectors) / sizeof(k_vectors[0])); idx++) {
    uint32_t qd  = 0xFFFFFFFFU;
    uint32_t imm = 0xFFFFFFFFU;
    if (!internal_mve_vmov_decode(k_vectors[idx].hw1, k_vectors[idx].hw2, &qd, &imm)) {
      (void)fprintf(stderr, "vector %zu: refused a valid vmov.i32\n", idx);
      return __LINE__;
    }
    if ((qd != k_vectors[idx].qd) || (imm != k_vectors[idx].imm32)) {
      (void)fprintf(stderr, "vector %zu: got q%u #0x%08X, want q%u #0x%08X\n", idx, qd, imm,
                    k_vectors[idx].qd, k_vectors[idx].imm32);
      return __LINE__;
    }
  }
  return 0;
}

/**
 * @brief Check every neighbouring encoding is refused.
 * @details Check every neighbouring encoding is refused; this step is contained within the test and uses bounded caller or module-owned storage.
 * @return Zero on success, else the failing source line.
 * @retval 0 Every vector was refused and left to the invalid-instruction path.
 * @pre None. @pre The call executes on the test's single owning thread.
 * @post No emulated state is touched; decode is pure. @post Ownership of caller-supplied storage is unchanged.
 * @note The operation is synchronous and does not transfer heap ownership.
 * @since 0.1.0
 */
static int test_rejects(void)
{
  static const vmov_reject_t k_vectors[] = {
    {0xEFC1U, 0x0052U}, /* D set: capstone renders q8, a register MVE does not have */
    {0xEF81U, 0x1052U}, /* odd Vd: no vector form encodes it */
    {0xEF81U, 0x0852U}, /* cmode 0b1000 is the .i16 form, a lane width this seam does not emulate */
    {0xEF81U, 0x0072U}, /* op == 1 is vmvn.i32, not vmov */
    {0xEF81U, 0x0012U}, /* Q == 0 is the 64-bit vmov.i32 d0 form */
    {0xED80U, 0x7F31U}, /* vstrw.32 q3, [r0, #196]: the contiguous family, decoded elsewhere */
  };
  for (size_t idx = 0U; idx < (sizeof(k_vectors) / sizeof(k_vectors[0])); idx++) {
    uint32_t qd  = 0U;
    uint32_t imm = 0U;
    if (internal_mve_vmov_decode(k_vectors[idx].hw1, k_vectors[idx].hw2, &qd, &imm)) {
      (void)fprintf(stderr, "vector %zu: decoded an encoding that is not vmov.i32 Qd,#imm\n", idx);
      return __LINE__;
    }
  }
  return 0;
}

/**
 * @brief Run the encoding contract.
 * @details Run the encoding contract; this step is contained within the test and uses bounded caller or module-owned storage.
 * @return Zero when both halves pass, else the failing source line.
 * @retval 0 The decoder matches the instruction set on every vector.
 * @pre None. @pre The call executes on the test's single owning thread.
 * @post No emulated state is touched. @post Ownership of caller-supplied storage is unchanged.
 * @note The operation is synchronous and does not transfer heap ownership.
 * @since 0.1.0
 */
int main(void)
{
  const int accepts = test_accepts();
  if (accepts != 0) {
    return accepts;
  }
  const int rejects = test_rejects();
  if (rejects != 0) {
    return rejects;
  }
  (void)printf("test_emu_mve_vmov: ok\n");
  return 0;
}
