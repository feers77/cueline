SECTIONS {
  . = P56_BASE;
  .text : { *(.text.stub) *(.text.sites) *(.text*) *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
