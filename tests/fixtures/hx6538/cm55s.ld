ENTRY(Reset_Handler)

MEMORY
{
  SRAM0_S (rwx) : ORIGIN = 0x34000000, LENGTH = 256K
  DTCM_S (rw)   : ORIGIN = 0x30000000, LENGTH = 256K
}

_estack = ORIGIN(DTCM_S) + LENGTH(DTCM_S);

SECTIONS
{
  .isr_vector :
  {
    KEEP(*(.isr_vector))
  } > SRAM0_S

  .text :
  {
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
    _sidata = .;
  } > SRAM0_S

  .data : AT(_sidata)
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } > DTCM_S

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DTCM_S
}
