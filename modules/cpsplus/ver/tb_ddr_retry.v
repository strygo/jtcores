/* CPS+ — cpsplus_ddr self-heal retry regression.

    Reproduces the MEASURED MiSTer hardware failure (2026-07-22):

      1. the ROM+pack download completes, boot_go pulses, the loader starts;
      2. the core then asserts its startup reset -- AFTER the loader began --
         wiping the load back to idle (status 0, ready 0);
      3. boot_go is a one-shot on the ioctl_rom falling edge, so it NEVER
         fires again and the pack is never loaded.  Silence forever.

    On hardware this presented as "status latched non-zero but live status 0"
    (DBG beep round 4 = 6 beeps, round 3 = 3 beeps) on all three cores.

    The fix under test: cpsplus_ddr retries from idle/fail until ready, so the
    load completes on its own after that late reset with no second boot_go.

    Reuses the vectors from gen_chain_vectors.py --mode ddr (win_ind.hex etc).
    RETRY_W is shrunk so the retry lands in a few thousand sim cycles.
*/
`timescale 1ns/1ps

module tb_ddr_retry;

localparam TRIG_AW = 13, TRIG_ROWS = 4608;
localparam RETRY_W = 8;                       // 256 clks between attempts in sim

reg         clk = 0, rst = 1, boot_go = 0, osd_en = 1;
always #5.2 clk = ~clk;                       // ~96 MHz

// ---- behavioral DDRAM window (same shape as tb_ddr.v) -------------------
reg  [31:0] WBASE, WSIZE, BASE;
reg  [63:0] win [0:65535];
reg  [63:0] ddram_dout;
reg         ddram_dout_ready = 0, ddram_busy = 0;
wire        ddram_rd;
wire [ 7:0] ddram_burstcnt;
wire [28:0] ddram_addr;

reg  [ 8:0] beats = 0;
reg  [28:0] cur;

// serve read bursts out of the window (same shape as tb_ddr.v)
always @(posedge clk) begin
    ddram_dout_ready <= 1'b0;
    if( ddram_rd && beats==0 ) begin
        cur   <= ddram_addr;
        beats <= {1'b0, ddram_burstcnt};
    end else if( beats!=0 ) begin
        ddram_dout       <= win[ (({cur,3'd0} - WBASE) >> 3) ];
        ddram_dout_ready <= 1'b1;
        cur              <= cur + 1'd1;
        beats            <= beats - 1'd1;
    end
end

wire        ready, magic_ok;
wire [ 3:0] status;

cpsplus_ddr #(.TRIG_AW(TRIG_AW), .TRIG_ROWS(TRIG_ROWS), .TRK_AW(7),
              .RETRY_W(RETRY_W)) u_ddr(
    .rst            ( rst            ),
    .clk            ( clk            ),
    .base_addr      ( BASE           ),
    .base_indirect  ( 1'b1           ),
    .osd_en         ( osd_en         ),
    .boot_go        ( boot_go        ),
    .ready          ( ready          ),
    .magic_ok       ( magic_ok       ),
    .status         ( status         ),
    // event port idle: this TB only exercises the load path
    .evt_stb        ( 1'b0           ),
    .evt_verb       ( 3'd0           ),
    .evt_track      ( 12'd0          ),
    .evt_gain       ( 7'd0           ),
    .evt_argw       ( 16'd0          ),
    .evt_argb       ( 8'd0           ),
    .pmem_rd        ( 1'b0           ),
    .pmem_addr      ( 32'd0          ),
    .ddram_busy     ( ddram_busy     ),
    .ddram_burstcnt ( ddram_burstcnt ),
    .ddram_addr     ( ddram_addr     ),
    .ddram_dout     ( ddram_dout     ),
    .ddram_dout_ready( ddram_dout_ready ),
    .ddram_rd       ( ddram_rd       )
);

integer cyc;
reg  [1023:0] fwin;

initial begin
    if( !$value$plusargs("WIN=%s",   fwin)  ) $fatal(1,"need +WIN=");
    if( !$value$plusargs("WBASE=%d", WBASE) ) $fatal(1,"need +WBASE=");
    if( !$value$plusargs("WSIZE=%d", WSIZE) ) $fatal(1,"need +WSIZE=");
    if( !$value$plusargs("BASE=%d",  BASE)  ) $fatal(1,"need +BASE=");
    $readmemh(fwin, win);

    // ---- phase 1: power-up. boot_go is deliberately NEVER pulsed, proving
    // the load no longer depends on catching that one-shot at all. ---------
    repeat(20) @(posedge clk);
    rst = 0;

    cyc = 0;
    while( !ready && cyc < 200000 ) begin
        @(posedge clk);
        cyc = cyc + 1;
    end
    if( !ready ) begin
        $display("FAIL: pack never loaded without a boot_go (status=%0d)", status);
        $finish;
    end
    $display("[phase1] loaded with NO boot_go at all: ready=1 magic_ok=%b status=%0d (%0d cycles)",
             magic_ok, status, cyc);

    // ---- phase 2: the LATE reset that broke hardware --------------------
    // Core asserts its startup reset after the loader began.  boot_go will
    // NOT be pulsed again -- exactly the hardware sequence.
    rst = 1;
    repeat(10) @(posedge clk);
    rst = 0;
    @(posedge clk);
    if( status!=4'd0 || ready!==1'b0 ) begin
        $display("FAIL: reset did not clear the loader (status=%0d ready=%b)",
                 status, ready);
        $finish;
    end
    $display("[phase2] late reset wiped the loader (status=0, ready=0), no further boot_go");

    // ---- phase 3: the retry must recover it, unaided --------------------
    cyc = 0;
    while( !ready && cyc < 200000 ) begin
        @(posedge clk);
        cyc = cyc + 1;
    end
    if( !ready ) begin
        $display("FAIL: pack never loaded after late reset (status=%0d after %0d cycles) -- retry did not self-heal", status, cyc);
        $finish;
    end
    $display("[phase3] SELF-HEALED: ready=1, magic_ok=%b, status=%0d after %0d cycles with NO second boot_go", magic_ok, status, cyc);
    $display("TB_DDR_RETRY PASS");
    $finish;
end

initial begin
    #50_000_000;
    $display("FAIL: timeout");
    $finish;
end

endmodule
