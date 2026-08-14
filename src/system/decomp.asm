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
; We use the DMA1 registers for fastrom local storage.
; The nature of how DMA is used in earthbound guarantees DMA0 and DMA1 won't
; be used for HDMA. DMA0 is used in the NMI handler, so we can't rely on
; any registers there that are used for normal DMA transfers. DMA1 and the
; unused byte in other DMA channels should be safe.
;
; The code layout is a tangled zig-zag of blocks, set up to allow branch
; targets to work in one byte rather than read clearly.
.DEFINE DMA_BASE DMAP0
.DEFINE DATA_DST DMAP1 ; 3 bytes
.DEFINE DATA_DST_ORIG NTRL0 ; 2 bytes - in DMA0, but these bytes aren't used for regular DMA
.DEFINE FAST_CMD DASB0 ; 1 bytes - in DMA0, but this byte isn't used for regular DMA
.DEFINE FAST_TMP $4308 ; 2 bytes - in DMA0, but these bytes aren't used for regular DMA
.DEFINE DATA_SRC_BANK $432B ; 1 byte - unused space in DMA2 (remains unchanged even across DMAs)
.DEFINE DATA_LEN A1T1H ; 2 bytes
.DEFINE MVN_ADDR $4315 ; 7 contiguous bytes to execute a payload
.DEFINE MVN_SRC_BANK $4317
.DEFINE MVN_DST_BANK $4316
.DEFINE MVN_JMP $4318
.DEFINE MVN_JMP_ADDR $4319
; Because our routine is slightly larger than the original, we hoist the init
; code elsewhere and only have the main loop here. This costs an extra
; 6 cycles/call, which is tiny.
	JMP a:DECOMP_ENTRY
DECOMP_LOOP:
.GLOBAL DECOMP_LOOP
	SEP #PROC_FLAGS::ACCUM8
LOOP_NO_SEP:
; We store the value of X here before calling MVN, because for most operations
; X needs to be adjusted to a different place for that opcode. For the
; codepaths where X is left alone, we can bypass this with LOOP_NO_LOAD.
	LDX z:<FAST_TMP
LOOP_NO_LOAD:
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
	INX
	AND #$001F
; The actual number of bytes to operate on is the operand +1, but MVN adds
; that +1 on its own. For the codepaths that don't use MVN, we'll add it
; ourselves.
	STA z:<DATA_LEN
	STZ z:<DATA_LEN+1
DECODE_CMD:
	PHB
	LDA z:<FAST_CMD
	BPL CMD_LOW
	JMP CMD_HIGH
CMD_LONG:
	CMP #$FF
	BEQ EXIT
	ASL
	ASL
	ASL
	AND #$00E0
	STA z:<FAST_CMD
	LDA a:$00,X
	INX
	AND #$0003
	STA z:<DATA_LEN+1
	LDA a:$00,X
	INX
	STA z:<DATA_LEN
	BRA DECODE_CMD
EXIT:
	REP #PROC_FLAGS::ACCUM8
	PLB
	PLD
	RTL
CMD_LOW:
.A8
	BEQ LITERAL
	CMP #$40
	BCC RLE8
	BEQ RLE16
	BRA SEQ
RLE16:
	REP #PROC_FLAGS::ACCUM8
; Besides being distinguised by m, these are also distinguished by c.
; c will be 1 for RLE16, and 0 for RLE8.
RLE8:
; It would be safe to read 16-bits here, but an unconditional 16-bit write
; could overflow our buffer if DATA_LEN=0.
	LDA a:$00,X
	STA [<DATA_DST],Y
	INX
	STX z:<FAST_TMP
	TYX
	BCC RLE8_NORMAL
; Extra increments for the rle16 case
	INC z:<FAST_TMP
	INY
RLE8_NORMAL:
	INY
	REP #PROC_FLAGS::ACCUM8
	LDA z:<DATA_LEN
; If we are only RLE'ing 1 byte, we have to stop now. MVN would overflow and write 64k.
	BEQ DECOMP_LOOP
	BCC RLE8_ASL_SKIP
	ASL
RLE8_ASL_SKIP:
	DEC
	JML MVN_ADDR
LITERAL:
.A8
; This codepath does the most self-modifying code, because it needs to adjust
; both the source bank and the jump target, and then adjust them back again after.
; This allows all other codepaths (the common ones) to avoid self-modifying code.
	LDA z:<DATA_SRC_BANK
	STA z:<MVN_SRC_BANK
	REP #PROC_FLAGS::ACCUM8
	LDA #(<LITERAL_CLEANUP | >LITERAL_CLEANUP << 8)
	STA z:<MVN_JMP_ADDR
	LDA z:<DATA_LEN
	JML MVN_ADDR
LITERAL_CLEANUP:
	LDA #(<DECOMP_LOOP | >DECOMP_LOOP << 8)
	STA z:<MVN_JMP_ADDR
	SEP #PROC_FLAGS::ACCUM8
	LDA z:<DATA_DST+2
	STA z:<MVN_SRC_BANK
	JMP LOOP_NO_LOAD
SEQ:
	LDA a:$00,X
	INX
	STX z:<FAST_TMP
	LDX z:<DATA_LEN
	INX
SEQ_LOOP:
	STA [<DATA_DST],Y
	INY
	INC
	DEX
	BNE SEQ_LOOP
	JMP LOOP_NO_SEP
CMD_HIGH:
	REP #PROC_FLAGS::ACCUM8|PROC_FLAGS::CARRY
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
	BRA BREF_ROT
BREF:
	REP #PROC_FLAGS::ACCUM8
	LDA z:<DATA_LEN
	JML MVN_ADDR
BREF_ROT:
.A8
; Steal DATA_DST to do indirect reads from our table
	LDA #^DECOMP_REV_TABLE
	STA z:<DATA_DST+2
	LDA #>DECOMP_REV_TABLE
	STA z:<DATA_DST+1
BREF_ROT_LOOP:
	LDA a:$00,X
	STA z:<DATA_DST
	LDA [<DATA_DST]
	STA a:$00,Y
	INX
; We compare vs the preincrement value, because DATA_LEN is storing the last
; address instead of one-past-the-end. But we can't use the z flag, because
; INY overwrites it - so we use c instead, which switches from 0 to 1 once Y
; equals DATA_LEN.
	CPY z:<DATA_LEN
	INY
	BCC BREF_ROT_LOOP
	STZ z:<DATA_DST
	STZ z:<DATA_DST+1
	LDA z:<MVN_DST_BANK
	STA z:<DATA_DST+2
	JMP LOOP_NO_SEP
BREF_REV:
	LDA a:$00,X
	STA a:$00,Y
	DEX
	CPY z:<DATA_LEN
	INY
	BCC BREF_REV
	JMP LOOP_NO_SEP
.ENDPROC

; Space out the function so that other functions end in the same spots
.RES $24

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
