; RESET_PC is the verified original reset vector, supplied by the builder.
; Preserve registers, stack and SR before handing control back to the game.
; Two entries: $a00000 is reached directly from the patched reset vector;
; $a00200 is reached from plaintext code placed inside the original 4 MiB
; window above the key's encrypted bound (window_hook.s), which leaves a
; witness in D7 that this entry checks before continuing.
        org $a00000
        move.w sr,-(sp)
        movem.l d0-d7/a0-a6,-(sp)
        bra common_checks
        org $a00200
window_entry:
        move.w sr,-(sp)
        movem.l d0-d7/a0-a6,-(sp)
        cmp.l #$c2c25a5a,d7
        bne hook_failed
common_checks:
        jsr test_subroutine
        cmp.l #$c2c20008,d0
        bne hook_failed
        cmp.w #$1357,$bffffe
        bne hook_failed
        cmp.w #$2468,$c00000
        bne hook_failed
        cmp.w #$beef,$dffffe
        bne hook_failed
        movem.l (sp)+,d0-d7/a0-a6
        move.w (sp)+,sr
        jmp RESET_PC
hook_failed:
        stop #$2700
        bra hook_failed
test_subroutine:
        move.l #$c2c20008,d0
        rts
