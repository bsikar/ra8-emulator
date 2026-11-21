ENTRY(Reset_Handler)

MEMORY
{
  ITCM_S (rwx) : ORIGIN = 0x10000000, LENGTH = 256K
  DTCM_S (rw)  : ORIGIN = 0x30000000, LENGTH = 256K
}

_estack = ORIGIN(DTCM_S) + LENGTH(DTCM_S);

SECTIONS
{
  .isr_vector :
  {
    KEEP(*(.isr_vector))
  } > ITCM_S

  .text :
  {
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
    _sidata = .;
  } > ITCM_S

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
