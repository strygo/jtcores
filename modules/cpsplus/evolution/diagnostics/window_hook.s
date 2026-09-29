; Plaintext code inside the original 4 MiB window, above the key's encrypted
; bound, in an all-FF cave of the stock program (WINDOW_HOOK from the builder).
; It must execute unmodified by the decryptor; stock jtcps2 garbles it.
;
; hook2: leaves the witness in D7 and enters the extension hook's second entry.
; hook3 (assembled with HOLD_ADDR): first spins on the long word the builder
; stores at HOLD_ADDR in the extension (about 3.5 s at 0x300000; the RTL run
; overrides it with 2). A garbled fetch of this code faults into the game's
; exception handler, which restarts the game at once, so only a core that
; really executes plaintext above the bound shows the delay.
        org WINDOW_HOOK
        ifd HOLD_ADDR
        move.l HOLD_ADDR,d0
.hold:  subq.l #1,d0
        bne.s .hold
        endif
        move.l #$c2c25a5a,d7
        jmp $a00200
