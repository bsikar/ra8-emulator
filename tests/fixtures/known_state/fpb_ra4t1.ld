ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 256K
  SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 40K
}
SECTIONS
{
  .text ORIGIN(FLASH) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .known_state 0x20000100 (NOLOAD) : { KEEP(*(.known_state)) } > SRAM
  .data : { *(.data*) } > SRAM AT > FLASH
  .bss (NOLOAD) : { *(.bss*) *(COMMON) } > SRAM
  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
