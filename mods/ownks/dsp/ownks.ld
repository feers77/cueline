/* ownks DSP section: one boot-table section at KS_BASE; NOLOAD state after it (ks3: set up in chunks) */
ENTRY(ks_fill)
SECTIONS
{
  . = 0x805C0000;
  .ksimg : {
    *(.ksctl)
    . = ALIGN(32);
    *(.text .text.*)
    . = ALIGN(8);
    *(.rodata .rodata.* .const .const.* .neardata .neardata.* .fardata .fardata.* .data .data.* .bss .bss.* .far .far.* COMMON)
    . = ALIGN(32);
  }
  .ksnoload (NOLOAD) : { *(.ksnoload) }
  _ks_end = .;                          /* KS3: ownks.py checks it against 0x80600000 */
  /DISCARD/ : { *(.comment) *(.c6xabi.*) *(.note*) }
}
