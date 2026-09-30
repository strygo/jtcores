; Flat QSound diagnostic (build_controls.py `qsound` and `qsmirror` controls,
; patch 0006). RESET_PC is the verified original reset vector, supplied by
; the builder. Reached from the patched reset vector. After the extension
; window checks of game_hook.s it draws three rows of objects, restarts the
; Z80 sound driver, plays two generated tones from the upper 8 MiB of the
; sample library twice, then restores the CPU state and jumps to the game's
; original entry.
;
; What a human should see and hear for about five seconds after power-on on
; a core with patch 0006 and the `qsound` image (marker 07, black
; background, rows 16 pixels tall near the top left):
;   row 1 (y=$30): tile codes $0100..$0107 through the NORMAL window: the
;         game's own art at those codes (it may be blank);
;   row 2 (y=$50): the same codes through the A14 ALIAS: solid color blocks
;         from the slice pattern, pens 1..8 (blue, green, red, cyan, magenta,
;         yellow, white, grey), like the `slice` control's second row;
;   row 3 (y=$70): codes $FFF1..$FFF8 through the alias: the same eight
;         colors again. Every byte of these eight tiles was downloaded above
;         the 64 MiB boundary of the image (the last 264 KiB of the slice
;         pattern), so a core that truncates the download address shows them
;         wrong or does not boot at all;
;   sound: 1 kHz for half a second (bank $80 offset 0), then 1.5 kHz for
;         about a second (bank $FF offset $FF00, looped until the stop
;         command), a short pause, and the pair once more. The stock Z80
;         driver plays them: only two descriptor rows of vs2.01 were
;         repointed, by an MRA patch, at the generated tones.
; With the `qsmirror` image (marker 01, the same tones and hook, stock region
; order) the capability is off: rows 2 and 3 show the game's own art (the
; alias is a plain mirror) and the sound commands play whatever the stock
; library holds at bank $00 offset 0 and bank $7F offset $FF00 instead of the
; tones. A core without patch 0006 rejects marker 07 and does not boot the
; `qsound` image; it runs `qsmirror` exactly as the patched core does.
;
; Sound command protocol (cpsplus/manifests/protocol/vsav2.json and the
; driver's interrupt handler at vs2.01 $0038): record bytes at the odd
; addresses of $618000 (cmd_hi +$01, cmd_lo +$03), handshake +$1F posted as
; $00, acknowledged by the Z80 with $FF, and only while the control byte at
; Z80 $CFFD ($619FFB) reads $88. The Z80 (and, on jtcps2, the QSound DSP
; with it) is held in reset until bit 3 of the output port at $804040 is
; set; the hook asserts and releases that reset so the driver boots at the
; same moment on MiSTer and in the HBMAME model, then performs the game's
; own boot handshake with it.
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
        bsr play_test
        movem.l (sp)+,d0-d7/a0-a6
        move.w (sp)+,sr
        jmp RESET_PC
hook_failed:
        stop #$2700
        bra hook_failed
test_subroutine:
        move.l #$c2c20008,d0
        rts

; Hold unit: iterations of an 18-cycle loop at 16 MHz, about a quarter of a
; second (MEASURED 0.33 s in the HBMAME model). Every wait in this hook is a
; multiple of it. The RTL gate overrides this long word with 2 (+HOLD_ADDR);
; nothing else differs between the simulated and the shipped program.
        org $a00100
hold_count:
        dc.l $38000

; Sound commands as (command, hold units after it) pairs, in the order the
; hook posts them (the RTL gate checks the same command list at the 68K's
; QSound port, +QSCMDS). The first three are the game's own preamble at boot
; (MEASURED in the HBMAME model: $00e0, $ff05 stop SE tracks, $ff00 stop all;
; without them the driver acknowledges the tone commands but keys nothing),
; then tone A, tone B, stop, once more, stop.
        org $a00104
commands:
        dc.w $00e0,1,$ff05,1,$ff00,1
        dc.w $0112,3,$0110,3,$ff00,2
        dc.w $0112,3,$0110,3,$ff00,1
commands_end:

        org $a00130
draw_test:
        ; palette 0 of the object page at VRAM $910000, full brightness
        lea $910000,a0
        lea colors(pc),a1
        moveq #15,d1
.pal:   move.w (a1)+,(a0)+
        dbra d1,.pal
        move.w #$9100,$80010a           ; CPS-A palette base: schedules the palette copy
        ; object list: object RAM page 0 ($700000), physical bank 0 after reset
        move.w #$0030,d3                ; row 1: normal window, low library
        move.w #$0100,d4
        lea $700000,a2
        bsr row
        move.w #$0050,d3                ; row 2: alias window, slice, below the 64 MiB image boundary
        move.w #$0100,d4
        lea $704000+64,a2
        bsr row
        move.w #$0070,d3                ; row 3: alias window, slice tiles downloaded above 64 MiB
        move.w #$fff1,d4
        lea $704000+128,a2
        bsr row
        move.w #$8000,$700000+192+2     ; end of list
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

; d1 = number of hold units to wait
hold:   move.l hold_count(pc),d0
.h:     subq.l #1,d0
        bne.s .h
        dbra d1,hold
        rts

play_test:
        lea $618000,a3
        ; Z80 reset through the output port: assert, then release. The driver
        ; boots now; on jtcps2 the QSound DSP comes out of reset with it.
        move.b #$00,$804041
        moveq #1,d1
        bsr hold
        move.b #$08,$804041
        ; The driver writes $77 to Z80 $CFFF ($619FFF) as its first act and,
        ; after its own init, waits there for $FF from the 68K before it enters
        ; its main loop (vs2.01 $0176). A retained $77 from an earlier run
        ; satisfies the poll at once, so a fixed unit follows the release
        ; before anything is written: the fresh driver's $77 must not land on
        ; top of our $FF (MEASURED in the HBMAME model, where the Z80 runs
        ; before the hook's reset: the driver then never left its init).
        move.l #$40000,d3
.boot:  cmpi.b #$77,$1fff(a3)
        beq.s .alive
        subq.l #1,d3
        bne.s .boot
.alive: moveq #0,d1
        bsr hold
        ; the control bytes the game writes at boot: $CFFD = $88 lets the
        ; interrupt handler take commands at all (without it the driver never
        ; acknowledges), $CFFE = $FF enables per-voice panning, $CFFF = $FF
        ; releases the main loop; the handshake byte idles at the acknowledge
        ; value. Then two units for the driver to finish its init.
        move.b #$88,$1ffb(a3)
        move.b #$ff,$1ffd(a3)
        move.b #$ff,$1fff(a3)
        move.b #$ff,$1f(a3)
        moveq #1,d1
        bsr hold
        lea commands(pc),a4
.next:  move.w (a4)+,d0
        bsr send
        move.w (a4)+,d1
        subq.w #1,d1                    ; hold takes the count minus one
        bsr hold
        cmp.l #commands_end,a4
        blo.s .next
        rts

; Post one sound command: record bytes, handshake, then wait for the ack
; (bounded so that a silent Z80 cannot stall the boot).
send:   move.w d0,d2
        lsr.w #8,d2
        move.b d2,1(a3)
        move.b d0,3(a3)
        clr.b $1f(a3)
        move.l #$8000,d3
.ack:   cmpi.b #$ff,$1f(a3)
        beq.s .done
        subq.l #1,d3
        bne.s .ack
.done:  rts

colors:
        dc.w $f000,$f00f,$f0f0,$ff00,$f0ff,$ff0f,$fff0,$ffff
        dc.w $f888,$f008,$f080,$f800,$f088,$f808,$f880,$fccc
