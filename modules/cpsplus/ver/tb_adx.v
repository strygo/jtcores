/* CPS+ — cpsplus_adx acceptance testbench.

    Feeds a header-stripped ADX frame stream (extracted from a real .cpk by
    gen_adx_vectors.py) into the decoder through the byte valid/ready port
    with pseudo-random stalls on both sides, and compares every output
    sample pair bit-exactly against the adxcodec.py py_decode golden.

    plusargs (written by gen_adx_vectors.py into plusargs.txt):
      +STREAM=<stream.hex>  byte stream, one hex byte per line
      +GOLD=<golden.hex>    golden pairs, one 32-bit hex word {R,L} per line
      +NBYTES=<n> +NPAIRS=<n> +STEREO=<0|1>
      +C1=<u16> +C2=<u16>   predictor coefficients, two's-complement in 16 bits

    Pass criterion: NPAIRS pairs compared, divergence = 0.
*/
`timescale 1ns/1ps

module tb_adx;

parameter MAXB = 1<<23;      // stream bytes capacity
parameter MAXP = 1<<21;      // golden pairs capacity

reg         clk = 0;
reg         rst = 1;
always #5 clk = ~clk;

reg  [7:0]  smem[0:MAXB-1];
reg  [31:0] gmem[0:MAXP-1];
reg  [8*400-1:0] fstream, fgold;
integer     nbytes, npairs, stereo_i, c1_i, c2_i;

reg  [15:0] c1_r, c2_r;
reg         stereo_r;

// DUT hookup
reg  [31:0] bidx;
wire [7:0]  din       = smem[bidx[22:0]];
wire        din_valid;
wire        din_ready;
wire signed [15:0] pcm_l, pcm_r;
wire        pcm_valid;
reg         pcm_ready_r;
wire [63:0] hist_out;

cpsplus_adx dut(
    .rst        ( rst          ),
    .clk        ( clk          ),
    .clr        ( 1'b0         ),
    .stereo     ( stereo_r     ),
    .c1         ( c1_r         ),
    .c2         ( c2_r         ),
    .din        ( din          ),
    .din_valid  ( din_valid    ),
    .din_ready  ( din_ready    ),
    .pcm_l      ( pcm_l        ),
    .pcm_r      ( pcm_r        ),
    .pcm_valid  ( pcm_valid    ),
    .pcm_ready  ( pcm_ready_r  ),
    .hist_out   ( hist_out     ),
    .hist_in    ( 64'd0        ),
    .hist_load  ( 1'b0         ),
    .busy       (              ),
    .eof        (              )
);

// pseudo-random stalls, fixed seeds -> deterministic
reg [15:0] lfsr_a = 16'hACE1, lfsr_b = 16'h5EED;
wire lfsr_a_fb = lfsr_a[15] ^ lfsr_a[13] ^ lfsr_a[12] ^ lfsr_a[10];
wire lfsr_b_fb = lfsr_b[15] ^ lfsr_b[13] ^ lfsr_b[12] ^ lfsr_b[10];

assign din_valid = (bidx < nbytes) && (lfsr_a[2:0] != 3'd0);  // ~87% duty

always @(posedge clk) begin
    if (!rst) begin
        lfsr_a <= {lfsr_a[14:0], lfsr_a_fb};
        lfsr_b <= {lfsr_b[14:0], lfsr_b_fb};
        pcm_ready_r <= (lfsr_b[3:0] != 4'd0);                 // ~94% duty
        if (din_valid && din_ready)
            bidx <= bidx + 1;
    end
end

// capture + compare
integer gidx, mism;
reg [31:0] got;
always @(posedge clk) begin
    if (!rst && pcm_valid && pcm_ready_r) begin
        got = {pcm_r, pcm_l};
        if (gidx < npairs) begin
            if (got !== gmem[gidx]) begin
                mism = mism + 1;
                if (mism <= 10)
                    $display("MISMATCH pair %0d: dut %08x golden %08x",
                             gidx, got, gmem[gidx]);
            end
        end
        gidx = gidx + 1;
    end
end

// watchdog: fail on stall
integer last_gidx, stall_ctr;
always @(posedge clk) begin
    if (!rst) begin
        if (gidx != last_gidx) begin
            last_gidx = gidx;
            stall_ctr = 0;
        end else begin
            stall_ctr = stall_ctr + 1;
            if (stall_ctr > 2000000) begin
                $display("TB_ADX FAIL: stalled at pair %0d/%0d", gidx, npairs);
                $finish;
            end
        end
    end
end

initial begin
    bidx = 0; gidx = 0; mism = 0; last_gidx = 0; stall_ctr = 0;
    pcm_ready_r = 0;
    if (!$value$plusargs("STREAM=%s", fstream)) $fatal(1, "need +STREAM=");
    if (!$value$plusargs("GOLD=%s",   fgold))   $fatal(1, "need +GOLD=");
    if (!$value$plusargs("NBYTES=%d", nbytes))  $fatal(1, "need +NBYTES=");
    if (!$value$plusargs("NPAIRS=%d", npairs))  $fatal(1, "need +NPAIRS=");
    if (!$value$plusargs("STEREO=%d", stereo_i))$fatal(1, "need +STEREO=");
    if (!$value$plusargs("C1=%d",     c1_i))    $fatal(1, "need +C1=");
    if (!$value$plusargs("C2=%d",     c2_i))    $fatal(1, "need +C2=");
    $readmemh(fstream, smem);
    $readmemh(fgold,   gmem);
    c1_r     = c1_i[15:0];
    c2_r     = c2_i[15:0];
    stereo_r = stereo_i[0];
    repeat (5) @(posedge clk);
    rst = 0;
    wait (gidx >= npairs);
    repeat (10) @(posedge clk);
    if (mism == 0)
        $display("TB_ADX PASS: %0d pairs compared, divergence=0", gidx);
    else
        $display("TB_ADX FAIL: %0d pairs compared, %0d mismatches",
                 gidx, mism);
    $finish;
end

endmodule
