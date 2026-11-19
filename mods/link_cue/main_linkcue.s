! SPDX-License-Identifier: Apache-2.0
!
! Link Cue, prototype: a file streamer for the CDJ-2000NXS2 MAIN firmware
! (SH7724, SH-4, little-endian, v1.87). On request it reads any file the deck
! can open -- its own media (C:) or, over Pro DJ Link, the media of the
! player it browses (D:, the firmware's NFS mount) -- and streams the bytes
! over UDP, paced in real time. Decoding is the client's job; a WAV's data
! chunk is already PCM.
!
! The hook (DJCONT_PASS, shared with tcnet) only starts the streamer: after
! 1000 passes of the DJcont output loop it creates the task "LnkCue"
! (acre_tsk, priority 9) once and starts it. Its 4 KB stack and its packet
! buffers come from the firmware's malloc (0x08344A9C) at that moment, so the
! blob itself stays small. Everything else runs in that task, never in the DJcont loop.
!
! The task opens UDP 50099 on the firmware's own UDP layer (udp_vcre_cep,
! the T_UDP_CCEP shape of the tcnet listener) and polls it. A request
! (little-endian):
!
!     @0   "LCQ1"
!     @4   file offset to start at
!     @8   bytes to stream; 0 stops the current stream
!     @12  bytes per packet, at most 1400 (0 = 1400)
!     @16  pace, bytes per millisecond in 16.16 fixed point; 0 = unpaced
!     @20  lead: bytes sent ahead of real time
!     @24  the path, UTF-16LE, NUL-terminated (e.g. "D:/Contents/...")
!
! A new request replaces the stream in progress. The reply packets go to the
! requesting endpoint:
!
!     @0   "LCD1"
!     @4   sequence number
!     @8   file offset of the data
!     @12  data bytes that follow; 0 = end of the stream; -1 = the file did
!          not open; -2 = the seek failed
!     @16  the data
!
! Firmware calls (v1.87): acre_tsk 0x085142D8, sta_tsk 0x08514730, dly_tsk
! 0x08518FD4, udp_vcre_cep/udp_rcv_dat/udp_snd_dat as tcnet, and the stdio
! wrappers around the file library (context 0xA80EB5B8 baked in): fopen
! 0x082C0D2A (wide path, "r"), fclose 0x082C0D34, fseek 0x082C0D3C, fread
! 0x082C0D44 (buf, size, count, file). The 1 ms RTOS tick is 0x0B0C5258.

	.equ	D_ACRE, 4		! the firmware functions, after the
	.equ	D_STA, 8		! fpscr mask at data + 0
	.equ	D_DLY, 12
	.equ	D_UCRE, 16
	.equ	D_URCV, 20
	.equ	D_USND, 24
	.equ	D_FOPEN, 28
	.equ	D_FCLOSE, 32
	.equ	D_FSEEK, 36
	.equ	D_FREAD, 40
	.equ	D_TICK, 44
	.equ	D_STATE, 48		! hook passes; -1 started, -2 acre_tsk failed
	.equ	D_TID, 52
	.equ	D_CEP, 56
	.equ	D_FH, 60
	.equ	D_OFF, 64
	.equ	D_LEFT, 68
	.equ	D_SEQ, 72
	.equ	D_T0, 76
	.equ	D_SENT, 80
	.equ	D_CHUNK, 84
	.equ	D_RATE, 88
	.equ	D_LEAD, 92
	.equ	D_BUF, 96		! the malloc'd block: stack, then rx, then tx
	.equ	D_PEER, 100
	.equ	D_FROM, 108
	.equ	D_CCEP, 116
	.equ	D_CTSK, 132
	.equ	D_NAME, 160
	.equ	STACK, 4096
	.equ	B_RX, STACK
	.equ	RX_LEN, 552
	.equ	B_TX, STACK + RX_LEN
	.equ	TX_LEN, 16 + 1400 + 24
	.equ	BUF_LEN, B_TX + TX_LEN
	.equ	MAX_CHUNK, 1400

! Calls the firmware function at data + \fn with the fpscr mask the firmware
! applies before every call. Clobbers r1-r3; r4-r7 and the stack carry the
! arguments.
	.macro	fw fn
	mov.l	@(\fn,r8),r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	.endm

! data + \off (< 128) to and from a register other than r0. Clobber r0.
	.macro	ld reg, off
	mov	#\off,r0
	mov.l	@(r0,r8),\reg
	.endm
	.macro	st reg, off
	mov	#\off,r0
	mov.l	\reg,@(r0,r8)
	.endm

	.text
	.global linkcue
! The hook. r0-r7 are free (the trampoline saved them); r8 and pr are saved
! here because acre_tsk / sta_tsk are called.
linkcue:
	mova	h_pool,r0
	mov.l	@r0,r1
	add	r0,r1			! data
	mov.l	@(D_STATE,r1),r2
	cmp/pz	r2
	bf	9f			! started, or failed for good
	add	#1,r2
	mov.l	r2,@(D_STATE,r1)
	mov.w	h_wait,r3
	cmp/hs	r3,r2
	bf	9f
	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov	r1,r8
	mov.w	h_buflen,r4		! malloc(stack + rx + tx)
	mov.l	h_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	mov	#-2,r2
	tst	r0,r0
	bt	1f
	mov	#D_BUF,r1
	add	r8,r1
	mov.l	r0,@r1
	mov.w	h_ctsk,r5
	add	r8,r5			! T_CTSK
	mov.l	h_entry,r1
	add	r8,r1
	mov.l	r1,@(8,r5)		! task
	mov	#D_BUF,r0
	mov.l	@(r0,r8),r1
	mov.l	r1,@(20,r5)		! stk, the start of the block
	mov.w	h_name,r1
	add	r8,r1
	mov.l	r1,@(24,r5)		! name
	mov	#0,r4
	fw	D_ACRE
	mov	#-2,r2
	cmp/pl	r0
	bf	1f
	mov.l	r0,@(D_TID,r8)
	mov	r0,r4
	mov	#0,r5
	fw	D_STA
	mov	#-1,r2
1:	mov.l	r2,@(D_STATE,r8)
	mov.l	@r15+,r8
	lds.l	@r15+,pr
9:	rts
	nop

h_wait:		.word 1000
h_ctsk:		.word D_CTSK
h_name:		.word D_NAME
h_buflen:	.word BUF_LEN
	.p2align 2
h_pool:		.long data - h_pool
h_entry:	.long task - data
h_malloc:	.long 0x08344A9C

! The task. r8 = data for good; never returns.
task:
	mova	t_pool,r0
	mov.l	@r0,r8
	add	r0,r8
1:	mov	#D_CCEP,r4
	add	r8,r4
	fw	D_UCRE
	cmp/pl	r0
	bt	2f
	mov.w	t_1000,r4		! the network is not up yet
	fw	D_DLY
	bra	1b
	nop
2:	mov.l	r0,@(D_CEP,r8)

loop:
	mov	#0,r1
	mov.l	r1,@-r15		! TMO_POL
	mov.l	@(D_CEP,r8),r4
	mov	#D_FROM,r5
	add	r8,r5
	ld	r6,D_BUF
	mov.w	t_rx,r0
	add	r0,r6
	mov.w	t_rxlen,r7
	fw	D_URCV
	add	#4,r15
	cmp/pl	r0
	bf	1f
	bsr	request
	nop
1:	mov.l	@(D_FH,r8),r0
	tst	r0,r0
	bt	2f
	bsr	pump
	nop
	mov	#1,r4
	fw	D_DLY
	bra	loop
	nop
2:	mov	#10,r4
	fw	D_DLY
	bra	loop
	nop

t_1000:		.word 1000
t_rx:		.word B_RX
t_rxlen:	.word RX_LEN
	.p2align 2
t_pool:		.long data - t_pool

! Handles the request of r0 bytes in the receive buffer.
request:
	sts.l	pr,@-r15
	mov	r0,r9
	mov	#24,r1
	cmp/hs	r1,r9
	bf	9f
	ld	r10,D_BUF
	mov.w	q_rx,r0
	add	r0,r10
	mov.l	@r10,r1
	mov.l	q_magic,r2
	cmp/eq	r1,r2
	bf	9f
	bsr	close
	nop
	mov	#D_FROM,r1		! replies go where the request came from
	add	r8,r1
	mov	#D_PEER,r2
	add	r8,r2
	mov.l	@r1,r3
	mov.l	r3,@r2
	mov.l	@(4,r1),r3
	mov.l	r3,@(4,r2)
	mov.l	@(4,r10),r1
	st	r1,D_OFF
	mov.l	@(8,r10),r1
	st	r1,D_LEFT
	mov.l	@(12,r10),r1
	mov.w	q_max,r2
	tst	r1,r1
	bt	1f
	cmp/hi	r2,r1
	bf	2f
1:	mov	r2,r1
2:	st	r1,D_CHUNK
	mov.l	@(16,r10),r1
	st	r1,D_RATE
	mov.l	@(20,r10),r1
	st	r1,D_LEAD
	mov	#0,r1
	st	r1,D_SEQ
	st	r1,D_SENT
	ld	r1,D_LEFT
	tst	r1,r1
	bt	9f			! a stop request
	mov	r10,r4
	add	#24,r4			! the path
	fw	D_FOPEN
	tst	r0,r0
	bf	2f
	bsr	reply_status
	mov	#-1,r4
	bra	9f
	nop
2:	mov	r0,r11
	mov	r0,r4
	ld	r5,D_OFF
	mov	#0,r6			! SEEK_SET
	fw	D_FSEEK
	tst	r0,r0
	bt	3f
	mov	r11,r4
	fw	D_FCLOSE
	bsr	reply_status
	mov	#-2,r4
	bra	9f
	nop
3:	mov.l	r11,@(D_FH,r8)
	mov.l	@(D_TICK,r8),r1
	mov.l	@r1,r1
	st	r1,D_T0
9:	lds.l	@r15+,pr
	rts
	nop

q_rx:		.word B_RX
q_max:		.word MAX_CHUNK
	.p2align 2
q_magic:	.long 0x3151434C	! "LCQ1"

! Sends up to four packets of the open file, as far as the pace allows;
! at the end of the requested range or of the file, closes it and sends
! the end marker.
pump:
	sts.l	pr,@-r15
	mov	#4,r12
1:	ld	r1,D_LEFT
	tst	r1,r1
	bt	8f
	ld	r2,D_RATE
	tst	r2,r2
	bt	2f
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r3
	ld	r4,D_T0
	sub	r4,r3			! ms since the request
	dmulu.l	r3,r2
	sts	mach,r3
	sts	macl,r4
	shll16	r3
	shlr16	r4
	or	r4,r3			! bytes due by now
	ld	r4,D_LEAD
	add	r4,r3
	ld	r4,D_SENT
	cmp/hs	r3,r4
	bt	9f			! ahead of the pace: later
2:	ld	r6,D_CHUNK
	cmp/hi	r1,r6
	bf	3f
	mov	r1,r6			! the last, shorter packet
3:	ld	r4,D_BUF
	mov.w	p_tx,r0
	add	r0,r4
	add	#16,r4
	mov	#1,r5
	mov.l	@(D_FH,r8),r7
	fw	D_FREAD
	cmp/pl	r0
	bf	8f
	mov	r0,r13
	ld	r6,D_BUF
	mov.w	p_tx,r0
	add	r0,r6
	mov.l	p_magic,r2
	mov.l	r2,@r6
	ld	r2,D_SEQ
	mov.l	r2,@(4,r6)
	add	#1,r2
	st	r2,D_SEQ
	ld	r2,D_OFF
	mov.l	r2,@(8,r6)
	add	r13,r2
	st	r2,D_OFF
	mov.l	r13,@(12,r6)
	ld	r2,D_LEFT
	sub	r13,r2
	st	r2,D_LEFT
	ld	r2,D_SENT
	add	r13,r2
	st	r2,D_SENT
	mov	r13,r7
	bsr	send
	add	#16,r7
	dt	r12
	bf	1b
	bra	9f
	nop
8:	bsr	close
	nop
	bsr	reply_status
	mov	#0,r4
9:	lds.l	@r15+,pr
	rts
	nop

p_tx:		.word B_TX
	.p2align 2
p_magic:	.long 0x3144434C	! "LCD1"

! A header-only reply with data bytes = r4 (0 end, < 0 error).
reply_status:
	sts.l	pr,@-r15
	mov	r4,r1
	ld	r6,D_BUF
	mov.w	z_tx,r0
	add	r0,r6
	mov.l	z_magic,r2
	mov.l	r2,@r6
	ld	r2,D_SEQ
	mov.l	r2,@(4,r6)
	ld	r2,D_OFF
	mov.l	r2,@(8,r6)
	mov.l	r1,@(12,r6)
	bsr	send
	mov	#16,r7
	lds.l	@r15+,pr
	rts
	nop

z_tx:		.word B_TX
	.p2align 2
z_magic:	.long 0x3144434C

! udp_snd_dat(socket, the requester, r6, r7 bytes, TMO_FEVR).
send:
	sts.l	pr,@-r15
	mov	#-1,r1
	mov.l	r1,@-r15
	mov.l	@(D_CEP,r8),r4
	mov	#D_PEER,r5
	add	r8,r5
	fw	D_USND
	add	#4,r15
	lds.l	@r15+,pr
	rts
	nop

! Closes the open file, if any.
close:
	sts.l	pr,@-r15
	mov.l	@(D_FH,r8),r4
	tst	r4,r4
	bt	1f
	fw	D_FCLOSE
	mov	#0,r1
	mov.l	r1,@(D_FH,r8)
1:	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
data:
	.long	0xFFE7FFFF		! fpscr mask
	.long	0x085142D8		! acre_tsk(0, T_CTSK)
	.long	0x08514730		! sta_tsk(id, 0)
	.long	0x08518FD4		! dly_tsk(ms)
	.long	0x08233A22		! udp_vcre_cep
	.long	0x0823415E		! udp_rcv_dat
	.long	0x08233CF6		! udp_snd_dat
	.long	0x082C0D2A		! fopen(wide path) "r"
	.long	0x082C0D34		! fclose
	.long	0x082C0D3C		! fseek(file, offset, whence)
	.long	0x082C0D44		! fread(buf, size, count, file)
	.long	0x0B0C5258		! the 1 ms RTOS tick
	.long	0			! state
	.long	0			! task id
	.long	0			! socket
	.long	0			! open file
	.long	0			! next file offset
	.long	0			! bytes left
	.long	0			! sequence
	.long	0			! tick at the request
	.long	0			! bytes sent
	.long	0			! bytes per packet
	.long	0			! pace
	.long	0			! lead
	.long	0			! the malloc'd block
	.space	8			! the requester, a T_IPV4EP
	.space	8			! the sender of the last datagram
	.long	0, 0			! T_UDP_CCEP: attribute, any address,
	.short	50099, 0		! the port,
	.long	0			! no callback
	.long	0, 0, 0, 9, 4096, 0, 0	! T_CTSK: atr, exinf, task, priority,
					! stack size, stack, name
	.ascii	"LnkCue\0\0"
