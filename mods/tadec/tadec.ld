/* tadec blob: absolute at TADEC_BASE (build.sh: -defsym, default 0x08140000
 * in MAIN's code cave); entry table first.
 * .bss is folded into .data so the flat binary carries its zeros (the cave
 * in the image is erased flash, 0xFF). */
SECTIONS
{
  . = TADEC_BASE;
  .entries : { KEEP(*(.entries)) }
  .text    : { *(.text .text.*) }
  .rodata  : { *(.rodata .rodata.*) }
  .data    : { *(.data .data.*) *(.bss .bss.*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.gnu*) }
}
