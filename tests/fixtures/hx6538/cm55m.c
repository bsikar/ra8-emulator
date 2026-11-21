#include <stdint.h>

#define SCB_CPUID        (*(volatile uint32_t *)0xE000ED00U)
#define SCB_SHCSR        (*(volatile uint32_t *)0xE000ED24U)
#define SCB_CFSR         (*(volatile uint32_t *)0xE000ED28U)
#define SCB_BFAR         (*(volatile uint32_t *)0xE000ED38U)
#define SCB_CPACR        (*(volatile uint32_t *)0xE000ED88U)
#define MPU_TYPE         (*(volatile uint32_t *)0xE000ED90U)
#define SAU_CTRL         (*(volatile uint32_t *)0xE000EDD0U)
#define SAU_TYPE         (*(volatile uint32_t *)0xE000EDD4U)
#define DWT_CTRL         (*(volatile uint32_t *)0xE0001000U)
#define FP_CTRL          (*(volatile uint32_t *)0xE0002000U)
#define NVIC_ISER0       (*(volatile uint32_t *)0xE000E100U)
#define NVIC_ISER1       (*(volatile uint32_t *)0xE000E104U)

#define SCU_CM55S_STATE      (*(volatile uint32_t *)0x56100210U)
#define SCU_CM55S_INITSVTOR  (*(volatile uint32_t *)0x56100D00U)
#define SCU_CM55S_CPUWAIT    (*(volatile uint32_t *)0x56100D08U)

#define MBOX_M_STATUS    (*(volatile uint32_t *)0x5400A000U)
#define MBOX_M_CLR       (*(volatile uint32_t *)0x5400A008U)
#define MBOX_S_TRIG      (*(volatile uint32_t *)0x5400A014U)
#define MBOX_SHARE(n)    (*(volatile uint32_t *)(0x5400A100U + ((uint32_t)(n) * 4U)))
#define MBOX_MUTEX(n)    (*(volatile uint32_t *)(0x5400A200U + ((uint32_t)(n) * 4U)))

#define UART0_RBR_THR    (*(volatile uint32_t *)0x54003000U)
#define UART0_IER_DLH    (*(volatile uint32_t *)0x54003004U)
#define UART0_FCR        (*(volatile uint32_t *)0x54003008U)
#define UART0_LCR        (*(volatile uint32_t *)0x5400300CU)
#define UART0_LSR        (*(volatile uint32_t *)0x54003014U)
#define UART0_CPR        (*(volatile uint32_t *)0x540030F4U)

#define TIMER0_CTRL      (*(volatile uint32_t *)0x5500A000U)
#define TIMER0_VALUE     (*(volatile uint32_t *)0x5500A004U)
#define TIMER0_RELOAD    (*(volatile uint32_t *)0x5500A008U)
#define TIMER0_INTCLEAR  (*(volatile uint32_t *)0x5500A00CU)

#define SHARED_BASE      0x34080000U
#define SHARED_NS_BASE   0x24080000U
#define U55_BASE_ADDR    0x53020000U

typedef struct {
    volatile uint32_t magic;
    volatile uint32_t cm55m_cpuid;
    volatile uint32_t cm55s_cpuid;
    volatile uint32_t cm55m_dwt_fpb;
    volatile uint32_t cm55s_boot_seq;
    volatile uint32_t timer0_irqs;
    volatile uint32_t cm55m_mbox_irqs;
    volatile uint32_t cm55s_mbox_irqs;
    volatile uint32_t u55_bus_faults;
    volatile uint32_t u55_bfar;
    volatile uint32_t pac_usage_faults;
    volatile uint32_t mve_lob_sum;
    volatile uint32_t tt_flags;
    volatile uint32_t excl_counter;
    volatile uint32_t cm55s_loop_ticks;
    volatile uint32_t status;
} HxSharedState;

static HxSharedState *const shared = (HxSharedState *)SHARED_BASE;
static HxSharedState *const shared_ns = (HxSharedState *)SHARED_NS_BASE;

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;

void Reset_Handler(void);
void Default_Handler(void);
void BusFault_Handler(void);
void UsageFault_Handler(void);
void Mailbox_Handler(void);
void Timer0_Handler(void);
void hx_done_park(void);

__attribute__((section(".isr_vector"), used))
const uint32_t vector_table[56] = {
    (uint32_t)&_estack,
    (uint32_t)Reset_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)BusFault_Handler,
    (uint32_t)UsageFault_Handler,
    (uint32_t)Default_Handler,
    0, 0, 0,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    0,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    [16 + 7]  = (uint32_t)Mailbox_Handler,
    [16 + 34] = (uint32_t)Timer0_Handler,
};

static void uart0_init(void) {
    UART0_LCR = 0x83U;
    UART0_RBR_THR = 13U;
    UART0_IER_DLH = 0U;
    UART0_LCR = 0x03U;
    UART0_FCR = 0x07U;
}

static void uart0_puts(const char *s) {
    while (*s != '\0') {
        while ((UART0_LSR & 0x20U) == 0U) {}
        UART0_RBR_THR = (uint32_t)(uint8_t)(*s++);
    }
}

__attribute__((naked)) static void probe_bus_fault_read(uint32_t addr) {
    (void)addr;
    __asm volatile(
        ".syntax unified\n"
        ".thumb\n"
        ".inst.n 0x6800\n" /* 16-bit ldr r0, [r0, #0] */
        "bx lr\n"
    );
}

__attribute__((naked)) static void probe_pacbti_mrs(void) {
    __asm volatile(
        ".syntax unified\n"
        ".thumb\n"
        ".inst.n 0xF3EF\n"
        ".inst.n 0x8020\n" /* 32-bit mrs r0, pac_key_p_0 */
        "bx lr\n"
    );
}

static uint32_t tt_query(uint32_t addr) {
    uint32_t res;
    __asm volatile("tt %0, %1" : "=r"(res) : "r"(addr));
    return res;
}

static uint32_t mve_lob_kernel(void) {
    uint32_t acc = 0U;
    uint32_t vec_a[4] = { 10U, 20U, 30U, 40U };
    uint32_t vec_b[4] = { 1U, 2U, 3U, 4U };
    __asm volatile(
        "vldrw.u32 q0, [%[a]]\n"
        "vldrw.u32 q1, [%[b]]\n"
        "vadd.i32 q2, q0, q1\n"
        "vstrw.32 q2, [%[a]]\n"
        :
        : [a] "r"(vec_a), [b] "r"(vec_b)
        : "q0", "q1", "q2", "memory"
    );
    for (uint32_t i = 0U; i < 4U; i++) {
        acc += vec_a[i];
    }
    return acc; /* 11+22+33+44 = 110 */
}

static void atomic_inc(volatile uint32_t *ptr) {
    uint32_t val;
    uint32_t fail;
    do {
        __asm volatile("ldrex %0, [%1]" : "=r"(val) : "r"(ptr));
        val += 1U;
        __asm volatile("strex %0, %1, [%2]" : "=&r"(fail) : "r"(val), "r"(ptr) : "memory");
    } while (fail != 0U);
}

void BusFault_Handler_C(uint32_t *frame) {
    uint32_t cfsr = SCB_CFSR;
    if ((cfsr & (1U << 15)) != 0U) {
        shared->u55_bfar = SCB_BFAR;
    }
    shared->u55_bus_faults += 1U;
    SCB_CFSR = cfsr;
    frame[6] += 2U;
}

void UsageFault_Handler_C(uint32_t *frame) {
    uint32_t cfsr = SCB_CFSR;
    if ((cfsr & (1U << 16)) != 0U) {
        shared->pac_usage_faults += 1U;
    }
    SCB_CFSR = cfsr;
    frame[6] += 4U;
}

__attribute__((naked)) void BusFault_Handler(void) {
    __asm volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "b BusFault_Handler_C\n"
    );
}

__attribute__((naked)) void UsageFault_Handler(void) {
    __asm volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "b UsageFault_Handler_C\n"
    );
}

void Timer0_Handler(void) {
    TIMER0_INTCLEAR = 1U;
    shared->timer0_irqs += 1U;
}

void Mailbox_Handler(void) {
    uint32_t status = MBOX_M_STATUS;
    MBOX_M_CLR = status;
    shared->cm55m_mbox_irqs += 1U;
}

__attribute__((noinline)) void hx_done_park(void) {
    for (;;) {
        __asm volatile("wfi" ::: "memory");
    }
}

void Default_Handler(void) {
    shared->status = 0xE000U;
    hx_done_park();
}

void Reset_Handler(void) {
    for (uint32_t *p = &_sdata, *s = &_sidata; p < &_edata; p++, s++) *p = *s;
    for (uint32_t *p = &_sbss; p < &_ebss; p++) *p = 0U;

    for (uint32_t i = 0U; i < 16U; i++) {
        ((volatile uint32_t *)SHARED_BASE)[i] = 0U;
    }

    SCB_CPACR |= (0xFU << 20);
    SCB_SHCSR |= (7U << 16);
    __asm volatile("dsb; isb");

    shared->cm55m_cpuid = SCB_CPUID;
    const uint32_t dwt_comp = (DWT_CTRL >> 28) & 0xFU;
    const uint32_t fpb_code = ((FP_CTRL >> 4) & 0x7U) | ((FP_CTRL >> 9) & 0x38U);
    shared->cm55m_dwt_fpb = (dwt_comp << 16) | fpb_code;

    /* Verify inverted bit-28 HX6538 IDAU attribution via TT (SAU_CTRL.ALLNS=1). */
    SAU_CTRL = 2U;
    __asm volatile("dsb; isb");
    const uint32_t s_itcm = (tt_query(0x10000000U) >> 22) & 1U;
    const uint32_t ns_itcm = (tt_query(0x00000000U) >> 22) & 1U;
    const uint32_t s_mmio = (tt_query(0x5400A000U) >> 22) & 1U;
    const uint32_t ns_mmio = (tt_query(0x4400A000U) >> 22) & 1U;
    SAU_CTRL = 0U;
    __asm volatile("dsb; isb");
    shared->tt_flags = (s_itcm << 0) | (ns_itcm << 1) | (s_mmio << 2) | (ns_mmio << 3);

    uart0_init();
    if (UART0_CPR == 0x00010422U) {
        uart0_puts("HX6538 M55 DUAL BOOT\n");
    }

    /* Probe negative boundaries: unmapped U55 @0x53020000 BusFault, absent PACBTI UsageFault. */
    probe_bus_fault_read(U55_BASE_ADDR);
    probe_pacbti_mrs();

    shared->mve_lob_sum = mve_lob_kernel();

    /* Exercise Timer0 IRQ34 cleanly. */
    NVIC_ISER1 = (1U << (34U - 32U));
    TIMER0_RELOAD = 59U;
    TIMER0_VALUE = 59U;
    TIMER0_CTRL = (1U << 3) | (1U << 0);
    while (shared->timer0_irqs < 2U) {
        __asm volatile("wfi");
    }
    TIMER0_CTRL = 0U;

    /* Confirm CM55S is cold-held before release (STATE=0, CPUWAIT=1, boot_seq=0). */
    if (SCU_CM55S_STATE != 0U || SCU_CM55S_CPUWAIT != 1U || shared->cm55s_boot_seq != 0U) {
        Default_Handler();
    }

    NVIC_ISER0 = (1U << 7);
    SCU_CM55S_INITSVTOR = 0x34000000U;
    SCU_CM55S_STATE = 1U;
    SCU_CM55S_CPUWAIT = 0U;

    /* Wait for CM55S cold boot sequence to complete and park on WFI. */
    while (shared->cm55s_boot_seq < 1U) {
        __asm volatile("nop");
    }

    /* Acquire hardware mutex 0, send Mailbox command word + IRQ7 to CM55S. */
    while (MBOX_MUTEX(0) == 0U) {}
    MBOX_SHARE(0) = 0x4D353501U;
    MBOX_MUTEX(0) = 1U;
    MBOX_S_TRIG = 1U;

    while (shared->cm55m_mbox_irqs == 0U) {
        __asm volatile("wfi");
    }

    if (MBOX_SHARE(1) == 0x53353502U && shared_ns->cm55s_boot_seq >= 2U) {
        atomic_inc(&shared->excl_counter);
        shared->magic = 0x48584D35U;
        shared->status = 1U;
        uart0_puts("HX6538 M55 DUAL PASS\n");
    }
    hx_done_park();
}
