ENTRY(vectors)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x02000000, LENGTH = 1M
  SRAM (rwx) : ORIGIN = 0x22000000, LENGTH = 1664K
}
SECTIONS
{
  .text ORIGIN(FLASH) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .data : { *(.data*) } > SRAM AT > FLASH
  .bss (NOLOAD) : { *(.bss*) *(COMMON) } > SRAM
}
