/* tadec entry table + FPSCR stubs (TchAud's calls; TchDec runs the decoder:
 * tadec.c "TchDec"). The firmware calls with FPSCR.PR = 0;
 * gcc -m4 code expects PR = 1 on entry. Each stub saves FPSCR, sets
 * PR = 1 / SZ = 0, calls the C function (args in r4-r7 untouched) and
 * restores FPSCR. */
	.section .entries,"ax"
	.global tadec_table
tadec_table:
	bra	s_open			/* +0  q_open(path): TchDec opens it, waits */
	nop
	bra	s_seek			/* +4  q_seek(col): posted, the ring flushed */
	nop
	bra	s_read			/* +8  q_read(out, n, live): from the ring, -1 none now */
	nop
	bra	s_rate			/* +12 tadec_rate() */
	nop
	bra	s_close			/* +16 q_close(): TchDec closes it, waits */
	nop
	bra	s_jpeg			/* +20 tadec_jpeg(...) */
	nop
	bra	tadec_task_entry	/* +24 TchDec's task entry (its own stack) */
	nop
	bra	s_quiet			/* +28 q_quiet(): TchDec out of the file layer */
	nop

/* TchDec (tadec.c q_start creates it): runs on its own task stack, so no
 * stack switch; only FPSCR PR = 1 / SZ = 0 for gcc -m4 code. Never returns. */
	.global	tadec_task_entry
tadec_task_entry:
	sts	fpscr,r1
	mov.l	1f,r0
	and	r0,r1
	mov.l	2f,r0
	or	r0,r1
	lds	r1,fpscr
	mov.l	3f,r0
	jmp	@r0
	nop
	.p2align 2
1:	.long	0xFFE7FFFF
2:	.long	0x00080000
3:	.long	tadec_task

	.macro STUB name, fn
\name:
	mov.l	4f,r1			/* run on the blob's own stack: the caller's */
	mov.l	r15,@r1			/* task stack is small and minimp3 needs ~17 KB */
	mov.l	5f,r15
	sts.l	pr,@-r15
	sts.l	fpscr,@-r15
	sts	fpscr,r1
	mov.l	1f,r0
	and	r0,r1
	mov.l	2f,r0
	or	r0,r1
	lds	r1,fpscr
	mov.l	3f,r0
	jsr	@r0
	nop
	lds.l	@r15+,fpscr
	lds.l	@r15+,pr
	mov.l	4f,r1
	rts
	mov.l	@r1,r15
	.p2align 2
1:	.long	0xFFE7FFFF
2:	.long	0x00080000
3:	.long	\fn
4:	.long	saved_sp
5:	.long	stack_top
	.endm

	STUB s_open, q_open
	STUB s_seek, q_seek
	STUB s_read, q_read
	STUB s_rate, tadec_rate
	STUB s_close, q_close
	STUB s_jpeg, tadec_jpeg
	STUB s_quiet, q_quiet

	.section .bss
	.p2align 3
saved_sp:	.space	4
	.p2align 3
#ifndef TADEC_STACK            /* m4a/build.sh: 98304 (FAAD2's CPE path alone takes ~42 KB) */
#define TADEC_STACK 49152
#endif
stack:		.space	TADEC_STACK
stack_top:
