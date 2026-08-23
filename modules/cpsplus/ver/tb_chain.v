/* CPS+ — full-chain acceptance testbench (Phase 3).
    ==================================================

    Instantiates the complete CPS+ stack (cpsplus_top = trigger + ddr +
    player) against a behavioral MiSTer DDRAM model backed by a windowed
    image of the REAL work/packs/hsf2_arrange.cpk (gen_chain_vectors.py
    --mode chain documents the windowing: header + tables + track 54's
    data relocated to data_offset 0; other tracks read as zeros).

    The run covers, in one session:
      * boot: MRA-header pointer dereference + full pack load, MODE
        enable last, ready/magic status;
      * the Phase-2 hsf2 fight-log bus vectors (frames 5509-6350):
        driver init/stop control records, two suppressed plays
        (0x0036 -> track 53, 0x0037 -> track 54) with `gate` checked on
        exactly the suppressed handshake writes, SFX records in between;
      * golden verb-event sequence (classified from the pack tables —
        the same semantics the validated Phase-2 prototype logged);
      * PCM sample-exactness: from the track-54 play, the output stream
        must equal pack.audition.render (intro + loop passes) with the
        exact RTL volume law — compared across >= 1 predictor
        snapshot/restore loop wrap (wrap at pair 681,696 of 690,000);
      * one fade: injected HSF2-law 0xff06 (0x444/0x444 x 60 frames to
        silence) — fade engine frames/step/target checked exactly;
      * one stop: the driver-style 0xff00 mid-fade — silence and no
        further samples.

    Stimulus/golden formats: gen_chain_vectors.py header.
*/
`timescale 1ns/1ps

module tb_chain;

localparam MAXM     = 1<<20;      // window image bytes
localparam MAX_STIM = 1<<10;
localparam MAX_GOLD = 1<<7;
localparam MAX_PCM  = 1<<20;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// ------------------------------------------------------------- plusargs ---
reg [8*400-1:0] fwin, fstim, fevt, fgold;
integer WBASE, WSIZE, BASE, INDIRECT, NGOLD, RESET_EVT, VQ14;
integer FADE_EXP_FRAMES, FADE_EXP_STEP, FADE_EXP_TGT, TICK, FDIV;

// ------------------------------------------------------------------ DUT ---
reg  [23:1] m_addr;
reg  [15:0] m_dout;
reg  [ 1:0] m_dsn;
reg         m_rnw, m_cs;
wire        gate;
reg         cen_sample, cen_frame;
wire signed [15:0] audio_l, audio_r;
wire        sample_vld, playing, ready, magic_ok;
wire [ 3:0] status;
wire [15:0] trk_rate;
reg         osd_en, boot_go;
wire        ddram_busy, ddram_rd;
wire [ 7:0] ddram_burstcnt;
wire [28:0] ddram_addr;
reg  [63:0] ddram_dout;
reg         ddram_dout_ready;

cpsplus_top u_dut(
    .rst            ( rst            ),
    .clk            ( clk            ),
    .main_addr      ( m_addr         ),
    .main_dout      ( m_dout         ),
    .dsn            ( m_dsn          ),
    .main_rnw       ( m_rnw          ),
    .main2qs_cs     ( m_cs           ),
    .gate           ( gate           ),
    .cen_sample     ( cen_sample     ),
    .cen_frame      ( cen_frame      ),
    .osd_pause      ( 1'b0           ),
    .audio_l        ( audio_l        ),
    .audio_r        ( audio_r        ),
    .sample_vld     ( sample_vld     ),
    .playing        ( playing        ),
    .trk_rate       ( trk_rate       ),
    .base_addr      ( BASE[31:0]     ),
    .base_indirect  ( INDIRECT[0]    ),
    .osd_en         ( osd_en         ),
    .boot_go        ( boot_go        ),
    .ready          ( ready          ),
    .magic_ok       ( magic_ok       ),
    .status         ( status         ),
    .ddram_busy     ( ddram_busy     ),
    .ddram_burstcnt ( ddram_burstcnt ),
    .ddram_addr     ( ddram_addr     ),
    .ddram_dout     ( ddram_dout     ),
    .ddram_dout_ready( ddram_dout_ready ),
    .ddram_rd       ( ddram_rd       )
);

// --------------------------------------------------------- tick engine ----
integer tick_ctr = 0;
always @(posedge clk) begin
    cen_sample <= 0;
    cen_frame  <= 0;
    if (!rst) begin
        tick_ctr <= tick_ctr + 1;
        if (tick_ctr % TICK == TICK-1)          cen_sample <= 1;
        if (tick_ctr % (TICK*FDIV) == (TICK/2)) cen_frame  <= 1;
    end
end

// ------------------------------------------------- MiSTer DDRAM model ----
reg  [ 7:0] dmem [0:MAXM-1];
reg  [15:0] dlfsr = 16'hACE1;
wire        dfb = dlfsr[15]^dlfsr[13]^dlfsr[12]^dlfsr[10];
reg         q_run = 0;
reg  [28:0] q_addr;
reg  [ 8:0] q_left;
reg  [ 3:0] q_gap;
wire        mbusy = dlfsr[2:0] == 3'd0;

assign ddram_busy = mbusy | q_run;

function [63:0] word_at(input [28:0] wa);
    integer k;
    reg [31:0] ba;
    begin
        word_at = 64'd0;
        ba = {wa, 3'b000} - WBASE[31:0];
        for (k = 0; k < 8; k = k+1)
            if (ba + k < WSIZE[31:0] && !ba[31])
                word_at[8*k +: 8] = dmem[ba[19:0] + k];
    end
endfunction

always @(posedge clk) begin
    ddram_dout_ready <= 0;
    dlfsr <= {dlfsr[14:0], dfb};
    if (rst) begin
        q_run <= 0;
    end else if (!q_run) begin
        if (ddram_rd && !ddram_busy) begin
            q_run  <= 1;
            q_addr <= ddram_addr;
            q_left <= {1'b0, ddram_burstcnt};
            q_gap  <= 4'd2 + {2'd0, dlfsr[6:5]};
        end
    end else begin
        if (q_gap != 0)
            q_gap <= q_gap - 4'd1;
        else begin
            ddram_dout       <= word_at(q_addr);
            ddram_dout_ready <= 1;
            q_addr           <= q_addr + 29'd1;
            q_left           <= q_left - 9'd1;
            q_gap            <= {3'd0, dlfsr[7]};        // 0-1 idle cycles
            if (q_left == 9'd1) q_run <= 0;
        end
    end
end

// ------------------------------------------------ vectors + goldens ------
reg [95:0] stim [0:MAX_STIM-1];
reg [79:0] gold [0:MAX_GOLD-1];
reg [31:0] pcm  [0:MAX_PCM-1];
integer n_stim, n_gold;

// ------------------------------------------------ event + gate monitor ---
integer errors = 0, gidx_ev = 0;
reg     drive_act = 0, exp_gate = 0, gate_seen;
reg     arm_reset = 0, cmp_en = 0;
integer collected = 0, gidx = 0, mism = 0;
reg [31:0] got;

task fail(input [8*80-1:0] msg);
    begin
        errors = errors + 1;
        $display("TB_CHAIN CHECK-FAIL: %0s", msg);
    end
endtask

always @(posedge clk) if (!rst) begin
    // gate legality: only during stimulus cycles that expect it
    if (gate) begin
        if (!drive_act || !exp_gate) begin
            errors = errors + 1;
            $display("TB_CHAIN CHECK-FAIL: unexpected gate at t=%0t", $time);
        end
        gate_seen = 1;
    end
    // verb-event sequence (frame field of the golden is reference-only)
    if (u_dut.evt_stb === 1'b1) begin
        if (gidx_ev >= n_gold) begin
            errors = errors + 1;
            $display("TB_CHAIN CHECK-FAIL: extra event verb=%0d track=%0d",
                     u_dut.evt_verb, u_dut.evt_track);
        end else begin
            if (gold[gidx_ev][59:56] !== {1'b0, u_dut.evt_verb}
             || gold[gidx_ev][55:44] !== u_dut.evt_track
             || gold[gidx_ev][43:36] !== {1'b0, u_dut.evt_gain}
             || gold[gidx_ev][35:20] !== u_dut.evt_argw
             || gold[gidx_ev][19:12] !== u_dut.evt_argb
             || gold[gidx_ev][1]     !== u_dut.evt_ctrl
             || gold[gidx_ev][0]     !== u_dut.evt_sup) begin
                errors = errors + 1;
                $display("TB_CHAIN CHECK-FAIL: event %0d mismatch:", gidx_ev);
                $display("  got  verb=%0d track=%0d gain=%0d argw=%04x argb=%02x ctrl=%b sup=%b",
                    u_dut.evt_verb, u_dut.evt_track, u_dut.evt_gain,
                    u_dut.evt_argw, u_dut.evt_argb, u_dut.evt_ctrl,
                    u_dut.evt_sup);
                $display("  want verb=%0d track=%0d gain=%0d argw=%04x argb=%02x ctrl=%b sup=%b",
                    gold[gidx_ev][59:56], gold[gidx_ev][55:44],
                    gold[gidx_ev][43:36], gold[gidx_ev][35:20],
                    gold[gidx_ev][19:12], gold[gidx_ev][1], gold[gidx_ev][0]);
            end
            if (gidx_ev == RESET_EVT)
                arm_reset <= 1;      // reset PCM compare on this play's init
            gidx_ev = gidx_ev + 1;
        end
    end
    // PCM collection: reset the counters exactly when the designated
    // play's restart takes effect inside the player (init_go clears
    // sample_vld on the same edge, so no pair can slip past the reset)
    if (arm_reset && u_dut.u_player.init_go === 1'b1) begin
        arm_reset <= 0;
        cmp_en    <= 1;
        collected  = 0;
        gidx       = 0;
    end else if (sample_vld) begin
        got = {audio_r, audio_l};
        if (cmp_en && gidx < NGOLD) begin
            if (got !== pcm[gidx]) begin
                mism = mism + 1;
                if (mism <= 40)
                    $display("TB_CHAIN MISMATCH pair %0d: dut %08x golden %08x",
                             gidx, got, pcm[gidx]);
            end
            gidx = gidx + 1;
        end
        collected = collected + 1;
    end
end

// ------------------------------------------------------- bus driving -----
task drive_vector(input [95:0] v);
    integer thr;
    begin
        thr = v[95:64];
        wait (collected >= thr);
        exp_gate  = v[60];
        gate_seen = 0;
        @(negedge clk);
        m_addr    = v[58:36];
        m_dout    = v[35:20];
        m_dsn     = v[19:18];
        m_rnw     = v[17];
        m_cs      = v[16];
        drive_act = 1;
        repeat (6) @(negedge clk);
        m_dsn     = 2'b11;
        m_cs      = 1'b0;
        m_rnw     = 1'b1;
        drive_act = 0;
        repeat (6) @(negedge clk);
        if (gate_seen !== exp_gate) begin
            errors = errors + 1;
            $display("TB_CHAIN CHECK-FAIL: gate=%b expected=%b addr=%06x dout=%04x",
                     gate_seen, exp_gate, {v[58:36],1'b0}, v[35:20]);
        end
    end
endtask

// fade engine numeric check (hierarchical, as tb_player does)
integer fwait;
task fade_check;
    begin
        fwait = 0;
        while (u_dut.u_player.fade_act !== 1'b1 && fwait < 20000) begin
            @(posedge clk);
            fwait = fwait + 1;
        end
        if (u_dut.u_player.fade_act !== 1'b1)
            fail("fade never activated");
        else begin
            if (u_dut.u_player.frames_r !== FADE_EXP_FRAMES[31:0])
                fail("fade frames != expected");
            if (u_dut.u_player.fade_step !== FADE_EXP_STEP[23:0])
                fail("fade step != expected");
            if (u_dut.u_player.fade_tgt !== FADE_EXP_TGT[23:0])
                fail("fade target != expected");
            $display("[fade] frames=%0d step=%0d tgt=%0d (all as expected)",
                     u_dut.u_player.frames_r, u_dut.u_player.fade_step,
                     u_dut.u_player.fade_tgt);
        end
    end
endtask

integer stop_mark;
task stop_check;
    begin
        repeat (64) @(posedge clk);          // evt service + stop settle
        if (audio_l !== 16'd0 || audio_r !== 16'd0)
            fail("output not silent after stop");
        if (playing !== 1'b0)
            fail("still playing after stop");
        stop_mark = collected;
        repeat (50 * TICK) @(posedge clk);
        if (collected != stop_mark)
            fail("samples emitted after stop");
        else
            $display("[stop] silent after stop, no further samples");
    end
endtask

// ------------------------------------------------------------ control ----
integer i, dummy, boot_t;
initial begin
    NGOLD = 0; RESET_EVT = -1; VQ14 = -1;
    FADE_EXP_FRAMES = 0; FADE_EXP_STEP = 0; FADE_EXP_TGT = 0;
    TICK = 8; FDIV = 100;
    m_addr = 0; m_dout = 0; m_dsn = 2'b11; m_rnw = 1; m_cs = 0;
    osd_en = 1; boot_go = 0;

    if (!$value$plusargs("WIN=%s", fwin))       $fatal(1, "need +WIN=");
    if (!$value$plusargs("WBASE=%d", WBASE))    $fatal(1, "need +WBASE=");
    if (!$value$plusargs("WSIZE=%d", WSIZE))    $fatal(1, "need +WSIZE=");
    if (!$value$plusargs("BASE=%d", BASE))      $fatal(1, "need +BASE=");
    if (!$value$plusargs("INDIRECT=%d", INDIRECT)) $fatal(1, "need +INDIRECT=");
    if (!$value$plusargs("STIM=%s", fstim))     $fatal(1, "need +STIM=");
    if (!$value$plusargs("EVT=%s", fevt))       $fatal(1, "need +EVT=");
    if (!$value$plusargs("GOLD=%s", fgold))     $fatal(1, "need +GOLD=");
    if (!$value$plusargs("NGOLD=%d", NGOLD))    $fatal(1, "need +NGOLD=");
    if (!$value$plusargs("RESET_EVT=%d", RESET_EVT)) $fatal(1, "need +RESET_EVT=");
    dummy = $value$plusargs("VQ14=%d", VQ14);
    dummy = $value$plusargs("FADE_EXP_FRAMES=%d", FADE_EXP_FRAMES);
    dummy = $value$plusargs("FADE_EXP_STEP=%d", FADE_EXP_STEP);
    dummy = $value$plusargs("FADE_EXP_TGT=%d", FADE_EXP_TGT);
    dummy = $value$plusargs("TICK=%d", TICK);
    dummy = $value$plusargs("FDIV=%d", FDIV);

    $readmemh(fwin,  dmem);
    $readmemh(fstim, stim);
    $readmemh(fevt,  gold);
    $readmemh(fgold, pcm);

    n_stim = 0;
    while (n_stim < MAX_STIM && stim[n_stim] !== 96'bx) n_stim = n_stim + 1;
    n_gold = 0;
    while (n_gold < MAX_GOLD && gold[n_gold] !== 80'bx) n_gold = n_gold + 1;

    repeat (5) @(negedge clk);
    rst = 0;
    repeat (5) @(negedge clk);

    // ------------------------------------------------------------ boot ---
    boot_go = 1;
    @(negedge clk);
    boot_go = 0;
    boot_t = 0;
    while (ready !== 1'b1 && boot_t < 500000) begin
        @(posedge clk);
        boot_t = boot_t + 1;
    end
    if (ready !== 1'b1) begin
        fail("boot timeout");
        $display("TB_CHAIN FAIL: %0d errors", errors);
        $finish;
    end
    if (magic_ok !== 1'b1) fail("magic_ok low");
    if (status !== 4'd2)   fail("status != ok");
    $display("[boot] pack loaded via MRA pointer in %0d cycles", boot_t);

    // -------------------------------------------------------- stimulus ---
    for (i = 0; i < n_stim; i = i + 1) begin
        drive_vector(stim[i]);
        if (stim[i][61]) fade_check;        // flag bit1: injected fade
        if (stim[i][62]) stop_check;        // flag bit2: driver stop
    end

    // -------------------------------------------------------- verdicts ---
    if (gidx_ev !== n_gold) begin
        errors = errors + 1;
        $display("TB_CHAIN CHECK-FAIL: %0d events, %0d expected",
                 gidx_ev, n_gold);
    end
    if (gidx < NGOLD) begin
        errors = errors + 1;
        $display("TB_CHAIN CHECK-FAIL: only %0d of %0d golden pairs compared",
                 gidx, NGOLD);
    end
    if (VQ14 >= 0 && u_dut.u_player.vol_q14 !== VQ14[14:0])
        fail("vol_q14 != expected");

    repeat (20) @(posedge clk);
    if (mism == 0 && errors == 0)
        $display("TB_CHAIN PASS: %0d events, %0d/%0d golden pairs, divergence=0",
                 gidx_ev, (gidx > NGOLD) ? NGOLD : gidx, NGOLD);
    else
        $display("TB_CHAIN FAIL: %0d golden mismatches, %0d check errors",
                 mism, errors);
    $finish;
end

// stall watchdog: no sample progress and no completion
integer wl_col = 0, wl_ctr = 0;
always @(posedge clk) begin
    if (!rst) begin
        if (collected != wl_col) begin
            wl_col = collected;
            wl_ctr = 0;
        end else begin
            wl_ctr = wl_ctr + 1;
            if (wl_ctr > 8000000) begin
                $display("TB_CHAIN FAIL: watchdog stall at %0d pairs",
                         collected);
                $finish;
            end
        end
    end
end

endmodule
