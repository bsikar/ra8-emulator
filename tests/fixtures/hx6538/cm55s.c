#include <stdint.h>

#define SCB_CPUID        (*(volatile uint32_t *)0xE000ED00U)
#define SCB_CPACR        (*(volatile uint32_t *)0xE000ED88U)
#define NVIC_ISER0       (*(volatile uint32_t *)0xE000E100U)

#define MBOX_S_STATUS    (*(volatile uint32_t *)0x5400A010U)
#define MBOX_S_CLR       (*(volatile uint32_t *)0x5400A018U)
#define MBOX_M_TRIG      (*(volatile uint32_t *)0x5400A004U)
#define MBOX_SHARE(n)    (*(volatile uint32_t *)(0x5400A100U + ((uint32_t)(n) * 4U)))
#define MBOX_MUTEX(n)    (*(volatile uint32_t *)(0x5400A200U + ((uint32_t)(n) * 4U)))

#define SHARED_BASE      0x34080000U

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
extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;

void Reset_Handler(void);
void Default_Handler(void);
void Mailbox_Handler(void);
void cm55s_idle_loop(void);

__attribute__((section(".isr_vector"), used))
const uint32_t vector_table[24] = {
    (uint32_t)&_estack,
    (uint32_t)Reset_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    0, 0, 0,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    0,
    (uint32_t)Default_Handler,
    (uint32_t)Default_Handler,
    [16 + 7] = (uint32_t)Mailbox_Handler,
};

static void atomic_inc(volatile uint32_t *ptr) {
    uint32_t val;
    uint32_t fail;
    do {
        __asm volatile("ldrex %0, [%1]" : "=r"(val) : "r"(ptr));
        val += 1U;
        __asm volatile("strex %0, %1, [%2]" : "=&r"(fail) : "r"(val), "r"(ptr) : "memory");
    } while (fail != 0U);
}

void Mailbox_Handler(void) {
    const uint32_t status = MBOX_S_STATUS;
    MBOX_S_CLR = status;
    shared->cm55s_mbox_irqs += 1U;
    while (MBOX_MUTEX(0) == 0U) {}
    if (MBOX_SHARE(0) == 0x4D353501U) {
        MBOX_SHARE(1) = 0x53353502U;
        shared->cm55s_boot_seq = 2U;
        atomic_inc(&shared->excl_counter);
    }
    MBOX_MUTEX(0) = 1U;
    MBOX_M_TRIG = 2U;
}

__attribute__((noinline)) void cm55s_idle_loop(void) {
    for (;;) {
        shared->cm55s_loop_ticks += 1U;
        __asm volatile("nop" ::: "memory");
    }
}

void Default_Handler(void) {
    for (;;) {
        __asm volatile("wfi");
    }
}

void Reset_Handler(void) {
    for (uint32_t *p = &_sdata, *s = &_sidata; p < &_edata; p++, s++) *p = *s;
    for (uint32_t *p = &_sbss; p < &_ebss; p++) *p = 0U;

    SCB_CPACR |= (0xFU << 20);
    __asm volatile("dsb; isb");

    shared->cm55s_cpuid = SCB_CPUID;
    NVIC_ISER0 = (1U << 7);
    shared->cm55s_boot_seq = 1U;

    /* Wait for Mailbox IRQ7 from CM55M, then enter live stepping loop. */
    while (shared->cm55s_mbox_irqs == 0U) {
        __asm volatile("wfi");
    }
    cm55s_idle_loop();
}
