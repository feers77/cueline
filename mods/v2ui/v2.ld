/* SPDX-License-Identifier: Apache-2.0 */
/* V2 UI: two images. .v2 at V2_BASE (on-chip RAM): entry first, code, small data, zeroed state.
 * .v2ro at V2_RO (SDRAM, a range proven untouched by the stock GUI: re/V2_P4.md): the read-only bulk
 * (font and icon atlases). Each gets its own load record (v2ui.py). */
SECTIONS
{
	. = V2_BASE;
	.v2 : {
		KEEP(*(.text.entry))
		*(.text*)
		EXCLUDE_FILE(*font.o *atlas.o) *(.rodata*)
		*(.data*)
		*(.sdata*)
		*(.bss*)
		*(.sbss*)
		*(COMMON)
		LONG(0x56324549)	/* "V2EI": end marker, keeps the zeroed tail in the binary */
	}
	. = V2_RO;
	.v2ro : {
		__v2ro_start = .;
		*font.o(.rodata*)
		*atlas.o(.rodata*)
		. = ALIGN(4);
		__v2ro_end = .;
		LONG(0x56325230)	/* "V2R0": end of the read-only image */
	}
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
