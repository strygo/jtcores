/*  tb_cps1_tap.v — acceptance testbench for cpsplus_cps1_tap
    ==========================================================

    Replays stimulus vectors from tb/gen_cps1_vectors.py (the validated
    sf2 Phase-0 latch-trace slice plus directed corner cases) and checks,
    against the software reference, with ZERO divergence as the bar:

      * the emitted verb-event sequence equals the golden log
        (verb, track, gain, ctrl, sup) in order;
      * `sub` (idle-byte substitution) is asserted for exactly the driven
        command values flagged as suppressed music, and low otherwise —
        i.e. the value the Z80 sees is 0xff for a mapped music command and
        the real command byte for everything else (SFX / voice / control).

    Each stimulus vector drives ONE command-latch value, held long enough
    for the 2-FF synchroniser + 3-clk stability filter + 3-clk lookup to
    settle (a real command sits in the latch for a whole ~60 Hz frame).

    Plusargs:  +CFG=<file> +TRIG=<file> +STIM=<file> +GOLD=<file> +NAME=<id>
               [+VCD=<file>]
*/
`timescale 1ns/1ps

module tb_cps1_tap;

localparam TRIG_ROWS = 256;
localparam TRIG_AW   = 8;
localparam CFG_LINES = 72;
localparam MAX_STIM  = 1<<14;
localparam MAX_GOLD  = 1<<12;
localparam HOLD      = 24;          // clks each command value is held
localparam SAMPLE    = 18;          // clk within the hold to sample `sub`

reg clk = 0;
always #5 clk = ~clk;

reg              rst;
reg  [ 7:0]      latch;
wire             sub;
wire [ 7:0]      idle_byte;
wire             evt_stb, evt_ctrl, evt_sup;
wire [ 2:0]      evt_verb;
wire [11:0]      evt_track;
wire [ 6:0]      evt_gain;
wire [15:0]      evt_argw;
wire [ 7:0]      evt_argb;
reg              cfg_we;
reg  [ 7:0]      cfg_addr;
reg  [15:0]      cfg_data;
reg              trig_we;
reg  [TRIG_AW-1:0] trig_addr;
reg  [31:0]      trig_data;

cpsplus_cps1_tap #(.TRIG_ROWS(TRIG_ROWS), .TRIG_AW(TRIG_AW)) uut (
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( 1'b1      ),
    .latch      ( latch     ),
    .sub        ( sub       ),
    .idle_byte  ( idle_byte ),
    .evt_stb    ( evt_stb   ),
    .evt_verb   ( evt_verb  ),
    .evt_track  ( evt_track ),
    .evt_gain   ( evt_gain  ),
    .evt_argw   ( evt_argw  ),
    .evt_argb   ( evt_argb  ),
    .evt_ctrl   ( evt_ctrl  ),
    .evt_sup    ( evt_sup   ),
    .cfg_we     ( cfg_we    ),
    .cfg_addr   ( cfg_addr  ),
    .cfg_data   ( cfg_data  ),
    .trig_we    ( trig_we   ),
    .trig_addr  ( trig_addr ),
    .trig_data  ( trig_data )
);

reg [23:0] cfg_mem  [0:CFG_LINES-1];
reg [31:0] trig_mem [0:TRIG_ROWS-1];
reg [39:0] stim     [0:MAX_STIM-1];
reg [79:0] gold     [0:MAX_GOLD-1];

reg [8*200:1] fname, run_name, vcd_name;
integer n_stim, n_gold, i, errors, subs_seen, events_seen;

reg  [19:0] cur_frame;
integer     gidx;

// continuous monitor: verb-event capture + compare
always @(posedge clk) begin
    if( !rst && evt_stb ) begin
        events_seen = events_seen + 1;
        if( gidx >= n_gold ) begin
            errors = errors + 1;
            $display("FAIL %0s: extra event #%0d frame=%0d verb=%0d track=%0d",
                     run_name, events_seen, cur_frame, evt_verb, evt_track);
        end else begin
            if( gold[gidx][79:60] !== cur_frame
             || gold[gidx][59:56] !== {1'b0, evt_verb}
             || gold[gidx][55:44] !== evt_track
             || gold[gidx][43:36] !== {1'b0, evt_gain}
             || gold[gidx][35:20] !== evt_argw
             || gold[gidx][19:12] !== evt_argb
             || gold[gidx][1]     !== evt_ctrl
             || gold[gidx][0]     !== evt_sup ) begin
                errors = errors + 1;
                $display("FAIL %0s: event %0d mismatch", run_name, gidx);
                $display("  got  frame=%0d verb=%0d track=%0d gain=%0d ctrl=%b sup=%b",
                    cur_frame, evt_verb, evt_track, evt_gain, evt_ctrl, evt_sup);
                $display("  want frame=%0d verb=%0d track=%0d gain=%0d ctrl=%b sup=%b",
                    gold[gidx][79:60], gold[gidx][59:56], gold[gidx][55:44],
                    gold[gidx][43:36], gold[gidx][1], gold[gidx][0]);
            end
            gidx = gidx + 1;
        end
    end
end

task drive_value( input [39:0] v );
    reg       exp_sub;
    reg [7:0] val;
    integer   k;
    begin
        cur_frame = v[39:20];
        exp_sub   = v[8];
        val       = v[7:0];
        @(negedge clk);
        latch = val;
        for( k = 0; k < HOLD; k = k+1 ) begin
            @(negedge clk);
            if( k == SAMPLE ) begin
                if( sub !== exp_sub ) begin
                    errors = errors + 1;
                    $display("FAIL %0s: sub=%b expected=%b frame=%0d value=%02x",
                             run_name, sub, exp_sub, cur_frame, val);
                end
                if( sub ) begin
                    subs_seen = subs_seen + 1;
                    if( idle_byte !== 8'hff ) begin
                        errors = errors + 1;
                        $display("FAIL %0s: idle_byte=%02x (want ff)",
                                 run_name, idle_byte);
                    end
                end
            end
        end
    end
endtask

initial begin
    if( !$value$plusargs("NAME=%s", run_name) ) run_name = "run";
    if( !$value$plusargs("CFG=%s",  fname) ) begin
        $display("FAIL: +CFG missing"); $finish; end
    $readmemh(fname, cfg_mem);
    if( !$value$plusargs("TRIG=%s", fname) ) begin
        $display("FAIL: +TRIG missing"); $finish; end
    $readmemh(fname, trig_mem);
    if( !$value$plusargs("STIM=%s", fname) ) begin
        $display("FAIL: +STIM missing"); $finish; end
    $readmemh(fname, stim);
    if( !$value$plusargs("GOLD=%s", fname) ) begin
        $display("FAIL: +GOLD missing"); $finish; end
    $readmemh(fname, gold);
    if( $value$plusargs("VCD=%s", vcd_name) ) begin
        $dumpfile(vcd_name);
        $dumpvars(0, tb_cps1_tap);
    end

    n_stim = 0;
    while( n_stim < MAX_STIM && stim[n_stim] !== 40'bx ) n_stim = n_stim + 1;
    n_gold = 0;
    while( n_gold < MAX_GOLD && gold[n_gold] !== 80'bx ) n_gold = n_gold + 1;

    errors = 0; subs_seen = 0; events_seen = 0; gidx = 0; cur_frame = 0;
    rst = 1; cfg_we = 0; trig_we = 0; latch = 8'hff;
    repeat (5) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // load the trigger table
    for( i = 0; i < TRIG_ROWS; i = i+1 ) begin
        trig_we   = 1;
        trig_addr = i[TRIG_AW-1:0];
        trig_data = trig_mem[i];
        @(negedge clk);
    end
    trig_we = 0;
    // load the protocol config
    for( i = 0; i < CFG_LINES; i = i+1 ) begin
        cfg_we   = 1;
        cfg_addr = cfg_mem[i][23:16];
        cfg_data = cfg_mem[i][15:0];
        @(negedge clk);
    end
    cfg_we = 0;
    repeat (8) @(negedge clk);      // let the lookup settle post-load

    for( i = 0; i < n_stim; i = i+1 )
        drive_value( stim[i] );

    repeat (10) @(negedge clk);

    if( gidx !== n_gold ) begin
        errors = errors + 1;
        $display("FAIL %0s: %0d events emitted, %0d expected",
                 run_name, gidx, n_gold);
    end
    if( errors == 0 )
        $display("PASS %0s: values=%0d events=%0d subs=%0d",
                 run_name, n_stim, events_seen, subs_seen);
    else
        $display("RESULT %0s: %0d ERRORS", run_name, errors);
    $finish;
end

endmodule
