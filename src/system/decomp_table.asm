.GLOBAL DECOMP_LOOP

.align $100
DECOMP_REV_TABLE:
bvalue .SET 0
.REPEAT $100
  .BYT bvalue&1 << 7 | bvalue&2 << 5 | bvalue&4 << 3 | bvalue&8 << 1 | bvalue&16 >> 1 | bvalue&32 >> 3 | bvalue&64 >> 5 | bvalue&128 >> 7
  bvalue .SET bvalue + 1
.ENDREPEAT

DECOMP_ENTRY:
	PHD
	PHB
	SEP #PROC_FLAGS::ACCUM8
	LDA z:$10
	PHA
	STA f:DATA_SRC_BANK
	LDX z:$0E
	LDY z:$12
	LDA z:$14
; From here on we use direct addressing to access our locals, because
; we don't need to worry about the passed-in values.
; Use PEA+pull to avoid disturbing registers.
	PEA a:DMA_BASE
	PLD
	STX z:<FAST_TMP
	STY z:<DATA_DST_ORIG
	STA z:<DATA_DST+2
; By default, all MVNs will copy within the same bank. Only literals need
; to copy from the source address bank.
	STA z:<MVN_SRC_BANK
	STA z:<MVN_DST_BANK
	LDA #$54  ; MVN
	STA z:<MVN_ADDR
; This needs to be a far jmp, because $C4 has no access to the io ports.
	LDA #$5C  ; JML
	STA z:<MVN_JMP
	LDA #^DECOMP_LOOP
	STA z:<MVN_JMP_ADDR+2
	REP #PROC_FLAGS::ACCUM8
; The compiler/linker seems to be unable to comprehend 16-bit labels that
; aren't declared yet, so annoying hacks are needed?
	LDA #(<DECOMP_LOOP | >DECOMP_LOOP << 8)
	STA z:<MVN_JMP_ADDR
	STZ z:<DATA_DST
	JMP a:DECOMP_LOOP
