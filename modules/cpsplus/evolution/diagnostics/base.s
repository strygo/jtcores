; Original diagnostic, no Capcom code or assets. 68000, big-endian words.
        org 0
        dc.l $00ff8000, reset_entry
        dcb.l 24, diag_fail
        dc.l $00a00100             ; level-2 autovector (VBLANK)
        dcb.l 37, diag_fail
reset_entry:
        move.w #$2700,sr
        clr.w $ff0000
        clr.w $ff0002
        clr.w $ff0004
        jsr $a00000
        cmp.l #$cafebabe,d0
        bne diag_fail
        move.w $bffffe,d0
        cmp.w #$1357,d0
        bne diag_fail
        move.w $c00000,d0
        cmp.w #$2468,d0
        bne diag_fail
        move.w $dffffe,d0
        cmp.w #$beef,d0
        bne diag_fail
        moveq #15,d1
cache_loop:
        move.l $002000,d0
        cmp.l #$11223344,d0
        bne diag_fail
        move.l $a02000,d0
        cmp.l #$99aabbcc,d0
        bne diag_fail
        dbra d1,cache_loop
        move.w #$2000,sr
        move.w #$1234,$ff0002       ; bench may now request VBLANK
irq_wait:
        cmp.w #$6789,$ff0004
        bne irq_wait
        move.w #$600d,$ff0000
done:   bra done
diag_fail:
        move.w #$dead,$ff0000
        bra diag_fail
        org $400
helper: rts
        org $2000
        dc.l $11223344,$55667788
