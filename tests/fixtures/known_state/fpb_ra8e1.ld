ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x02000000, LENGTH = 1024K
  SRAM (rwx) : ORIGIN = 0x22060000, LENGTH = 512K
}
SECTIONS
{
  .text ORIGIN(FLASH) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .known_state 0x22060100 (NOLOAD) : { KEEP(*(.known_state)) } > SRAM
  .data : { *(.data*) } > SRAM AT > FLASH
  .bss (NOLOAD) : { *(.bss*) *(COMMON) } > SRAM
  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
