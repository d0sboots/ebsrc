; Inputs
; long data_src at $0E
; long data_dst at $12
; $11 and $15 are #00 since addresses are 24 bits
;
; Extra calling conventions:
; A/X/Y are ignored
; m and x flags must be 0, callee-saved
; DBR must be $7E (or at least something with access to Low RAM), callee-saved
.PROC DECOMP
; The general convention in this function is to use X as source address
; and Y as destination address, since this lines up with how MVN works.
; Because of asymmetric addressing modes, this means using DBR + #$0000, X
; for source and [<DATA_DST], Y for destination, where the memory at DATA_DST
; is only actually used for the bank, and the two lower bytes are 0.
;
; This is a little inconvenient, because MVN sets DBR to the *destination*
; bank, and we need it to be the source. But we can solve this with a little
; push/pull in a judicious place.
;
; ===== MEMORY SAFETY =====
; We use the DMA0/DMA6/DMA7 registers for fastrom local storage. Also WMADD[LMH] for DMA access.
; TL;DR: Either don't use these in your code (satisfied by default for stock Earthbound), OR
; don't use them in code that calls DECOMP *AND* don't use them during NMI (i.e. via SCHEDULE_OVERWORLD_TASK)
; ===== END MEMORY SAFETY =====
;
; DMA0 is used to do transfers during vblank by the NMI handler. Thus, it
; (generally) can't be used by any other code, and nothing else tries to use it.
; We are only using the HDMA part of the DMA0 registers, which never get touched.
;
; In standard earthbound, DMA1 is used in COPY_TO_VRAM for normal transfers, and
; DMA2/DMA4/DMA5 are used for HDMA. DMA6 and DMA7 are completely unused, and
; thus normally safe. Since DECOMP is a leaf function, it would still be safe
; for homebrew code to use them, as long as it didn't call DECOMP itself (this
; could unexpectedly corrupt the DMA registers), or use them during NMI and
; call DECOMP (which could corrupt them as DECOMP runs).
;
; The code layout is a tangled zig-zag of blocks, set up to allow branch
; targets to work in one byte rather than read clearly.
.DEFINE DMA_BASE DMAP0
.DEFINE FAST_CMD $4307 ; DASB0 - 1 byte - in DMA0, but this byte isn't used for regular DMA
.DEFINE FAST_TMP $4308 ; A2A0L - 2 bytes - in DMA0, but these bytes aren't used for regular DMA
.DEFINE DATA_DST_ORIG $430A ; NTRL0 - 2 bytes - in DMA0, but these bytes aren't used for regular DMA
.DEFINE DATA_DST $4368 ; A2A6L - 3 bytes - HDMA in DMA6, will be undisturbed
.DEFINE DATA_SRC_BANK $436B ; 1 byte - unused space in DMA6
.DEFINE DATA_LEN $4370 ; DMAP7 - 2 bytes
.DEFINE TABLE_ADDR $4372 ; A1T7L - 3 bytes
.DEFINE MVN_ADDR $4375 ; DAS7L - 7 contiguous bytes to execute a payload
.DEFINE MVN_SRC_BANK $4377 ; DASB7
.DEFINE MVN_DST_BANK $4376 ; DAS7H
.DEFINE MVN_JMP $4378 ; A2A7L
.DEFINE MVN_JMP_ADDR $4379 ; A2A7H
; Because our routine is slightly larger than the original, we hoist the init
; code elsewhere and only have the main loop here. This costs an extra
; 6 cycles/call, which is tiny.
	JMP a:DECOMP_ENTRY
DO_DMA:
.A8
; Doing DMAs during regular processing (not vblank) is *very* annoying, due to an bug on
; early SNES boards involving HDMA immediately following a regular DMA. Disabling HDMA
; isn't an option, since that would cause visual artifacts. We could avoid DMA when HDMA
; is in use (the sane tactic), but that's leaving performance on the table.
;
; Instead, we read the H-counter from the PPU so we know exactly how many cycles there are
; until hblank, and bound our DMAs to be a safe length. This involves potentially looping
; them multiple times, creating a lot of expensive setup along this path. Since there are
; complications like memory refresh in the middle of the scanline, the actual calculation
; is offloaded to a lookup table.
; Used to distinguish between RLE8 (c=1) and LITERAL (c=0)
	CMP #$20
	STX z:<$4362 ; A1T6L/H
; DMAP of 0 is Transfer A->B, Increment A-Bus, 1-byte transfer, which is
; what we want for LITERAL. For RLE8, we need $08 which is A-Bus fixed.
; This takes advantage of the fact that a=0 when c=0.
	BCC DMA_SETUP
	LDA #$08
	INX
DMA_SETUP:
	STA z:<$4360 ; DMAP6
; We handle adjusting the Y register at the top here instead of the bottom, because
; it is more convenient to do so when the carry flag is clear, and along with another
; required 16-bit op.
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::CARRY
	INC z:<DATA_LEN ; Translate +1 MVN values to DMA count values
	TYA
	STA f:$002181 ; WMADDL/M
	ADC z:<DATA_LEN
	TAY
	SEP #PROC_FLAGS::ACCUM8
DMA_LOOP:
; Load the current PPU H-counter. Requires a dummy-read plus a double-read.
; We are only loading the low 8 bits. This means the section of the scanline that is
; primarily in hblank gets "mapped" into the part at the beginning. This is safe because
; the values for the front of the scanline are strictly smaller, so we never risk
; overshooting our DMA. It also doesn't end up being inefficient for complicated emergent
; reasons of timing, and it lets us save slow instructions here.
	LDA f:$00213F ; STAT78 - Reset OPHCT flipflop
	LDA f:$002137 ; SLHV
	LDA f:$00213C ; OPHCT
	STA z:<TABLE_ADDR
	LDA [<TABLE_ADDR]
	BEQ DMA_LOOP ; If we would hit hblank, delay by trying again
	REP #PROC_FLAGS::ACCUM8
	AND #$00FF
	CMP z:<DATA_LEN
	BCC SKIP_DATA_LEN
	LDA z:<DATA_LEN
SKIP_DATA_LEN:
	STA z:<$4365 ; DAS6L/H
; SBC is accumulator - data, but we need data - accumulator, which means
; negating accumulator ourselves. We could get rid of the INC by using CLC,
; but then the carry flag wouldn't be set correctly below.
	SEC
	SBC z:<DATA_LEN
	EOR #$FFFF
	INC
	STA z:<DATA_LEN
	SEP #PROC_FLAGS::ACCUM8
	LDA #$40  ; MDMAEN = bit 6
	STA f:MDMAEN
; A few cycles run before DMA activates, but we aren't messing with anything
; critical in those cycles here.
; c is the value from SBC. c=1 iff old DATA_LEN <= transfer size, and since
; DATA_LEN is always >= transfer size, this means c=1 iff we are done.
	BCC DMA_LOOP
	LDA z:<$4360 ; DMAP6, still will be 0 if LITERAL
	BNE READ_CMD ; We already incremented X
	LDX z:<$4362 ; A1T6L/H, DMA adjusted address for us
	BRA READ_CMD ; We haven't pushed B along the DO_DMA branch, so we don't pull it
; The main loop starts here, so that conditional branch targets can make use of the full [-128,127] range
; by also jumping *before* this point.
DECOMP_LOOP:
.GLOBAL DECOMP_LOOP
	SEP #PROC_FLAGS::ACCUM8
DECOMP_LOOP_NO_SEP:
.GLOBAL DECOMP_LOOP_NO_SEP
; We store the value of X here before calling MVN, because for most operations
; X needs to be adjusted to a different place for that opcode. For the
; codepaths where X is left alone, we can bypass this with DECOMP_LOOP_NO_LOAD.
	LDX z:<FAST_TMP
DECOMP_LOOP_NO_LOAD:
.GLOBAL DECOMP_LOOP_NO_LOAD
; This restores DBR with a minimum of code each loop. Coming into the first
; loop, it gets the value of DATA_SRC_BANK we pushed from the input.
	PLB
READ_CMD:
	LDA a:$00,X
	CMP #$E0
	BCS CMD_LONG
CMD_SHORT:
	AND #$E0
	STA z:<FAST_CMD
	LDA a:$00,X
	BEQ ONE_LITERAL_BYTE
	INX
	AND #$001F
; The actual number of bytes to operate on is the operand +1, but MVN adds
; that +1 on its own. For the codepaths that don't use MVN, we'll add it
; ourselves.
	STA z:<DATA_LEN
	STZ z:<DATA_LEN+1
DECODE_CMD:
	LDA z:<FAST_CMD
	BMI CMD_HIGH
CMD_LOW:
.A8
	CMP #$40
	BCC DO_DMA
	PHB
	BEQ RLE16
	JMP SEQ
EXIT:
	REP #PROC_FLAGS::ACCUM8
	PLB
	PLD
	RTL
RLE16:
	REP #PROC_FLAGS::ACCUM8
	LDA a:$00,X
	INX
	INX
	STX z:<FAST_TMP
	TYX
	STA [<DATA_DST],Y
; Extra increments for the rle16 case
	INY
	INY
	LDA z:<DATA_LEN
; If we are only RLE'ing 2 bytes, we have to stop now. MVN would overflow and write 64k.
	BEQ DECOMP_LOOP
	ASL
	DEC
	JML MVN_ADDR
ONE_LITERAL_BYTE:
	INX
	LDA a:$00,X
	INX
	STA [<DATA_DST],Y
	INY
	BRA READ_CMD ; Haven't even pushed B
CMD_LONG:
.A8
	CMP #$FF
	BEQ EXIT
	ASL
	ASL
	ASL
	AND #$E0
	STA z:<FAST_CMD
	LDA a:$00,X
	INX
	AND #$03
	STA z:<DATA_LEN+1
	LDA a:$00,X
	INX
	STA z:<DATA_LEN
	LDA z:<FAST_CMD
	BPL CMD_LOW
CMD_HIGH:
	PHB
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::CARRY
	LDA a:$00,X
; Offset is stored big-endian, which is very annoying
	XBA
	ADC <DATA_DST_ORIG
	INX
	INX
	STX z:<FAST_TMP
	TAX
	SEP #PROC_FLAGS::ACCUM8
	LDA z:<FAST_CMD
	CMP #$0080
	BEQ BREF
	CMP #$00E0
	BEQ BREF
; c = 0 from the compare
; For non BREF targets (the ones that can't use MVN), we add Y to DATA_LEN
; to form a comparison target address. We know the output won't be bank-crossing,
; so 16-bit math is fine here. Since DATA_LEN is one less than the number of bytes
; copies, the target will be the last byte output, as opposed to one-past-the-end
; as usual - this has consequences for how the test is structured.
;
; Also, we switch DBR to the destination bank. Since we are doing writes *and*
; reads there, we need absolute X & Y addressing, instead of the normal
; asymmetric mode we use to read from src and write to dest.
	LDA z:<DATA_DST+2
	PHA
	PLB
	REP #PROC_FLAGS::ACCUM8
	TYA
	ADC z:<DATA_LEN
	STA z:<DATA_LEN
	SEP #PROC_FLAGS::ACCUM8
	LDA z:<FAST_CMD
	CMP #$00C0
	BEQ BREF_REV
	JMP BREF_ROT
BREF_REV:
.A8
	LDA a:$00,X
	STA a:$00,Y
	DEX
	CPY z:<DATA_LEN
	INY
	BCC BREF_REV
	JMP a:DECOMP_LOOP_NO_SEP
BREF:
	REP #PROC_FLAGS::ACCUM8
	LDA z:<DATA_LEN
	JML MVN_ADDR
.ENDPROC

; Space out the function so that other functions end in the same spots
.RES $21

; Not actually decomp at all
DECOMP_ENTRY2:
	 REP #PROC_FLAGS::ACCUM8
	 PHD
	 PHA
	 TDC
	 SEC
	 SBC #$000C
	 TCD
	 PLA
	 STA $00
	 STX $02
	 STY $04
	 LDA #$00E1
	 STA $08
	 LDA $00
DECOMP_UNKNOWN16:
	SEC
	SBC #$071C
	BCC DECOMP_UNKNOWN17
	INC $08
	BRA DECOMP_UNKNOWN16
DECOMP_UNKNOWN17:
	ADC #$071C
	STA $00
	LDA $00
	SEP #PROC_FLAGS::ACCUM8
	PHA
	LDA #$0012
	REP #PROC_FLAGS::ACCUM8
	STA f:WRMPYA
	NOP
	CLC
	LDA f:RDMPYL
	TAX
	SEP #PROC_FLAGS::ACCUM8
	PLA
	STA f:WRMPYB
	TXA
	XBA
	REP #PROC_FLAGS::ACCUM8
	ADC f:RDMPYL
	CLC
	ADC #$0000
	STA $06
	LDY #$0000
	LDA $04
	BNE DECOMP_UNKNOWN19
	LDY #$0000
DECOMP_UNKNOWN18:
	LDA [$06]
	AND #$F0FF
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	LDA [$06]
	XBA
	ASL
	ASL
	ASL
	ASL
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN18
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN19:
	DEC
	BNE DECOMP_UNKNOWN21
DECOMP_UNKNOWN20:
	LDA [$06]
	XBA
	LSR
	AND #$7FF8
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	LDA [$06]
	XBA
	ASL
	ASL
	ASL
	AND #$7FF8
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN20
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN21:
	DEC
	BNE DECOMP_UNKNOWN23
DECOMP_UNKNOWN22:
	LDA [$06]
	XBA
	LSR
	LSR
	AND #$3FFC
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	LDA [$06]
	XBA
	ASL
	ASL
	AND #$3FFC
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN22
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN23:
	DEC
	BNE DECOMP_UNKNOWN25
DECOMP_UNKNOWN24:
	LDA [$06]
	XBA
	LSR
	LSR
	LSR
	AND #$1FFE
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	LDA [$06]
	XBA
	ASL
	AND #$1FFE
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN24
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN25:
	DEC
	BNE DECOMP_UNKNOWN27
DECOMP_UNKNOWN26:
	LDA [$06]
	XBA
	LSR
	LSR
	LSR
	LSR
	XBA
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	LDA [$06]
	AND #$FF0F
	STA ($02),Y
	INY
	INY
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN26
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN27:
	DEC
	BNE DECOMP_UNKNOWN29
DECOMP_UNKNOWN28:
	STZ $0A
	LDA [$06]
	XBA
	LSR
	LSR
	LSR
	LSR
	LSR
	ROR $0A
	XBA
	STA ($02),Y
	INY
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INC $06
	STZ $0A
	LDA [$06]
	XBA
	LSR
	ROR $0A
	XBA
	STA ($02),Y
	INY
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN28
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN29:
	DEC
	BNE DECOMP_UNKNOWN31
DECOMP_UNKNOWN30:
	LDA [$06]
	XBA
	STA $0A
	LDA #$0000
	ASL $0A
	ROL
	ASL $0A
	ROL
	STA ($02),Y
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INY
	INC $06
	STZ $0A
	LDA [$06]
	XBA
	LSR
	ROR $0A
	LSR
	ROR $0A
	XBA
	STA ($02),Y
	INY
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN30
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
DECOMP_UNKNOWN31:
	LDA [$06]
	XBA
	STA $0A
	LDA #$0000
	ASL $0A
	ROL
	STA ($02),Y
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INY
	INC $06
	STZ $0A
	LDA [$06]
	XBA
	LSR
	ROR $0A
	LSR
	ROR $0A
	LSR
	ROR $0A
	XBA
	STA ($02),Y
	INY
	INY
	LDA $0A
	XBA
	STA ($02),Y
	INY
	INC $06
	INC $06
	CPY #$0024
	BCC DECOMP_UNKNOWN31
	PLD
	REP #PROC_FLAGS::ACCUM8 | PROC_FLAGS::INDEX8
	RTS
