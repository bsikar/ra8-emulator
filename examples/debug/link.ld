ENTRY(Reset_Handler)
MEMORY { RAM (rwx) : ORIGIN = 0x22000000, LENGTH = 64K }
SECTIONS {
  .text ORIGIN(RAM) : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > RAM
  .data : { *(.data*) *(.bss*) *(COMMON) } > RAM
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
