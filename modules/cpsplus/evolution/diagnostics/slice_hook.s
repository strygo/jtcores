; Object extension slice diagnostic (build_controls.py `slice` control).
; RESET_PC is the verified original reset vector, supplied by the builder.
; Reached from the patched reset vector. After the extension-window checks of
; game_hook.s it writes a palette, draws four rows of objects, holds them on
; screen, restores the CPU state and jumps to the game's original entry.
;
; What a human should see for about three seconds after power-on, before the
; game's own boot sequence (palette 0 = the 16-colour ramp below, black
; background, rows 16 pixels tall starting near the top left):
;   row 1 (y=$30): eight objects written through the NORMAL window with tile
;         codes $0100..$0107 of the game's own 32 MiB library: whatever stock
;         art lives at those codes (it may be blank);
;   row 2 (y=$50): the same codes written through the A14 ALIAS: solid colour
;         blocks from the slice pattern (pen = code mod 15: pens 1..8 in order),
;         the last object a 2x2 block of codes $0200/$0201/$0210/$0211;
;   row 3 (y=$70): alias entries with y bank bits 01: NOTHING (ext with bank
;         bits other than 00 draws transparent and fetches no SDRAM);
;   row 4 (y=$90): alias entries whose x word was then rewritten through the
;         normal window: stock art again, identical to row 1.
; Every object carries priority 7 so the mixer shows it over the empty
; background before the game programs any layer.
        org $a00000
        move.w sr,-(sp)
        movem.l d0-d7/a0-a6,-(sp)
        jsr test_subroutine
        cmp.l #$c2c20008,d0
        bne hook_failed
        cmp.w #$1357,$bffffe
        bne hook_failed
        cmp.w #$2468,$c00000
        bne hook_failed
        cmp.w #$beef,$dffffe
        bne hook_failed
        bsr draw_test
        movem.l (sp)+,d0-d7/a0-a6
        move.w (sp)+,sr
        jmp RESET_PC
hook_failed:
        stop #$2700
        bra hook_failed
test_subroutine:
        move.l #$c2c20008,d0
        rts

; Hold count: iterations of an 18-cycle loop at 16 MHz, about 3.5 seconds.
; The RTL gate overrides this long word with 2 (+HOLD_ADDR); nothing else
; differs between the simulated and the shipped program.
        org $a00100
hold_count:
        dc.l $300000

        org $a00104
draw_test:
        ; palette 0 of the object page at VRAM $910000, full brightness
        lea $910000,a0
        lea colours(pc),a1
        moveq #15,d1
.pal:   move.w (a1)+,(a0)+
        dbra d1,.pal
        move.w #$9100,$80010a           ; CPS-A palette base: schedules the palette copy
        ; object list: object RAM page 0 ($700000), physical bank 0 after reset
        move.w #$0030,d3                ; row 1: normal window, low library
        move.w #$0100,d4
        lea $700000,a2
        bsr row
        move.w #$0050,d3                ; row 2: alias window, slice
        move.w #$0100,d4
        lea $704000+64,a2
        bsr row
        move.w #$0200,-4(a2)            ; last object of row 2: 2x2 block
        move.w #$1100,-2(a2)
        move.w #$2070,d3                ; row 3: alias, y bank bits 01: transparent
        move.w #$0100,d4
        lea $704000+128,a2
        bsr row
        move.w #$0090,d3                ; row 4: alias ...
        move.w #$0100,d4
        lea $704000+192,a2
        bsr row
        lea $700000+192,a2              ; ... then x rewritten through the normal window
        moveq #7,d1
        move.w #$e040,d2
.rw:    move.w d2,(a2)
        addq.l #8,a2
        add.w #$18,d2
        dbra d1,.rw
        move.w #$8000,$700000+256+2     ; end of list
        move.l hold_count(pc),d0
.hold:  subq.l #1,d0
        bne.s .hold
        rts

; Eight 1x1 objects: a2 = first entry, d3 = y word, d4 = first tile code.
; x = $40 + 24*i with priority 7; palette 0, no flips.
row:    moveq #7,d1
        move.w #$e040,d2
.e:     move.w d2,(a2)+
        move.w d3,(a2)+
        move.w d4,(a2)+
        clr.w (a2)+
        addq.w #1,d4
        add.w #$18,d2
        dbra d1,.e
        rts

colours:
        dc.w $f000,$f00f,$f0f0,$ff00,$f0ff,$ff0f,$fff0,$ffff
        dc.w $f888,$f008,$f080,$f800,$f088,$f808,$f880,$fccc
