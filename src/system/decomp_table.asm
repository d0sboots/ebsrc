; These are logically local to the routine, just split across two
; locations/files, which is why they aren't declared in bank04.asm.
.GLOBAL DECOMP_LOOP: absolute
.GLOBAL DECOMP_LOOP_NO_SEP: absolute
.GLOBAL DECOMP_LOOP_NO_LOAD: absolute

; Initialization code, invoked from DECOMP
DECOMP_ENTRY:
.EXPORT DECOMP_ENTRY
	PHD
	PHB
	SEP #PROC_FLAGS::ACCUM8
	LDA z:$10
; We will pull this into DBR later
	PHA
	LDX z:$0E
	LDY z:$12
	LDA z:$14
; From here on we use direct addressing to access our locals, because
; we don't need to worry about the passed-in values.
; Use PEA+pull to avoid disturbing registers.
	PEA a:DMA_BASE
	PLD
	STY z:<DATA_DST_ORIG
	STA z:<DATA_DST+2
; By default, all MVNs will copy within the same bank. Only literals need
; to copy from the source address bank.
	STA z:<MVN_SRC_BANK
	STA z:<MVN_DST_BANK
	STA f:$002183 ; WMADDH
	LDA #$54  ; MVN
	STA z:<MVN_ADDR
; This needs to be a far jmp, because $C4 has no access to the io ports.
	LDA #$5C  ; JML
	STA z:<MVN_JMP
	LDA #^DECOMP_LOOP
	STA z:<MVN_JMP_ADDR+2
	LDA #$80  ; WRAM B-bus addr
	STA z:<$4361 ; BBAD6
	LDA 1, S
	STA z:<DATA_SRC_BANK
	STA z:<$4364 ; A1B6
	REP #PROC_FLAGS::ACCUM8
	LDA #.LOWORD(DECOMP_LOOP)
	STA z:<MVN_JMP_ADDR
	STZ z:<DATA_DST
	LDA #(DECOMP_TIMING_TABLE >> 8)
	STA z:<TABLE_ADDR+1
	SEP #PROC_FLAGS::ACCUM8
	JMP a:DECOMP_LOOP_NO_LOAD
; This code is rarely executed, and can be pulled out of the main body in
; order to make the main code fit.
SEQ:
.A8
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
	JMP DECOMP_LOOP_NO_SEP

; Table for bitrotated lookups. *Must* be page-aligned, or else the lookup
; code gets more complicated.
.align $100
DECOMP_ROT_TABLE:
bvalue .SET 0
.REPEAT $100
  .BYT bvalue&1 << 7 | bvalue&2 << 5 | bvalue&4 << 3 | bvalue&8 << 1 | bvalue&16 >> 1 | bvalue&32 >> 3 | bvalue&64 >> 5 | bvalue&128 >> 7
  bvalue .SET bvalue + 1
.ENDREPEAT

.align $100
DECOMP_TIMING_TABLE:
.REPEAT 170
  .BYT 120
.ENDREPEAT

