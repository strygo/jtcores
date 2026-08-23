/* CPS+ — cpsplus_ddr unit acceptance testbench.
    ==============================================

    Drives cpsplus_ddr alone against a behavioral MiSTer DDRAM model
    backed by images from gen_chain_vectors.py --mode ddr (a tiny
    synthetic pack written by pack/format.py, the normative layout
    writer).  Checks:

      * boot: MRA-header pack-pointer dereference (base_indirect), the
        exact trigger config image (all 72 words vs the Tables.cfg_words
        golden), the exact trigger table image (TRIG_ROWS rows incl.
        zero fill), MODE.enable written LAST (no cfg/table write after
        it, enable never set before the tables are complete), fade
        law/constants latched for the player;
      * fail-open: corrupted magic and no-pack (0xFFFF pointer) images
        leave the module disabled with the right status code and no
        MODE.enable write ever issued;
      * verb service: play -> index lookup -> exact trk_* register set +
        start pulse (both tracks); stop/fade/fade-keep/restore/master-
        fade -> the mapped player pulses, fade target = min(argb*4,127);
      * memory backend: sequential word reads return the image bytes
        (little-endian) with single-cycle acks; a loop-wrap style back
        jump and a far jump (track switch) re-fetch correctly; misses
        while disabled return dummy acks (no deadlock);
      * OSD toggle: disable rewrites MODE with enable=0 + player stop,
        re-enable rewrites MODE with enable=1;
      * reboot (pack switch): a second boot_go reloads to ready again.

    plusargs: see gen_chain_vectors.py build_ddr().
*/
`timescale 1ns/1ps

module tb_ddr;

// self-heal retry period, shortened for sim (hardware default 2**23 ~ 87 ms)
localparam RETRY_W = 15;
localparam SAME_SONG = 1;   // exercise the CPS1 re-send guard
localparam TRIG_AW   = 13;
localparam TRIG_ROWS = 4608;
localparam MAXM      = 1<<16;      // image bytes

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

// ------------------------------------------------------------- plusargs ---
reg [8*400-1:0] fwin, fcfg, ftrig;
integer WBASE, WSIZE, BASE, INDIRECT, EXPECT_FAIL, NCFG, NTRIG;
integer LAW, CONST1, CONST2;
integer T0_TRACK, T0_GAINT, T0_ADDR, T0_LEN, T0_LSTART, T0_LEND;
integer T0_STEREO, T0_CODEC, T0_GAIN, T0_C1, T0_C2, T0_RATE;
integer T1_TRACK, T1_GAINT, T1_ADDR, T1_LEN, T1_LSTART, T1_LEND;
integer T1_STEREO, T1_CODEC, T1_GAIN, T1_C1, T1_C2, T1_RATE;

// ------------------------------------------------------------------ DUT ---
reg  [31:0] base_addr;
reg         base_indirect, osd_en, boot_go;
wire        ready, magic_ok;
wire [ 3:0] status;
reg         evt_stb;
reg  [ 2:0] evt_verb;
reg  [11:0] evt_track;
reg  [ 6:0] evt_gain;
reg  [15:0] evt_argw;
reg  [ 7:0] evt_argb;
wire        cfg_we, trig_we;
wire [ 7:0] cfg_addr;
wire [15:0] cfg_data;
wire [TRIG_AW-1:0] trig_addr;
wire [31:0] trig_data;
wire        pl_start, pl_stop;
wire [31:0] trk_addr, trk_len, trk_lstart, trk_lend;
wire        trk_stereo, trk_codec;
wire [ 6:0] trk_gain, trig_gain;
wire [15:0] trk_c1, trk_c2, trk_rate;
wire [ 1:0] fade_law;
wire [31:0] fade_const1, fade_const2;
wire        fade_trig, fade_loop_off, restore_trig;
wire [ 6:0] fade_target;
wire [15:0] fade_arg;
reg         pmem_rd;
reg  [31:3] pmem_addr;
wire [63:0] pmem_data;
wire        pmem_ack;
wire        ddram_busy, ddram_rd;
wire [ 7:0] ddram_burstcnt;
wire [28:0] ddram_addr;
reg  [63:0] ddram_dout;
reg         ddram_dout_ready;

cpsplus_ddr #(.TRIG_AW(TRIG_AW), .TRIG_ROWS(TRIG_ROWS), .TRK_AW(7),
              .RETRY_W(RETRY_W), .SAME_SONG(SAME_SONG)) u_ddr(
    .rst            ( rst            ),
    .clk            ( clk            ),
    .base_addr      ( base_addr      ),
    .base_indirect  ( base_indirect  ),
    .osd_en         ( osd_en         ),
    .boot_go        ( boot_go        ),
    .ready          ( ready          ),
    .magic_ok       ( magic_ok       ),
    .status         ( status         ),
    .evt_stb        ( evt_stb        ),
    .evt_verb       ( evt_verb       ),
    .evt_track      ( evt_track      ),
    .evt_gain       ( evt_gain       ),
    .evt_argw       ( evt_argw       ),
    .evt_argb       ( evt_argb       ),
    .cfg_we         ( cfg_we         ),
    .cfg_addr       ( cfg_addr       ),
    .cfg_data       ( cfg_data       ),
    .trig_we        ( trig_we        ),
    .trig_addr      ( trig_addr      ),
    .trig_data      ( trig_data      ),
    .pl_start       ( pl_start       ),
    .pl_stop        ( pl_stop        ),
    .trk_addr       ( trk_addr       ),
    .trk_len        ( trk_len        ),
    .trk_lstart     ( trk_lstart     ),
    .trk_lend       ( trk_lend       ),
    .trk_stereo     ( trk_stereo     ),
    .trk_codec      ( trk_codec      ),
    .trk_gain       ( trk_gain       ),
    .trk_c1         ( trk_c1         ),
    .trk_c2         ( trk_c2         ),
    .trk_rate       ( trk_rate       ),
    .trig_gain      ( trig_gain      ),
    .fade_law       ( fade_law       ),
    .fade_const1    ( fade_const1    ),
    .fade_const2    ( fade_const2    ),
    .fade_trig      ( fade_trig      ),
    .fade_loop_off  ( fade_loop_off  ),
    .restore_trig   ( restore_trig   ),
    .fade_target    ( fade_target    ),
    .fade_arg       ( fade_arg       ),
    .pmem_rd        ( pmem_rd        ),
    .pmem_addr      ( pmem_addr      ),
    .pmem_data      ( pmem_data      ),
    .pmem_ack       ( pmem_ack       ),
    .ddram_busy     ( ddram_busy     ),
    .ddram_burstcnt ( ddram_burstcnt ),
    .ddram_addr     ( ddram_addr     ),
    .ddram_dout     ( ddram_dout     ),
    .ddram_dout_ready( ddram_dout_ready ),
    .ddram_rd       ( ddram_rd       )
);

// ------------------------------------------------- MiSTer DDRAM model ----
// Request accepted on a !busy cycle; burstcnt beats follow with random
// latency and inter-beat gaps.  Reads outside the window return zeros.
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
            q_gap            <= {2'd0, dlfsr[8:7]};       // 0-3 idle cycles
            if (q_left == 9'd1) q_run <= 0;
        end
    end
end

// ----------------------------------------------------- write monitors ----
reg [15:0] shadow_cfg [0:255];
reg [31:0] shadow_trig[0:TRIG_ROWS-1];
integer    mode_en_seen, table_after_en, cfg_after_en;
integer    stop_pulses, start_pulses;
reg        en_state;    // last MODE enable bit written

always @(posedge clk) if (!rst) begin
    if (cfg_we) begin
        shadow_cfg[cfg_addr] <= cfg_data;
        if (cfg_addr == 8'h07) begin
            en_state <= cfg_data[0];
            if (cfg_data[0]) mode_en_seen <= mode_en_seen + 1;
        end else if (en_state)
            cfg_after_en <= cfg_after_en + 1;
    end
    if (trig_we) begin
        shadow_trig[trig_addr] <= trig_data;
        if (en_state) table_after_en <= table_after_en + 1;
    end
    if (pl_stop)  stop_pulses  <= stop_pulses + 1;
    if (pl_start) start_pulses <= start_pulses + 1;
end

// ----------------------------------------------------------- helpers ----
integer errors;
task fail(input [8*80-1:0] msg);
    begin
        errors = errors + 1;
        $display("TB_DDR CHECK-FAIL: %0s", msg);
    end
endtask

task chk32(input [31:0] got, input [31:0] want, input [8*32-1:0] what);
    if (got !== want) begin
        errors = errors + 1;
        $display("TB_DDR CHECK-FAIL: %0s got %08x want %08x",
                 what, got, want);
    end
endtask

// pulse/value capture for the fade/restore outputs
reg        saw_fade, saw_restore;
reg [ 6:0] cap_tgt;
reg        cap_loopoff;
reg [15:0] cap_arg;
always @(posedge clk) if (!rst) begin
    if (fade_trig) begin
        saw_fade    <= 1;
        cap_tgt     <= fade_target;
        cap_loopoff <= fade_loop_off;
        cap_arg     <= fade_arg;
    end
    if (restore_trig) saw_restore <= 1;
end

// send one verb event
task evt(input [2:0] verb, input [11:0] track, input [6:0] gain,
         input [15:0] argw, input [7:0] argb);
    begin
        @(negedge clk);
        evt_stb   = 1;
        evt_verb  = verb;
        evt_track = track;
        evt_gain  = gain;
        evt_argw  = argw;
        evt_argb  = argb;
        @(negedge clk);
        evt_stb = 0;
        repeat (14) @(negedge clk);    // >= 12 clk event spacing contract
    end
endtask

// one player-port word read; returns data, checks single-cycle ack
reg [63:0] rd_data;
integer rd_wait;
task pread(input [31:0] byte_addr);
    begin
        @(negedge clk);
        pmem_rd   = 1;
        pmem_addr = byte_addr[31:3];
        rd_wait   = 0;
        @(posedge clk);
        while (pmem_ack !== 1'b1 && rd_wait < 2000) begin
            rd_wait = rd_wait + 1;
            @(posedge clk);
        end
        if (rd_wait >= 2000) fail("pmem read timeout");
        rd_data = pmem_data;
        @(negedge clk);
        pmem_rd = 0;
        @(posedge clk);
        if (pmem_ack === 1'b1) fail("ack longer than one cycle");
    end
endtask

// ------------------------------------------------------------ control ----
integer i, j, t, dummy, boot_t;
reg [63:0] exp_w;
reg [23:0] cfg_gold [0:255];
reg [31:0] trig_gold[0:TRIG_ROWS-1];

initial begin
    EXPECT_FAIL = 0; NCFG = 0; NTRIG = 0;
    LAW = 0; CONST1 = 0; CONST2 = 0;
    errors = 0; mode_en_seen = 0; table_after_en = 0; cfg_after_en = 0;
    stop_pulses = 0; start_pulses = 0; en_state = 0;
    saw_fade = 0; saw_restore = 0;
    evt_stb = 0; pmem_rd = 0; boot_go = 0; osd_en = 1;

    if (!$value$plusargs("WIN=%s", fwin))     $fatal(1, "need +WIN=");
    if (!$value$plusargs("WBASE=%d", WBASE))  $fatal(1, "need +WBASE=");
    if (!$value$plusargs("WSIZE=%d", WSIZE))  $fatal(1, "need +WSIZE=");
    if (!$value$plusargs("BASE=%d", BASE))    $fatal(1, "need +BASE=");
    if (!$value$plusargs("INDIRECT=%d", INDIRECT)) $fatal(1, "need +INDIRECT=");
    dummy = $value$plusargs("EXPECT_FAIL=%d", EXPECT_FAIL);
    dummy = $value$plusargs("CFG_GOLD=%s", fcfg);
    dummy = $value$plusargs("TRIG_GOLD=%s", ftrig);
    dummy = $value$plusargs("NCFG=%d", NCFG);
    dummy = $value$plusargs("NTRIG=%d", NTRIG);
    dummy = $value$plusargs("LAW=%d", LAW);
    dummy = $value$plusargs("CONST1=%d", CONST1);
    dummy = $value$plusargs("CONST2=%d", CONST2);
    dummy = $value$plusargs("T0_TRACK=%d",  T0_TRACK);
    dummy = $value$plusargs("T0_GAIN_TRIG=%d", T0_GAINT);
    dummy = $value$plusargs("T0_ADDR=%d",   T0_ADDR);
    dummy = $value$plusargs("T0_LEN=%d",    T0_LEN);
    dummy = $value$plusargs("T0_LSTART=%d", T0_LSTART);
    dummy = $value$plusargs("T0_LEND=%d",   T0_LEND);
    dummy = $value$plusargs("T0_STEREO=%d", T0_STEREO);
    dummy = $value$plusargs("T0_CODEC=%d",  T0_CODEC);
    dummy = $value$plusargs("T0_GAIN=%d",   T0_GAIN);
    dummy = $value$plusargs("T0_C1=%d",     T0_C1);
    dummy = $value$plusargs("T0_C2=%d",     T0_C2);
    dummy = $value$plusargs("T0_RATE=%d",   T0_RATE);
    dummy = $value$plusargs("T1_TRACK=%d",  T1_TRACK);
    dummy = $value$plusargs("T1_GAIN_TRIG=%d", T1_GAINT);
    dummy = $value$plusargs("T1_ADDR=%d",   T1_ADDR);
    dummy = $value$plusargs("T1_LEN=%d",    T1_LEN);
    dummy = $value$plusargs("T1_LSTART=%d", T1_LSTART);
    dummy = $value$plusargs("T1_LEND=%d",   T1_LEND);
    dummy = $value$plusargs("T1_STEREO=%d", T1_STEREO);
    dummy = $value$plusargs("T1_CODEC=%d",  T1_CODEC);
    dummy = $value$plusargs("T1_GAIN=%d",   T1_GAIN);
    dummy = $value$plusargs("T1_C1=%d",     T1_C1);
    dummy = $value$plusargs("T1_C2=%d",     T1_C2);
    dummy = $value$plusargs("T1_RATE=%d",   T1_RATE);

    $readmemh(fwin, dmem);
    if (NCFG  > 0) $readmemh(fcfg,  cfg_gold);
    if (NTRIG > 0) $readmemh(ftrig, trig_gold);

    base_addr     = BASE[31:0];
    base_indirect = INDIRECT[0];

    repeat (5) @(negedge clk);
    rst = 0;
    repeat (5) @(negedge clk);
    boot_go = 1;
    @(negedge clk);
    boot_go = 0;

    // ------------------------------------------------ fail-open images ---
    if (EXPECT_FAIL != 0) begin
        boot_t = 0;
        while (status !== EXPECT_FAIL[3:0] && boot_t < 500000) begin
            @(posedge clk);
            boot_t = boot_t + 1;
        end
        if (status !== EXPECT_FAIL[3:0]) fail("expected fail status");
        repeat (100) @(posedge clk);
        if (ready !== 1'b0)      fail("ready on a bad pack");
        if (mode_en_seen !== 0)  fail("MODE.enable written on a bad pack");
        if (EXPECT_FAIL == 5 && magic_ok !== 1'b0)
            fail("magic_ok on corrupted magic");
        // player-port reads must dummy-ack, not deadlock
        pread(32'h30001000);
        if (rd_data !== 64'd0) fail("dummy ack not zero");
        if (errors == 0)
            $display("TB_DDR PASS: fail-open status=%0d, no enable, dummy acks",
                     status);
        else
            $display("TB_DDR FAIL: %0d check errors", errors);
        $finish;
    end

    // ------------------------------------------------------- good boot ---
    boot_t = 0;
    while (ready !== 1'b1 && boot_t < 500000) begin
        @(posedge clk);
        boot_t = boot_t + 1;
    end
    if (ready !== 1'b1) begin
        fail("boot timeout");
        $display("TB_DDR FAIL: %0d check errors", errors);
        $finish;
    end
    repeat (4) @(posedge clk);      // let the monitors settle
    if (magic_ok !== 1'b1) fail("magic_ok low after good boot");
    if (status !== 4'd2)   fail("status != ok");
    if (mode_en_seen !== 1)     fail("MODE.enable written != once");
    if (table_after_en !== 0)   fail("table writes after MODE.enable");
    if (cfg_after_en !== 0)     fail("cfg writes after MODE.enable");
    $display("[boot] ready after %0d cycles", boot_t);

    // exact config image
    for (i = 0; i < NCFG; i = i+1)
        if (shadow_cfg[cfg_gold[i][23:16]] !== cfg_gold[i][15:0]) begin
            errors = errors + 1;
            $display("TB_DDR CHECK-FAIL: cfg[%02x] got %04x want %04x",
                     cfg_gold[i][23:16], shadow_cfg[cfg_gold[i][23:16]],
                     cfg_gold[i][15:0]);
        end
    $display("[boot] %0d config words exact", NCFG);
    // exact trigger table incl. zero fill
    j = 0;
    for (i = 0; i < NTRIG; i = i+1)
        if (shadow_trig[i] !== trig_gold[i]) begin
            j = j + 1;
            if (j <= 10)
                $display("TB_DDR CHECK-FAIL: trig[%04x] got %08x want %08x",
                         i, shadow_trig[i], trig_gold[i]);
        end
    if (j != 0) begin
        errors = errors + 1;
        $display("TB_DDR CHECK-FAIL: %0d trigger rows differ", j);
    end else
        $display("[boot] %0d trigger rows exact", NTRIG);
    // player config
    chk32({30'd0, fade_law}, LAW[31:0],   "fade_law");
    chk32(fade_const1,       CONST1[31:0], "fade_const1");
    chk32(fade_const2,       CONST2[31:0], "fade_const2");

    // ------------------------------------------------------ play verbs ---
    for (t = 0; t < 2; t = t+1) begin
        start_pulses = 0;
        evt(3'd1, t ? T1_TRACK[11:0] : T0_TRACK[11:0],
            t ? T1_GAINT[6:0] : T0_GAINT[6:0], 16'h0000, 8'h00);
        if (start_pulses !== 1) fail("play: start pulse count");
        chk32(trk_addr,   t ? T1_ADDR   : T0_ADDR,   "trk_addr");
        chk32(trk_len,    t ? T1_LEN    : T0_LEN,    "trk_len");
        chk32(trk_lstart, t ? T1_LSTART : T0_LSTART, "trk_lstart");
        chk32(trk_lend,   t ? T1_LEND   : T0_LEND,   "trk_lend");
        chk32({31'd0, trk_stereo}, t ? T1_STEREO : T0_STEREO, "trk_stereo");
        chk32({31'd0, trk_codec},  t ? T1_CODEC  : T0_CODEC,  "trk_codec");
        chk32({25'd0, trk_gain},   t ? T1_GAIN   : T0_GAIN,   "trk_gain");
        chk32({16'd0, trk_c1},     t ? T1_C1     : T0_C1,     "trk_c1");
        chk32({16'd0, trk_c2},     t ? T1_C2     : T0_C2,     "trk_c2");
        chk32({16'd0, trk_rate},   t ? T1_RATE   : T0_RATE,   "trk_rate");
        chk32({25'd0, trig_gain},  t ? T1_GAINT  : T0_GAINT,  "trig_gain");
        $display("[play] track %0d registers exact", t ? T1_TRACK : T0_TRACK);
    end

    // ---------------------------------------------------- memory reads ---
    // sequential stream (prefetch path)
    for (i = 0; i < 40; i = i+1) begin
        pread(T0_ADDR + i*8);
        exp_w = word_at(T0_ADDR[31:3] + i[28:0]);
        if (rd_data !== exp_w) begin
            errors = errors + 1;
            $display("TB_DDR CHECK-FAIL: seq word %0d got %016x want %016x",
                     i, rd_data, exp_w);
        end
    end
    // loop-wrap style back jump
    for (i = 0; i < 8; i = i+1) begin
        pread(T0_ADDR + T0_LSTART + i*8);
        exp_w = word_at(T0_ADDR[31:3] + T0_LSTART[31:3] + i[28:0]);
        if (rd_data !== exp_w) fail("wrap-jump word mismatch");
    end
    // far jump (track switch)
    pread(T1_ADDR);
    exp_w = word_at(T1_ADDR[31:3]);
    if (rd_data !== exp_w) fail("far-jump word mismatch");
    $display("[mem] sequential + wrap + far-jump reads exact");

    // ---------------------------------------------------- control verbs ---
    stop_pulses = 0;
    evt(3'd2, 12'd0, 7'd0, 16'h0000, 8'h00);
    if (stop_pulses !== 1) fail("verb 2: no stop pulse");

    saw_fade = 0;
    evt(3'd3, 12'd0, 7'd0, 16'h0200, 8'h10);
    if (saw_fade !== 1'b1)      fail("verb 3: no fade_trig");
    else begin
        if (cap_loopoff !== 1'b1) fail("verb 3: loop_off low");
        if (cap_tgt !== 7'd64)    fail("verb 3: target != 16*4");
        if (cap_arg !== 16'h0200) fail("verb 3: arg");
    end

    saw_fade = 0;
    evt(3'd4, 12'd0, 7'd0, 16'h0800, 8'h40);
    if (saw_fade !== 1'b1)      fail("verb 4: no fade_trig");
    else begin
        if (cap_loopoff !== 1'b0) fail("verb 4: loop_off high");
        if (cap_tgt !== 7'd127)   fail("verb 4: target not clamped");
    end

    saw_restore = 0;
    evt(3'd5, 12'd0, 7'd0, 16'h0000, 8'h00);
    if (saw_restore !== 1'b1) fail("verb 5: no restore_trig");

    saw_fade = 0;
    evt(3'd6, 12'd0, 7'd0, 16'h0300, 8'hff);
    if (saw_fade !== 1'b1)     fail("verb 6: no fade_trig");
    else begin
        if (cap_tgt !== 7'd0)     fail("verb 6: target != 0");
        if (cap_arg !== 16'h0300) fail("verb 6: arg");
    end
    $display("[verbs] stop/fade/fade-keep/restore/master-fade mapped");

    // ------------------------------------------------------- OSD toggle ---
    stop_pulses = 0;
    osd_en = 0;
    repeat (20) @(posedge clk);
    if (shadow_cfg[8'h07][0] !== 1'b0) fail("osd off: MODE.enable still 1");
    if (stop_pulses !== 1)             fail("osd off: no player stop");
    osd_en = 1;
    repeat (20) @(posedge clk);
    if (shadow_cfg[8'h07][0] !== 1'b1) fail("osd on: MODE.enable still 0");
    $display("[osd] disable/enable rewrites MODE + stop");

    // --------------------------------------------------------- reboot ----
    en_state = 0;   // shadow reset for the ordering monitors
    mode_en_seen = 0; table_after_en = 0; cfg_after_en = 0;
    @(negedge clk);
    boot_go = 1;
    @(negedge clk);
    boot_go = 0;
    repeat (4) @(posedge clk);      // ready drops before we poll it
    if (ready !== 1'b0) fail("reboot: ready did not drop");
    boot_t = 0;
    while (ready !== 1'b1 && boot_t < 500000) begin
        @(posedge clk);
        boot_t = boot_t + 1;
    end
    if (ready !== 1'b1)       fail("reboot timeout");
    repeat (4) @(posedge clk);
    if (mode_en_seen !== 1)   fail("reboot: MODE.enable count");
    if (table_after_en !== 0) fail("reboot: table writes after enable");
    $display("[reboot] pack reload ok (%0d cycles)", boot_t);

    // ----------------------------------------------------- late reset ----
    // Reproduces the MEASURED MiSTer failure (2026-07-22): the core asserts
    // its startup reset AFTER the download completed and the loader began,
    // wiping the load; boot_go is a one-shot on the ioctl_rom falling edge so
    // it never fires again and the pack stayed unloaded forever (silence on
    // all three cores).  The loader must recover WITHOUT a second boot_go.
    en_state = 0;
    mode_en_seen = 0; table_after_en = 0; cfg_after_en = 0;
    @(negedge clk);
    rst = 1;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst = 0;                        // note: boot_go deliberately NOT pulsed
    repeat (4) @(posedge clk);
    if (ready !== 1'b0) fail("late reset: ready did not drop");
    boot_t = 0;
    while (ready !== 1'b1 && boot_t < 5000000) begin
        @(posedge clk);
        boot_t = boot_t + 1;
    end
    if (ready !== 1'b1)
        fail("late reset: pack never reloaded without boot_go (self-heal retry failed)");
    else
        $display("[latereset] self-healed with NO boot_go (%0d cycles)", boot_t);

    // ------------------------------------------------ same-song re-send ----
    // Measured on hardware: a CPS1 driver IGNORES a music command identical to
    // the song already playing (Final Fight re-sends 0x28 ~2 s apart and the
    // YM2151 shows no start burst).  A repeat must NOT restart; a different
    // track must still start; a STOP must re-arm the same track.
    start_pulses = 0;
    evt(3'd1, 12'd0, 7'h7f, 16'd0, 8'd0);      // play track 0
    repeat (300) @(posedge clk);
    if (start_pulses !== 1) fail("same-song: first play did not start");
    evt(3'd1, 12'd0, 7'h7f, 16'd0, 8'd0);      // SAME track again -> ignored
    repeat (300) @(posedge clk);
    if (start_pulses !== 1) fail("same-song: a re-sent command restarted the track");
    evt(3'd1, 12'd1, 7'h7f, 16'd0, 8'd0);      // different track -> must start
    repeat (300) @(posedge clk);
    if (start_pulses !== 2) fail("same-song: a different track failed to start");
    evt(3'd2, 12'd0, 7'd0, 16'd0, 8'd0);       // STOP re-arms
    repeat (60) @(posedge clk);
    evt(3'd1, 12'd1, 7'h7f, 16'd0, 8'd0);      // same track, but after a stop
    repeat (300) @(posedge clk);
    if (start_pulses !== 3) fail("same-song: STOP did not re-arm the same track");
    $display("[samesong] repeat ignored, different track starts, STOP re-arms");

    if (errors == 0)
        $display("TB_DDR PASS: boot/fail-open/verbs/mem/osd/reboot/latereset/samesong all ok");
    else
        $display("TB_DDR FAIL: %0d check errors", errors);
    $finish;
end

// global watchdog
initial begin
    #200_000_000;
    $display("TB_DDR FAIL: global watchdog");
    $finish;
end

endmodule
