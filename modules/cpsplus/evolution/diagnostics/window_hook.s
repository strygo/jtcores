; Plaintext code inside the original 4 MiB window, above the key's encrypted
; bound, in an all-FF cave of the stock program (WINDOW_HOOK from the builder).
; It must execute unmodified by the decryptor; stock jtcps2 garbles it.
        org WINDOW_HOOK
        move.l #$c2c25a5a,d7
        jmp $a00200
