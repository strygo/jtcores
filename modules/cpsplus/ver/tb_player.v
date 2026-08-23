/* CPS+ — cpsplus_player acceptance testbench.

    Drives the player with a memory model backed by real .cpk track data
    (or synthetic tracks) prepared by gen_player_vectors.py, and checks the
    output sample stream, loop wraps (predictor snapshot/restore), restart,
    stop, fade laws and PCM passthrough.

    Memory model: 8-byte little-endian word reads with pseudo-random 3..10
    cycle latency, honouring the hold-req-until-ack contract.

    plusargs (all written by gen_player_vectors.py):
      +MEM= +GOLD= +NGOLD=          memory image, golden pairs, compare count
      +TRK_ADDR= +TRK_LEN= +LSTART= +LEND= +STEREO= +CODEC=
      +C1= +C2= +GAIN= +TGAIN=      track index registers
      +LAW= +CONST1= +CONST2=       fade law config
      +TICK= +FDIV=                 clocks/sample tick, sample ticks/frame tick
      +EXP_VOLQ14=                  expected volume divider result (opt)
      +RESTART_AT= +RESTART_DOUBLE= restart test (pairs; opt)
      +STOP_AT=                     stop test (pairs; opt)
      +F<n>_AT/_TGT/_ARG/_LOOPOFF/_RESTORE   fade events 1..3 (pairs; opt)
      +F<n>_EXP_FRAMES/_EXP_STEP/_EXP_TGT    exact fade-engine expectations
      +F<n>_CHK_SAMPLE/_EXP_SAMPLE           steady-state output check (opt)
      +EXPECT_END= +END_MIN= +END_MAX=       natural track end expectations
*/
`timescale 1ns/1ps

module tb_player;

parameter MAXM = 1<<21;      // memory image bytes
parameter MAXG = 1<<21;      // golden pairs
parameter XFADE_N = 256;     // crossfade length for the `xfade` vector

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

// ---------------------------------------------------------- plusargs ----
reg [8*400-1:0] fmem, fgold;
integer NGOLD, TRK_ADDR, TRK_LEN, LSTART, LEND, STEREO, CODEC;
integer C1, C2, GAIN, TGAIN, LAW, CONST1, CONST2, TICK, FDIV;
integer XFEN, LSTART_SMP, LEND_SMP, LCNT;
reg [8*400-1:0] flut;
integer EXP_VOLQ14, RESTART_AT, RESTART_DOUBLE, STOP_AT;
integer F_AT[1:3], F_TGT[1:3], F_ARG[1:3], F_LOOPOFF[1:3], F_RESTORE[1:3];
integer F_EXP_FRAMES[1:3], F_EXP_STEP[1:3], F_EXP_TGT[1:3];
integer F_CHK_SAMPLE[1:3], F_EXP_SAMPLE[1:3];
integer EXPECT_END, END_MIN, END_MAX;
integer tAT, tTGT, tARG, tLOOPOFF, tRESTORE, tEXP_FRAMES, tEXP_STEP, tEXP_TGT, tCHK_SAMPLE, tEXP_SAMPLE;

reg [7:0]  dmem[0:MAXM-1];
reg [31:0] gmem[0:MAXG-1];

// --------------------------------------------------------------- DUT ----
reg         cen_sample = 0, cen_frame = 0;
reg         start = 0, stop = 0;
reg         fade_trig = 0, restore_trig = 0, fade_loop_off = 0;
reg  [6:0]  fade_target = 0;
reg  [15:0] fade_arg = 0;
wire        mem_rd;
wire [31:3] mem_addr;
reg  [63:0] mem_data;
reg         mem_ack = 0;
wire signed [15:0] audio_l, audio_r;
wire        sample_vld, playing;
wire        track_done;

cpsplus_player #(.XFADE_N(XFADE_N), .XF_LUT_FILE("")) u_p(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .cen_sample     ( cen_sample    ),
    .cen_frame      ( cen_frame     ),
    .start          ( start         ),
    .stop           ( stop          ),
    .osd_pause      ( 1'b0          ),
    .trk_addr       ( TRK_ADDR[31:0]),
    .trk_len        ( TRK_LEN[31:0] ),
    .trk_loop_start ( LSTART[31:0]  ),
    .trk_loop_end   ( LEND[31:0]    ),
    .trk_stereo     ( STEREO[0]     ),
    .trk_codec      ( CODEC[0]      ),
    .trk_gain       ( GAIN[6:0]     ),
    .trk_c1         ( C1[15:0]      ),
    .trk_c2         ( C2[15:0]      ),
    .trig_gain      ( TGAIN[6:0]    ),
    .trk_xfade_en       ( XFEN[0]        ),
    .trk_loop_cnt       ( LCNT[1:0]      ),
    .trk_loop_start_smp ( LSTART_SMP[31:0] ),
    .trk_loop_end_smp   ( LEND_SMP[31:0]   ),
    .fade_law       ( LAW[1:0]      ),
    .fade_const1    ( CONST1[31:0]  ),
    .fade_const2    ( CONST2[31:0]  ),
    .fade_trig      ( fade_trig     ),
    .fade_target    ( fade_target   ),
    .fade_arg       ( fade_arg      ),
    .fade_loop_off  ( fade_loop_off ),
    .restore_trig   ( restore_trig  ),
    .mem_rd         ( mem_rd        ),
    .mem_addr       ( mem_addr      ),
    .mem_data       ( mem_data      ),
    .mem_ack        ( mem_ack       ),
    .audio_l        ( audio_l       ),
    .audio_r        ( audio_r       ),
    .sample_vld     ( sample_vld    ),
    .playing        ( playing       ),
    .track_done     ( track_done    )
);

// -------------------------------------------------------- tick engine ----
integer tick_ctr = 0;
always @(posedge clk) begin
    cen_sample <= 0;
    cen_frame  <= 0;
    if (!rst) begin
        tick_ctr <= tick_ctr + 1;
        if (tick_ctr % TICK == TICK-1)               cen_sample <= 1;
        if (tick_ctr % (TICK*FDIV) == (TICK/2))      cen_frame  <= 1;
    end
end

// -------------------------------------------------------- memory model ---
// req held until single-cycle ack; latency 3..10 clocks; little-endian
reg [15:0] mlfsr = 16'hBEEF;
wire       mlfsr_fb = mlfsr[15] ^ mlfsr[13] ^ mlfsr[12] ^ mlfsr[10];
reg [3:0]  mwait;
reg        mpend = 0;
reg [31:0] mbase;
integer k;

always @(posedge clk) begin
    mem_ack <= 0;
    if (rst) begin
        mpend <= 0;
    end else if (!mpend && mem_rd && !mem_ack) begin
        mpend <= 1;
        mbase <= {mem_addr, 3'b000};
        mwait <= 4'd2 + {1'b0, mlfsr[2:0]};
        mlfsr <= {mlfsr[14:0], mlfsr_fb};
    end else if (mpend) begin
        if (mwait == 0) begin
            for (k = 0; k < 8; k = k + 1)
                mem_data[8*k +: 8] <= dmem[mbase + k];
            mem_ack <= 1;
            mpend   <= 0;
        end else
            mwait <= mwait - 1;
    end
end

// -------------------------------------------------- collect + compare ----
integer collected = 0, gidx = 0, mism = 0;
integer done_seen = 0, done_at = -1;
reg [31:0] got;

always @(posedge clk) begin
    if (!rst && sample_vld) begin
        got = {audio_r, audio_l};
        if (gidx < NGOLD) begin
            if (got !== gmem[gidx]) begin
                mism = mism + 1;
                if (mism <= 40)
                    $display("MISMATCH pair %0d: dut %08x golden %08x",
                             gidx, got, gmem[gidx]);
            end
        end
        gidx      = gidx + 1;
        collected = collected + 1;
    end
    if (!rst && track_done) begin
        done_seen = done_seen + 1;
        done_at   = collected;
    end
end

// ------------------------------------------------------------- helpers ---
integer errors = 0;
task fail(input [8*80-1:0] msg);
    begin
        errors = errors + 1;
        $display("TB_PLAYER CHECK-FAIL: %0s", msg);
    end
endtask

task pulse_start;
    begin
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
    end
endtask

// fire fade event n and verify the fade engine numerically
task fade_event(input integer n);
    begin
        wait (collected >= F_AT[n]);
        @(negedge clk);
        if (F_RESTORE[n]) restore_trig = 1;
        else begin
            fade_trig     = 1;
            fade_target   = F_TGT[n][6:0];
            fade_arg      = F_ARG[n][15:0];
            fade_loop_off = F_LOOPOFF[n][0];
        end
        @(negedge clk);
        fade_trig = 0; restore_trig = 0; fade_loop_off = 0;
        wait (u_p.fade_act === 1'b1);
        if (u_p.frames_r !== F_EXP_FRAMES[n][31:0])
            fail("fade frames != expected");
        if (u_p.fade_step !== F_EXP_STEP[n][23:0])
            fail("fade step != expected");
        if (u_p.fade_tgt !== F_EXP_TGT[n][23:0])
            fail("fade target != expected");
        $display("[fade%0d] frames=%0d step=%0d tgt=%0d (all as expected)",
                 n, u_p.frames_r, u_p.fade_step, u_p.fade_tgt);
        wait (u_p.fade_act === 1'b0);
        if (u_p.fade_lvl !== F_EXP_TGT[n][23:0])
            fail("fade final level != target (exact-landing)");
        if (F_CHK_SAMPLE[n]) begin
            // skip 2 pairs for the volume pipeline, then check steady value
            repeat (2) begin
                @(posedge clk);
                while (sample_vld !== 1'b1) @(posedge clk);
            end
            @(posedge clk);
            while (sample_vld !== 1'b1) @(posedge clk);
            if (audio_l !== F_EXP_SAMPLE[n][15:0])
                fail("steady output after fade != expected");
            else
                $display("[fade%0d] steady output %0d ok", n,
                         $signed(audio_l));
        end
    end
endtask

// ------------------------------------------------------------- control ---
integer i, t0, dummy;
initial begin
    // defaults for optional plusargs
    NGOLD = 0; EXP_VOLQ14 = -1; RESTART_AT = 0; RESTART_DOUBLE = 0;
    STOP_AT = 0; EXPECT_END = 0; END_MIN = 0; END_MAX = 0;
    TICK = 8; FDIV = 100; LAW = 0; CONST1 = 0; CONST2 = 0;
    XFEN = 0; LSTART_SMP = 0; LEND_SMP = 0; LCNT = 0;
    for (i = 1; i <= 3; i = i + 1) begin
        F_AT[i] = 0; F_TGT[i] = 0; F_ARG[i] = 0; F_LOOPOFF[i] = 0;
        F_RESTORE[i] = 0; F_EXP_FRAMES[i] = 0; F_EXP_STEP[i] = 0;
        F_EXP_TGT[i] = 0; F_CHK_SAMPLE[i] = 0; F_EXP_SAMPLE[i] = 0;
    end

    if (!$value$plusargs("MEM=%s", fmem))          $fatal(1, "need +MEM=");
    dummy = ($value$plusargs("GOLD=%s", fgold));
    dummy = ($value$plusargs("NGOLD=%d", NGOLD));
    if (!$value$plusargs("TRK_ADDR=%d", TRK_ADDR)) $fatal(1, "need +TRK_ADDR=");
    if (!$value$plusargs("TRK_LEN=%d", TRK_LEN))   $fatal(1, "need +TRK_LEN=");
    if (!$value$plusargs("LSTART=%d", LSTART))     $fatal(1, "need +LSTART=");
    if (!$value$plusargs("LEND=%d", LEND))         $fatal(1, "need +LEND=");
    if (!$value$plusargs("STEREO=%d", STEREO))     $fatal(1, "need +STEREO=");
    if (!$value$plusargs("CODEC=%d", CODEC))       $fatal(1, "need +CODEC=");
    if (!$value$plusargs("C1=%d", C1))             $fatal(1, "need +C1=");
    if (!$value$plusargs("C2=%d", C2))             $fatal(1, "need +C2=");
    if (!$value$plusargs("GAIN=%d", GAIN))         $fatal(1, "need +GAIN=");
    if (!$value$plusargs("TGAIN=%d", TGAIN))       $fatal(1, "need +TGAIN=");
    dummy = ($value$plusargs("LAW=%d", LAW));
    dummy = ($value$plusargs("CONST1=%d", CONST1));
    dummy = ($value$plusargs("CONST2=%d", CONST2));
    dummy = ($value$plusargs("TICK=%d", TICK));
    dummy = ($value$plusargs("FDIV=%d", FDIV));
    dummy = ($value$plusargs("EXP_VOLQ14=%d", EXP_VOLQ14));
    dummy = ($value$plusargs("RESTART_AT=%d", RESTART_AT));
    dummy = ($value$plusargs("RESTART_DOUBLE=%d", RESTART_DOUBLE));
    dummy = ($value$plusargs("STOP_AT=%d", STOP_AT));
    dummy = ($value$plusargs("XFEN=%d", XFEN));
    dummy = ($value$plusargs("LCNT=%d", LCNT));
    dummy = ($value$plusargs("LSTART_SMP=%d", LSTART_SMP));
    dummy = ($value$plusargs("LEND_SMP=%d", LEND_SMP));
    if ($value$plusargs("LUT=%s", flut)) $readmemh(flut, u_p.xf_lut);
    tAT = F_AT[1];
    dummy = ($value$plusargs("F1_AT=%d", tAT));
    F_AT[1] = tAT;
    tTGT = F_TGT[1];
    dummy = ($value$plusargs("F1_TGT=%d", tTGT));
    F_TGT[1] = tTGT;
    tARG = F_ARG[1];
    dummy = ($value$plusargs("F1_ARG=%d", tARG));
    F_ARG[1] = tARG;
    tLOOPOFF = F_LOOPOFF[1];
    dummy = ($value$plusargs("F1_LOOPOFF=%d", tLOOPOFF));
    F_LOOPOFF[1] = tLOOPOFF;
    tRESTORE = F_RESTORE[1];
    dummy = ($value$plusargs("F1_RESTORE=%d", tRESTORE));
    F_RESTORE[1] = tRESTORE;
    tEXP_FRAMES = F_EXP_FRAMES[1];
    dummy = ($value$plusargs("F1_EXP_FRAMES=%d", tEXP_FRAMES));
    F_EXP_FRAMES[1] = tEXP_FRAMES;
    tEXP_STEP = F_EXP_STEP[1];
    dummy = ($value$plusargs("F1_EXP_STEP=%d", tEXP_STEP));
    F_EXP_STEP[1] = tEXP_STEP;
    tEXP_TGT = F_EXP_TGT[1];
    dummy = ($value$plusargs("F1_EXP_TGT=%d", tEXP_TGT));
    F_EXP_TGT[1] = tEXP_TGT;
    tCHK_SAMPLE = F_CHK_SAMPLE[1];
    dummy = ($value$plusargs("F1_CHK_SAMPLE=%d", tCHK_SAMPLE));
    F_CHK_SAMPLE[1] = tCHK_SAMPLE;
    tEXP_SAMPLE = F_EXP_SAMPLE[1];
    dummy = ($value$plusargs("F1_EXP_SAMPLE=%d", tEXP_SAMPLE));
    F_EXP_SAMPLE[1] = tEXP_SAMPLE;
    tAT = F_AT[2];
    dummy = ($value$plusargs("F2_AT=%d", tAT));
    F_AT[2] = tAT;
    tTGT = F_TGT[2];
    dummy = ($value$plusargs("F2_TGT=%d", tTGT));
    F_TGT[2] = tTGT;
    tARG = F_ARG[2];
    dummy = ($value$plusargs("F2_ARG=%d", tARG));
    F_ARG[2] = tARG;
    tLOOPOFF = F_LOOPOFF[2];
    dummy = ($value$plusargs("F2_LOOPOFF=%d", tLOOPOFF));
    F_LOOPOFF[2] = tLOOPOFF;
    tRESTORE = F_RESTORE[2];
    dummy = ($value$plusargs("F2_RESTORE=%d", tRESTORE));
    F_RESTORE[2] = tRESTORE;
    tEXP_FRAMES = F_EXP_FRAMES[2];
    dummy = ($value$plusargs("F2_EXP_FRAMES=%d", tEXP_FRAMES));
    F_EXP_FRAMES[2] = tEXP_FRAMES;
    tEXP_STEP = F_EXP_STEP[2];
    dummy = ($value$plusargs("F2_EXP_STEP=%d", tEXP_STEP));
    F_EXP_STEP[2] = tEXP_STEP;
    tEXP_TGT = F_EXP_TGT[2];
    dummy = ($value$plusargs("F2_EXP_TGT=%d", tEXP_TGT));
    F_EXP_TGT[2] = tEXP_TGT;
    tCHK_SAMPLE = F_CHK_SAMPLE[2];
    dummy = ($value$plusargs("F2_CHK_SAMPLE=%d", tCHK_SAMPLE));
    F_CHK_SAMPLE[2] = tCHK_SAMPLE;
    tEXP_SAMPLE = F_EXP_SAMPLE[2];
    dummy = ($value$plusargs("F2_EXP_SAMPLE=%d", tEXP_SAMPLE));
    F_EXP_SAMPLE[2] = tEXP_SAMPLE;
    tAT = F_AT[3];
    dummy = ($value$plusargs("F3_AT=%d", tAT));
    F_AT[3] = tAT;
    tTGT = F_TGT[3];
    dummy = ($value$plusargs("F3_TGT=%d", tTGT));
    F_TGT[3] = tTGT;
    tARG = F_ARG[3];
    dummy = ($value$plusargs("F3_ARG=%d", tARG));
    F_ARG[3] = tARG;
    tLOOPOFF = F_LOOPOFF[3];
    dummy = ($value$plusargs("F3_LOOPOFF=%d", tLOOPOFF));
    F_LOOPOFF[3] = tLOOPOFF;
    tRESTORE = F_RESTORE[3];
    dummy = ($value$plusargs("F3_RESTORE=%d", tRESTORE));
    F_RESTORE[3] = tRESTORE;
    tEXP_FRAMES = F_EXP_FRAMES[3];
    dummy = ($value$plusargs("F3_EXP_FRAMES=%d", tEXP_FRAMES));
    F_EXP_FRAMES[3] = tEXP_FRAMES;
    tEXP_STEP = F_EXP_STEP[3];
    dummy = ($value$plusargs("F3_EXP_STEP=%d", tEXP_STEP));
    F_EXP_STEP[3] = tEXP_STEP;
    tEXP_TGT = F_EXP_TGT[3];
    dummy = ($value$plusargs("F3_EXP_TGT=%d", tEXP_TGT));
    F_EXP_TGT[3] = tEXP_TGT;
    tCHK_SAMPLE = F_CHK_SAMPLE[3];
    dummy = ($value$plusargs("F3_CHK_SAMPLE=%d", tCHK_SAMPLE));
    F_CHK_SAMPLE[3] = tCHK_SAMPLE;
    tEXP_SAMPLE = F_EXP_SAMPLE[3];
    dummy = ($value$plusargs("F3_EXP_SAMPLE=%d", tEXP_SAMPLE));
    F_EXP_SAMPLE[3] = tEXP_SAMPLE;
    dummy = ($value$plusargs("EXPECT_END=%d", EXPECT_END));
    dummy = ($value$plusargs("END_MIN=%d", END_MIN));
    dummy = ($value$plusargs("END_MAX=%d", END_MAX));

    $readmemh(fmem, dmem);
    if (NGOLD > 0) $readmemh(fgold, gmem);

    repeat (5) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk);
    pulse_start;

    // volume divider check
    if (EXP_VOLQ14 >= 0) begin
        wait (u_p.vol_rdy === 1'b1);
        if (u_p.vol_q14 !== EXP_VOLQ14[14:0])
            fail("vol_q14 != expected");
        else
            $display("[vol] vol_q14=%0d ok", u_p.vol_q14);
    end

    // restart test: re-pulse start after RESTART_AT pairs; output must be
    // the track from sample 0 again, bit-exactly
    if (RESTART_AT > 0) begin
        wait (collected >= RESTART_AT);
        pulse_start;
        if (RESTART_DOUBLE) begin       // second start racing the first init
            repeat (3) @(negedge clk);
            pulse_start;
        end
        repeat (8) @(posedge clk);      // init flushed, no stale pulses
        gidx = 0; collected = 0;
        $display("[restart] re-started after %0d pairs, compare reset",
                 RESTART_AT);
    end

    // fade events
    if (F_AT[1] > 0) fade_event(1);
    if (F_AT[2] > 0) fade_event(2);
    if (F_AT[3] > 0) fade_event(3);

    // stop test: silence within one sample tick, nothing after
    if (STOP_AT > 0) begin
        wait (collected >= STOP_AT);
        @(negedge clk) stop = 1;
        @(negedge clk) stop = 0;
        @(posedge clk);
        if (audio_l !== 16'd0 || audio_r !== 16'd0)
            fail("output not silent right after stop");
        if (playing !== 1'b0)
            fail("still playing after stop");
        t0 = collected;
        repeat (50 * TICK) @(posedge clk);
        if (collected != t0)
            fail("sample_vld seen after stop");
        else
            $display("[stop] silent after stop, no further samples");
    end else if (NGOLD > 0) begin
        wait (gidx >= NGOLD);
    end

    // natural end expectations (drain / fade-to-zero / loop-off)
    if (EXPECT_END) begin
        wait (done_seen > 0);
        repeat (4) @(posedge clk);
        if (playing !== 1'b0) fail("playing after track_done");
        if (audio_l !== 16'd0 || audio_r !== 16'd0)
            fail("output not silent after track end");
        if (done_seen !== 1) fail("track_done pulsed more than once");
        $display("[end] track_done at %0d collected pairs", done_at);
        if (END_MAX > 0 && (done_at < END_MIN || done_at > END_MAX))
            fail("track ended at unexpected sample position");
    end

    repeat (20) @(posedge clk);
    if (mism == 0 && errors == 0)
        $display("TB_PLAYER PASS: %0d/%0d golden pairs, divergence=0, checks ok",
                 (NGOLD > 0) ? ((gidx > NGOLD) ? NGOLD : gidx) : 0, NGOLD);
    else
        $display("TB_PLAYER FAIL: %0d golden mismatches, %0d check errors",
                 mism, errors);
    $finish;
end

// watchdog: no progress and no completion
integer wl_gidx = 0, wl_ctr = 0;
always @(posedge clk) begin
    if (!rst) begin
        if (collected != wl_gidx || done_seen > 0) begin
            wl_gidx = collected;
            wl_ctr  = 0;
        end else begin
            wl_ctr = wl_ctr + 1;
            if (wl_ctr > 5000000) begin
                $display("TB_PLAYER FAIL: watchdog stall at %0d pairs",
                         collected);
                $finish;
            end
        end
    end
end

endmodule
