        org $a00000
ext_entry: jsr $000400              ; call back into original ROM, then return
        move.l #$cafebabe,d0
        rts
        org $a00100
vblank: move.w #$6789,$ff0004
        rte
        org $a02000
        dc.l $99aabbcc,$ddeeff00
