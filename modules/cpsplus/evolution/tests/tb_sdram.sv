`timescale 1ns/1ps
// jtframe_sdram64 driving two AS4C32M16SB-class chip models wired as the
// MiSTer 128 MiB module: every pin shared, SDRAM_nCS straight into chip 0 and
// through the module's inverter into chip 1. With JTFRAME_SDRAM_XL (AW=24, the
// objext profile) the controller must use both chips; without it (AW=23, the
// stock 64 MiB controller, textually upstream) the same testbench proves the
// chip model and the address contract on known-good RTL, and chip 1 must
// never decode a command. The address contract pinned here: word address bit
// 23 = chip, bits 21:9 = row, {bit 22, bits 8:0} = column, so the lower 23
// bits split as the 64 MiB module does. Every read beat is compared against a
// shadow of what was written or, for untouched words, the chip model's
// (chip, bank, row, column) pattern, so a dropped or misplaced bit shows up
// as wrong data. The chip models enforce the datasheet command rules
// (activate on an open bank, read/write on a closed bank, refresh with an
// open bank, tRCD/tRP/tRAS/tRC/tRRD/tRFC/tWR/tMRD, the power-up order).
// +MUTATE forces the controller's open-row match to ignore the chip bit
// (the 64 MiB compare): the test must then fail.
module tb_sdram;
import sdram_model_pkg::*;
`ifdef JTFRAME_SDRAM_XL
localparam AW=24, CHIPS=2;
`else
localparam AW=23, CHIPS=1;
`endif
localparam real PERIOD=10.0; // 100 MHz: the faster of the two periods jtframe's own controller tests use
localparam LINE_CLKS=6400;   // one refresh trigger per 64 us line, as jtframe_board_sdram generates it
reg clk=0;
always #(PERIOD/2) clk=~clk;
reg rst=1;
// bank requesters
reg  [AW-1:0] ba0_addr=0, ba1_addr=0, ba2_addr=0, ba3_addr=0;
reg  [3:0] rd=0, wr=0;
reg  [15:0] ba0_din=0;
reg  [1:0] ba0_dsn=2'b11;
wire [3:0] ack, dst, dok, rdy;
wire [15:0] dout;
wire init;
// programmer
reg prog_en=0, prog_wr=0;
reg [AW-1:0] prog_addr=0;
reg [15:0] prog_din=0;
reg [1:0] prog_dsn=2'b11, prog_ba=0;
wire prog_dst, prog_dok, prog_rdy, prog_ack;
reg rfsh=0;
// pins
wire [15:0] sdram_din, sdram_dq;
wire [12:0] sdram_a;
wire [1:0] sdram_ba;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;

// The CPS2 profile of jtframe_board_sdram: 64-bit bursts on banks 0/2/3, 32 on
// bank 1, 32-bit programmer, only bank 0 writable and auto-precharged.
jtframe_sdram64 #(.AW(AW), .HF(1), .SHIFTED(0), .BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(32),
    .BA0_WEN(1), .BA1_WEN(0), .BA2_WEN(0), .BA3_WEN(0), .BA0_AUTOPRECH(1), .MISTER(1), .RFSHCNT(9), .BAPRIO(1)) u_sdram(
    .rst(rst), .clk(clk), .init(init),
    .ba0_addr(ba0_addr), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(ba3_addr),
    .rd(rd), .wr(wr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn), .ba1_din(16'd0), .ba1_dsn(2'b11),
    .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
    .prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr), .prog_din(prog_din), .prog_dsn(prog_dsn),
    .prog_ba(prog_ba), .prog_dst(prog_dst), .prog_dok(prog_dok), .prog_rdy(prog_rdy), .prog_ack(prog_ack),
    .rfsh(rfsh), .ack(ack), .dst(dst), .dok(dok), .rdy(rdy), .dout(dout),
    .sdram_dq(sdram_dq), .sdram_din(sdram_din), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh),
    .sdram_ba(sdram_ba), .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
);

wire [15:0] dq0, dq1;
wire [1:0] en0, en1;
integer refresh0, refresh1, act0, act1, rd0, rd1, wr0, wr1, cmd0, cmd1, pall0, pall1;
wire idone0, idone1;
sdram_chip_model #(.ID(0)) u_chip0(.clk(clk), .cs_n(sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas), .we_n(sdram_nwe),
    .ba(sdram_ba), .a(sdram_a), .dqm({sdram_dqmh, sdram_dqml}), .din(sdram_din), .dout(dq0), .dout_en(en0),
    .refreshes(refresh0), .activates(act0), .reads(rd0), .writes(wr0), .commands(cmd0), .pre_alls(pall0), .init_done(idone0));
sdram_chip_model #(.ID(1)) u_chip1(.clk(clk), .cs_n(~sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas), .we_n(sdram_nwe), // U3, LVC1G04
    .ba(sdram_ba), .a(sdram_a), .dqm({sdram_dqmh, sdram_dqml}), .din(sdram_din), .dout(dq1), .dout_en(en1),
    .refreshes(refresh1), .activates(act1), .reads(rd1), .writes(wr1), .commands(cmd1), .pre_alls(pall1), .init_done(idone1));
// shared DQ bus and its two contention rules
assign sdram_dq[15:8] = en0[1] ? dq0[15:8] : dq1[15:8];
assign sdram_dq[7:0]  = en0[0] ? dq0[7:0]  : dq1[7:0];
reg ctrl_drive=0;
always @(posedge clk) ctrl_drive <= u_sdram.wr_cycle; // the pad register that drives DQ during writes
always @(negedge clk) if(!rst) begin
    if((en0 & en1)!=0) begin $display("ERROR: both chips drive DQ at %t", $realtime); $fatal(1); end
    if(ctrl_drive && (en0|en1)!=0) begin $display("ERROR: a chip drives DQ during the controller's write cycle at %t", $realtime); $fatal(1); end
    if(!sdram_cke) begin $display("ERROR: CKE low (tied to VCC on the module)"); $fatal(1); end
end
// refresh trigger, one per 64 us line
always begin repeat(LINE_CLKS) @(posedge clk); rfsh<=1; @(posedge clk); rfsh<=0; end

// ---------------------------------------------------------------- expectations
logic [15:0] shadow [longint];
integer beats_checked=0, words_written=0, reads_done=0, writes_done=0;

function automatic longint skey(input [1:0] bank, input [AW-1:0] addr);
    skey = {38'd0, bank, 24'(addr)};
endfunction
// the address contract under test
function automatic [15:0] expect_word(input [1:0] bank, input [AW-1:0] addr);
    longint k;
    reg [23:0] a24;
begin
    k = skey(bank, addr); a24 = 24'(addr);
    if(shadow.exists(k)) expect_word = shadow[k];
    else expect_word = sdram_pattern(AW==24 ? 32'(a24[23]) : 0, bank, a24[21:9], {a24[22], a24[8:0]});
end
endfunction
function automatic [AW-1:0] mk(input integer chip, input [12:0] row, input [9:0] col);
    reg [23:0] full;
begin
    full = {chip[0], col[9], row, col[8:0]};
    mk = full[AW-1:0];
end
endfunction
task automatic fail(input string msg);
begin
    $display("ERROR: %s at %t", msg, $realtime);
    $fatal(1);
end
endtask

// ---------------------------------------------------------------- programmer
task automatic prog_write(input [1:0] bank, input [AW-1:0] addr, input [15:0] data, input [1:0] dsn);
    reg [15:0] cur;
begin
    @(negedge clk);
    prog_addr=addr; prog_ba=bank; prog_din=data; prog_dsn=dsn; prog_wr=1;
    @(negedge clk); while(!prog_ack) @(negedge clk);
    prog_wr=0;
    cur = expect_word(bank, addr);
    if(!dsn[1]) cur[15:8]=data[15:8];
    if(!dsn[0]) cur[7:0]=data[7:0];
    shadow[skey(bank,addr)] = cur;
    words_written = words_written+1;
    // jtframe_dwnld presents the next word right after the ack; jtcps1_prom_we waits for rdy
    if($urandom%2) begin @(negedge clk); while(!prog_rdy) @(negedge clk); end
end
endtask

// ---------------------------------------------------------------- requesters
// jtframe_ramslot_ctrl / romrq style: hold rd until ack, drop it, take the data at dst, next request after rdy
task automatic set_addr(input [1:0] bank, input [AW-1:0] addr);
begin
    case(bank) 0: ba0_addr=addr; 1: ba1_addr=addr; 2: ba2_addr=addr; default: ba3_addr=addr; endcase
end
endtask
function automatic integer beats(input [1:0] bank);
    beats = bank==1 ? 2 : 4; // BA1_LEN=32
endfunction
task automatic read_check(input [1:0] bank, input [AW-1:0] addr);
    integer i;
    reg [AW-1:0] a;
    reg [15:0] exp;
begin
    @(negedge clk);
    set_addr(bank, addr); rd[bank]=1;
    @(negedge clk); while(!ack[bank]) @(negedge clk);
    rd[bank]=0;
    while(!dst[bank]) @(negedge clk);
    for(i=0;i<beats(bank);i=i+1) begin
        a = addr; a[1:0] = addr[1:0]+i[1:0]; // sequential burst, wrapping in the four-word group
        exp = expect_word(bank, a);
        if($test$plusargs("SDRAM_TRACE")) $display("    tb t=%0t bank %0d beat %0d word %h dout=%h exp=%h dst=%b rdy=%b", $realtime, bank, i, a, dout, exp, dst, rdy);
        if(dout!==exp) fail($sformatf("bank %0d word %h beat %0d: read %h, expected %h", bank, a, i, dout, exp));
        beats_checked = beats_checked+1;
        if(i==beats(bank)-1) begin
            if(!rdy[bank]) fail($sformatf("bank %0d: rdy missing with the last beat", bank));
        end else begin
            if(rdy[bank]) fail($sformatf("bank %0d: rdy before the last beat", bank));
            @(negedge clk);
        end
    end
    reads_done = reads_done+1;
end
endtask
task automatic write_check(input [AW-1:0] addr, input [15:0] data, input [1:0] dsn);
    reg [15:0] cur;
begin
    @(negedge clk);
    ba0_addr=addr; ba0_din=data; ba0_dsn=dsn; wr[0]=1;
    @(negedge clk); while(!ack[0]) @(negedge clk);
    wr[0]=0;
    while(!rdy[0]) @(negedge clk);
    cur = expect_word(0, addr);
    if(!dsn[1]) cur[15:8]=data[15:8];
    if(!dsn[0]) cur[7:0]=data[7:0];
    shadow[skey(0,addr)] = cur;
    writes_done = writes_done+1;
end
endtask
function automatic [1:0] some_mask;
    reg [1:0] m;
begin
    m = $urandom;
    some_mask = m==2'b11 ? 2'b00 : m;
end
endfunction
function automatic [AW-1:0] rnd_addr(input integer chip);
    rnd_addr = mk(chip, $urandom, $urandom);
endfunction
reg [AW-1:0] wlist [0:3][0:4095];
integer nwritten [0:3];
function automatic [AW-1:0] written_or_random(input [1:0] bank, input integer chip);
    // half the traffic revisits written words, the rest is fresh
    written_or_random = ($urandom%2 && nwritten[bank]>0) ? wlist[bank][$urandom%nwritten[bank]] : rnd_addr(chip);
endfunction
task automatic remember(input [1:0] bank, input [AW-1:0] addr);
begin
    if(nwritten[bank]<4096) begin wlist[bank][nwritten[bank]]=addr; nwritten[bank]=nwritten[bank]+1; end
end
endtask

// +MUTATE: the 64 MiB open-row compare (row bits only, chip ignored)
reg [3:0] match_nochip=0;
always @(posedge clk) begin
    match_nochip[0] <= u_sdram.u_latch.ba0_addr[21:9] === u_sdram.u_latch.ba0_row[12:0];
    match_nochip[1] <= u_sdram.u_latch.ba1_addr[21:9] === u_sdram.u_latch.ba1_row[12:0];
    match_nochip[2] <= u_sdram.u_latch.ba2_addr[21:9] === u_sdram.u_latch.ba2_row[12:0];
    match_nochip[3] <= u_sdram.u_latch.ba3_addr[21:9] === u_sdram.u_latch.ba3_row[12:0];
end
initial if($test$plusargs("MUTATE")) begin
    $display("MUTATION: open-row match ignores the chip bit");
    force u_sdram.u_latch.match = match_nochip;
end

// ---------------------------------------------------------------- scenarios
integer k, c, bank, r0, r1, a0, a1, base_act0, base_act1, base_pall0, base_pall1, ms;
integer snap_r0, snap_r1, snap_reads, snap_writes;
reg [12:0] row;
reg [AW-1:0] addr;
initial begin
    for(k=0;k<4;k=k+1) nwritten[k]=0;
    repeat(5) @(negedge clk);
    rst=0;
    // 1. initialization: one JEDEC sequence per chip (u_init repeats it for chip 1)
    @(negedge clk); while(init) @(negedge clk);
    repeat(4) @(negedge clk);
    if(!idone0) fail("chip 0 not initialized");
    if(CHIPS==2) begin
        if(!idone1) fail("chip 1 not initialized (precharge all, 2 refreshes, load mode)");
        if(u_chip0.cl!=2 || u_chip1.cl!=2 || u_chip0.bl!=4 || u_chip1.bl!=4 || !u_chip0.wr_single || !u_chip1.wr_single)
            fail("mode registers differ from CL=2, BL=4, single writes");
        $display("PASS sdram init: both chips precharged, refreshed %0d/%0d times and mode-set (CL=2, BL=4) before the first activate", u_chip0.refreshes, u_chip1.refreshes);
    end else begin
        if(cmd1!=0) fail($sformatf("64 MiB controller: chip 1 (inverted CS) decoded %0d commands", cmd1));
        $display("PASS sdram init: 64 MiB controller initialized chip 0 (%0d refreshes); chip 1 behind the inverted CS decoded 0 commands", u_chip0.refreshes);
    end
    // 2. programmer: every bank, both halves, the 64 MiB boundary, aliasing pairs
    @(negedge clk); prog_en=1; repeat(4) @(negedge clk);
    for(bank=0;bank<4;bank=bank+1) begin
        if(CHIPS==2) for(k=-4;k<4;k=k+1) begin // words 0x7ffffc..0x800003
            addr = 24'h800000 + k;
            prog_write(bank, addr, $urandom, 2'b00); remember(bank, addr);
        end
        for(k=0;k<16;k=k+1) begin // the same row and column in both chips must hold different data
            row=$urandom; a0=$urandom;
            for(c=0;c<CHIPS;c=c+1) begin
                addr = mk(c, row, a0[9:0]);
                prog_write(bank, addr, $urandom, 2'b00); remember(bank, addr);
            end
        end
        for(k=0;k<48*CHIPS;k=k+1) begin
            addr = rnd_addr(k%CHIPS);
            prog_write(bank, addr, $urandom, some_mask()); remember(bank, addr);
            if($urandom%4==0) begin prog_write(bank, addr, $urandom, some_mask()); end // second write, other bytes
        end
    end
    @(negedge clk); while(!prog_rdy && prog_wr) @(negedge clk);
    repeat(8) @(negedge clk); prog_en=0; repeat(8) @(negedge clk);
    // 3. read everything back in a random order
    for(k=0;k<600;k=k+1) begin
        bank=$urandom%4;
        read_check(bank, wlist[bank][$urandom%nwritten[bank]]);
    end
    if(CHIPS==2) $display("PASS sdram prog: %0d words written through the programmer across the 64 MiB boundary in every bank and %0d bursts read back correctly (shadow + pattern)", words_written, reads_done);
    else $display("PASS sdram prog: %0d words written through the programmer and %0d bursts read back correctly (shadow + pattern)", words_written, reads_done);
    // 4. alternating chips back to back in one bank: a row open in chip 0, the
    //    same bank in chip 1, back to chip 0; same row bits and different rows.
    base_act0=act0; base_act1=act1;
    for(bank=1;bank<4;bank=bank+1) for(k=0;k<64;k=k+1) begin
        row=$urandom;
        read_check(bank, mk(0, row, $urandom));
        read_check(bank, mk(CHIPS-1, row, $urandom));
        read_check(bank, mk(0, row, $urandom));
        read_check(bank, mk(CHIPS-1, row, $urandom));
        read_check(bank, mk(CHIPS-1, row, $urandom));       // row hit within the same chip
        read_check(bank, mk(0, row^13'h0101, $urandom));    // different row
        read_check(bank, mk(CHIPS-1, row, $urandom));
    end
    if(CHIPS==2 && (act1-base_act1 < 3*64*3 || act0-base_act0 < 3*64*3)) fail("alternation did not activate both chips");
    // bank 0, auto-precharged and writable, alternating chips too
    for(k=0;k<64;k=k+1) begin
        row=$urandom; a0=$urandom;
        write_check(mk(0, row, a0[9:0]), $urandom, some_mask());
        write_check(mk(CHIPS-1, row, a0[9:0]), $urandom, some_mask());
        read_check(0, mk(0, row, a0[9:0]));
        read_check(0, mk(CHIPS-1, row, a0[9:0]));
        read_check(0, mk(0, row, a0[9:0]));
    end
    $display("PASS sdram alternation: banks 1-3 read alternating chips in the same bank and row (%0d/%0d activates on chip 0/1), bank 0 written and read alternating chips, data correct",
             act0-base_act0, act1-base_act1);
    // 5. programmer restart with rows open in both chips: the programmer's
    //    precharge-all only reaches one chip, so the other chip must be
    //    precharged before its first activate (the chip model rejects an
    //    activate on an open bank otherwise). Both orders.
    for(k=0;k<2;k=k+1) begin
        for(bank=1;bank<4;bank=bank+1) for(c=0;c<CHIPS;c=c+1) read_check(bank, rnd_addr(c)); // rows open everywhere
        @(negedge clk); prog_en=1; repeat(4) @(negedge clk);
        base_pall0=pall0; base_pall1=pall1;
        c = CHIPS==2 ? k : 0;
        prog_write(1, rnd_addr(c), $urandom, 2'b00);
        prog_write(1, rnd_addr(CHIPS==2 ? 1-c : 0), $urandom, 2'b00);
        prog_write(3, rnd_addr(CHIPS==2 ? 1-c : 0), $urandom, 2'b00);
        prog_write(3, rnd_addr(c), $urandom, 2'b00);
        prog_write(2, rnd_addr(c), $urandom, 2'b00);
        @(negedge clk); while(!prog_rdy && prog_wr) @(negedge clk);
        repeat(8) @(negedge clk); prog_en=0; repeat(8) @(negedge clk);
        if(CHIPS==2 && (pall0-base_pall0<1 || pall1-base_pall1<1)) fail("programmer restart did not precharge-all both chips");
        for(bank=1;bank<4;bank=bank+1) for(c=0;c<CHIPS;c=c+1) read_check(bank, rnd_addr(c));
    end
    if(CHIPS==2) $display("PASS sdram prog restart: with rows open in both chips, the programmer precharged each chip before activating it, both orders");
    else $display("PASS sdram prog restart: with rows open, the programmer precharged the chip before activating it");
    // 6. long random traffic on four banks with the refresh trigger running:
    //    per-chip refresh coverage (>= 8192 in a 64 ms window), row age
    //    (tRAS max), data on every beat.
    snap_r0=0; snap_r1=0; snap_reads=reads_done; snap_writes=writes_done;
    fork
        begin : traffic0
            forever begin
                if($urandom%3==0) write_check(written_or_random(0, $urandom%CHIPS), $urandom, some_mask());
                else read_check(0, written_or_random(0, $urandom%CHIPS));
                repeat($urandom%24) @(negedge clk);
            end
        end
        begin : traffic1
            forever begin read_check(1, written_or_random(1, $urandom%CHIPS)); repeat($urandom%16) @(negedge clk); end
        end
        begin : traffic2
            forever begin read_check(2, written_or_random(2, $urandom%CHIPS)); repeat($urandom%8) @(negedge clk); end
        end
        begin : traffic3
            forever begin read_check(3, written_or_random(3, $urandom%CHIPS)); repeat($urandom%32) @(negedge clk); end
        end
        begin : timer
            #(5_000_000); snap_r0=refresh0; snap_r1=refresh1;      // 5 ms
            #(64_000_000);                                          // 69 ms
        end
    join_any
    disable traffic0; disable traffic1; disable traffic2; disable traffic3;
    rd=0; wr=0;
    repeat(64) @(negedge clk);
    if(refresh0-snap_r0 < 8192) fail($sformatf("chip 0 got %0d refreshes in 64 ms", refresh0-snap_r0));
    if(CHIPS==2) begin
        if(refresh1-snap_r1 < 8192) fail($sformatf("chip 1 got %0d refreshes in 64 ms", refresh1-snap_r1));
        if(refresh1!=refresh0) fail($sformatf("paired refresh: chip 0 %0d, chip 1 %0d", refresh0, refresh1));
    end else if(cmd1!=0) fail("64 MiB controller reached chip 1");
    $display("PASS sdram refresh: %0d/%0d refreshes per chip in a 64 ms window under traffic (%0d reads, %0d writes over 4 banks, %0d beats checked), no row older than 120 us, no timing rule violated",
             refresh0-snap_r0, CHIPS==2 ? refresh1-snap_r1 : 0, reads_done-snap_reads, writes_done-snap_writes, beats_checked);
    if(CHIPS==2) $display("PASS sdram: 128 MiB, two chips behind one inverted chip select, %0d beats verified in total", beats_checked);
    else $display("PASS sdram: 64 MiB, one chip, stock controller, %0d beats verified in total", beats_checked);
    $finish;
end
initial begin
    #(200_000_000); // 200 ms
    fail("timeout");
end
endmodule
