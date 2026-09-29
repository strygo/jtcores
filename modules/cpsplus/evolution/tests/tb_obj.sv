`timescale 1ns/1ps
// Object extension bit (patch 0003): the real download router, object RAM
// write path, frame copy, object RAM shadow, scanner, drawer and SDRAM slots.
// Only the external SDRAM is modeled: four banks with 24-bit word addresses,
// the 128 MiB module the slice needs. With REAL_SDRAM (patch 0004) the
// behavioural SDRAM is replaced by jtframe_sdram64 at AW=24 driving two chip
// models wired as the 128 MiB module (shared bus, nCS inverted into chip 1):
// the same scenes then run through the real controller, the slice fetches
// must reach chip 1 bank 2 and every read beat must carry the chip model's
// (chip, bank, row, column) pattern for the requested word.
// Object entries are written through the
// CPU port of jtcps1_sdram exactly as jtcps2_main presents them (A17..A1,
// byte lanes, obank) and every tile fetch is checked at the SDRAM against the
// set the written list must produce: low library {0, y[14:13], code} at bank
// 2/3 below 16 MiB, slice {1, 00, code} at bank 2 above 16 MiB, nothing at
// all for ext with bank bits != 00, never bank 1.
module tb_obj;
reg clk=0;
always #5 clk=~clk;          // 96 MHz: SDRAM and video clock (clk_gfx == clk in jtcps2_game)
reg rst=1;
// download
reg [25:0] ioctl_addr=0;
reg [7:0] ioctl_dout=0;
reg ioctl_wr=0, ioctl_rom=1;
wire ext, obj_cap, hold_rst, key_we, prog_we;
wire [23:0] prog_addr, ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [15:0] prog_data, ba0_din;
wire [1:0] prog_mask, prog_ba, ba0_dsn;
wire [3:0] ba_rd, ba_wr;
wire prog_rd;
`ifdef REAL_SDRAM
wire [3:0] ba_ack, ba_dst, ba_rdy, ba_dok;
wire [15:0] data_read;
wire prog_rdy_w, prog_ack_w, prog_dst_w, prog_dok_w, sdram_init;
`else
reg [3:0] ba_ack=0, ba_dst=0, ba_rdy=0;
reg [15:0] data_read=0;
wire [3:0] ba_dok = 4'd0;
wire prog_rdy_w = 1'b1;
`endif
// CPU object RAM port, as jtcps2_main drives it
reg oram_cs=0, rnw=1, obank=0;
reg [17:1] ram_addr=0;
reg [15:0] cpu_dout=0;
reg [1:0] dsn=2'b11;
wire ram_ok;
wire [15:0] ram_data;
// frame copy <-> SDRAM
wire [12:0] gfx_oram_addr;
wire [15:0] gfx_oram_data;
wire gfx_oram_ok, gfx_oram_clr, gfx_oram_cs, gfx_oram_ext;
// tile fetches
wire [19:0] rom0_addr;
wire [2:0] rom0_bank;
wire rom0_half, rom0_cs, rom0_ok;
wire [31:0] rom0_data;
wire [11:0] pxl;
// video timing as jtcps1_timing produces it: 512 pixels per line, 262 lines,
// vrender1 two lines ahead of vdump. The pixel enable is every 4 clocks so
// the frame copy (17 pixel clocks per word) and the line scans stay in ratio.
reg pxl_cen=0;
reg [1:0] cen_cnt=0;
reg [8:0] hdump=0, vdump=9'hf0, vrender=9'hf1, vrender1=9'hf2;
integer frame=0;
wire rst_obj = rst | hold_rst | ioctl_rom;

always @(posedge clk) begin
    cen_cnt <= cen_cnt+1'd1;
    pxl_cen <= cen_cnt==2'd3;
end
always @(posedge clk) if(pxl_cen) begin
    hdump <= hdump+1'd1;
    if(&hdump) begin
        vrender1 <= vrender1==9'd261 ? 9'd0 : vrender1+1'd1;
        vrender  <= vrender1;
        vdump    <= vrender;
        if(vrender==0) frame <= frame+1;
    end
end

jtcps1_sdram #(.CPS(2)) sdram(
    .rst(rst), .clk(clk), .clk_gfx(clk), .clk_cpu(clk), .LVBL(1'b1), .hold_rst(hold_rst),
    .ioctl_rom(ioctl_rom), .dwnld_busy(), .cfg_we(),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_din(), .ioctl_wr(ioctl_wr), .ioctl_ram(1'b0),
    .prog_addr(prog_addr), .prog_data(prog_data), .prog_mask(prog_mask), .prog_ba(prog_ba),
    .prog_we(prog_we), .prog_rd(prog_rd), .prog_rdy(prog_rdy_w), .prog_qsnd(),
    .sclk(1'b0), .sdi(1'b0), .sdo(), .scs(1'b0), .kabuki_we(),
    .cps2_key_we(key_we), .cps2_joymode(), .cps2_prog_ext(ext), .cps2_obj_ext(obj_cap), .gfx_oram_ext(gfx_oram_ext),
    .main_rom_cs(1'b0), .main_rom_ok(), .main_rom_addr(22'd0), .main_rom_data(),
    .vram_clr(1'b0), .vram_dma_cs(1'b0), .main_ram_cs(1'b0), .main_vram_cs(1'b0), .main_oram_cs(oram_cs),
    .obank(obank), .oram_base(16'd0),
    .gfx_oram_addr(gfx_oram_addr), .gfx_oram_data(gfx_oram_data), .gfx_oram_ok(gfx_oram_ok),
    .gfx_oram_clr(gfx_oram_clr), .gfx_oram_cs(gfx_oram_cs), .vram_rfsh_en(1'b0),
    .dsn(dsn), .main_dout(cpu_dout), .main_rnw(rnw), .main_ram_ok(ram_ok), .vram_dma_ok(),
    .main_ram_addr(ram_addr), .vram_dma_addr(17'd0), .main_ram_data(ram_data), .vram_dma_data(),
    .snd_cs(1'b0), .pcm_cs(1'b0), .snd_ok(), .pcm_ok(), .snd_addr(19'd0), .pcm_addr(23'd0), .snd_data(), .pcm_data(),
    .rom0_cs(rom0_cs), .rom1_cs(1'b0), .rom0_ok(rom0_ok), .rom1_ok(), .rom0_addr(rom0_addr), .rom0_bank(rom0_bank),
    .rom1_addr(20'd0), .rom0_half(rom0_half), .rom1_half(1'b0), .rom0_data(rom0_data), .rom1_data(),
    .star_bank(1'b0), .star0_addr(13'd0), .star0_data(), .star0_ok(), .star0_cs(1'b0),
    .star1_addr(13'd0), .star1_data(), .star1_ok(), .star1_cs(1'b0),
    .ba0_addr(ba0_addr), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(ba3_addr),
    .ba_rd(ba_rd), .ba_wr(ba_wr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
    .ba_ack(ba_ack), .ba_dst(ba_dst), .ba_dok(ba_dok), .ba_rdy(ba_rdy), .data_read(data_read), .dump_flag()
);

jtcps2_obj obj(
    .oram_ext(gfx_oram_ext),
    .rst(rst_obj), .clk(clk), .clk_cpu(clk), .pxl_cen(pxl_cen), .flip(1'b0), .LVBL(1'b1),
    .objcfg_cs(1'b0), .cpu_dout(16'd0), .dsn(2'b11), .addr(3'd0),
    .oram_addr(gfx_oram_addr), .oram_ok(gfx_oram_ok), .oram_clr(gfx_oram_clr), .oram_cs(gfx_oram_cs), .oram_data(gfx_oram_data),
    .obank(obank), .start(1'b0), .vrender1(vrender1), .vdump(vdump), .hdump(hdump),
    .rom_addr(rom0_addr), .rom_bank(rom0_bank), .rom_half(rom0_half), .rom_data(rom0_data), .rom_cs(rom0_cs), .rom_ok(rom0_ok),
    .pxl(pxl)
);

// ---------------------------------------------------------------- SDRAM model
// One transaction at a time, lowest bank first, four-word bursts wrapping in
// the 8-byte group, variable request latency. Bank 0 is real storage (the
// object table the CPU writes and the frame copy reads back); banks 2/3
// return any non-blank pattern; bank 1 must never be read (no samples here).
reg [15:0] mem0 [0:8388607];
integer tx=0, beat=0, latency=0, clocks=0, opaque=0, fetches=0, slice_fetches=0;
reg [1:0] tx_bank;
reg [23:0] tx_addr;
reg tx_write, checking=0;
reg [15:0] tx_data;
reg [1:0] tx_mask;
reg expect_key [0:524287]; // {ext, code17, code16, code[15:0]} = tile code bits 18..0
reg seen_key   [0:524287];

function [18:0] fetch_key(input [1:0] bank, input [23:0] w);
    fetch_key = {w[23], w[22], bank[0], w[21:6]};
endfunction

task note_fetch(input [1:0] bank, input [23:0] w);
reg [18:0] key;
begin
    if(bank==2'd1) $fatal(1,"frame %0d: bank 1 (samples) read at %h; the slice does not live there",frame,w);
    key=fetch_key(bank,w);
    if(checking) begin
        if(!expect_key[key])
            $fatal(1,"frame %0d: unexpected tile fetch bank=%0d word=%h -> ext=%b bank=%b code=%h",frame,bank,w,key[18],key[17:16],key[15:0]);
        seen_key[key]=1;
        fetches=fetches+1;
        if(w[23]) slice_fetches=slice_fetches+1;
    end
end
endtask

`ifdef REAL_SDRAM
// ------------------------------------------------ the real controller, two chips
import sdram_model_pkg::*;
reg sdram_rst=1, rfsh=0, ctrl_drive=0;
wire [15:0] sdram_din, sdram_dq, dq0, dq1;
wire [12:0] sdram_a;
wire [1:0] sdram_ba, en0, en1;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, idone0, idone1;
integer refresh0, refresh1, act0, act1, rd0, rd1, wr0, wr1, cmd0, cmd1, pall0, pall1;
integer beats_checked=0, slice_beats=0, bank3_beats=0, b;
reg [23:0] fetch_addr [0:3];
integer beats_left [0:3];
initial begin repeat(5) @(negedge clk); sdram_rst=0; end
always begin repeat(6400) @(posedge clk); rfsh<=1; @(posedge clk); rfsh<=0; end // one refresh trigger per 64 us line
// jtframe_board_sdram's CPS2 profile: 64-bit bursts on banks 0/2/3, 32 on bank 1, only bank 0 writable and auto-precharged
jtframe_sdram64 #(.AW(24), .HF(1), .SHIFTED(0), .BA0_LEN(64), .BA1_LEN(32), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(32),
    .BA0_WEN(1), .BA1_WEN(0), .BA2_WEN(0), .BA3_WEN(0), .BA0_AUTOPRECH(1), .MISTER(1), .RFSHCNT(9), .BAPRIO(1)) u_sdram(
    .rst(sdram_rst), .clk(clk), .init(sdram_init),
    .ba0_addr(ba0_addr), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(ba3_addr),
    .rd(ba_rd), .wr(ba_wr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn), .ba1_din(16'd0), .ba1_dsn(2'b11),
    .ba2_din(16'd0), .ba2_dsn(2'b11), .ba3_din(16'd0), .ba3_dsn(2'b11),
    .prog_en(ioctl_rom), .prog_addr(prog_addr), .prog_rd(prog_rd), .prog_wr(prog_we), .prog_din(prog_data), .prog_dsn(prog_mask),
    .prog_ba(prog_ba), .prog_dst(prog_dst_w), .prog_dok(prog_dok_w), .prog_rdy(prog_rdy_w), .prog_ack(prog_ack_w),
    .rfsh(rfsh), .ack(ba_ack), .dst(ba_dst), .dok(ba_dok), .rdy(ba_rdy), .dout(data_read),
    .sdram_dq(sdram_dq), .sdram_din(sdram_din), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh),
    .sdram_ba(sdram_ba), .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
);
sdram_chip_model #(.ID(0)) u_chip0(.clk(clk), .cs_n(sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas), .we_n(sdram_nwe),
    .ba(sdram_ba), .a(sdram_a), .dqm({sdram_dqmh, sdram_dqml}), .din(sdram_din), .dout(dq0), .dout_en(en0),
    .refreshes(refresh0), .activates(act0), .reads(rd0), .writes(wr0), .commands(cmd0), .pre_alls(pall0), .init_done(idone0));
sdram_chip_model #(.ID(1)) u_chip1(.clk(clk), .cs_n(~sdram_ncs), .ras_n(sdram_nras), .cas_n(sdram_ncas), .we_n(sdram_nwe), // the module's inverter
    .ba(sdram_ba), .a(sdram_a), .dqm({sdram_dqmh, sdram_dqml}), .din(sdram_din), .dout(dq1), .dout_en(en1),
    .refreshes(refresh1), .activates(act1), .reads(rd1), .writes(wr1), .commands(cmd1), .pre_alls(pall1), .init_done(idone1));
assign sdram_dq[15:8] = en0[1] ? dq0[15:8] : dq1[15:8];
assign sdram_dq[7:0]  = en0[0] ? dq0[7:0]  : dq1[7:0];
always @(posedge clk) ctrl_drive <= u_sdram.wr_cycle;
function automatic [15:0] pattern_of(input [1:0] bank, input [23:0] a);
    pattern_of = sdram_pattern(32'(a[23]), bank, a[21:9], {a[22], a[8:0]}); // the address contract of patch 0004
endfunction
task automatic check_beat(input [1:0] bank);
    reg [23:0] a;
    reg [15:0] exp;
begin
    a = fetch_addr[bank]; a[1:0] = fetch_addr[bank][1:0] + 2'(4-beats_left[bank]);
    exp = pattern_of(bank, a);
    if(data_read!==exp) $fatal(1,"frame %0d: bank %0d word %h read %h through the controller, expected pattern %h",frame,bank,a,data_read,exp);
    beats_checked = beats_checked+1;
    if(a[23]) slice_beats = slice_beats+1;
    if(bank==3) bank3_beats = bank3_beats+1;
    beats_left[bank] = beats_left[bank]-1;
end
endtask
always @(negedge clk) begin
    clocks=clocks+1;
    if(clocks>300000000) $fatal(1,"timeout at frame %0d (rom0_cs=%b rom0_ok=%b)",frame,rom0_cs,rom0_ok);
    if(!sdram_rst) begin
        if((en0 & en1)!=0) $fatal(1,"both chips drive DQ");
        if(ctrl_drive && (en0|en1)!=0) $fatal(1,"a chip drives DQ during the controller's write cycle");
    end
    if(!rst) begin
        // the address each bank command was issued for, as the controller latched it
        if(ba_ack[0] && u_sdram.ba0_addr_l[23]) $fatal(1,"bank 0 access above 16 MiB: %h",u_sdram.ba0_addr_l);
        if(ba_ack[1]) note_fetch(2'd1, u_sdram.ba1_addr_l);
        if(ba_ack[2]) begin note_fetch(2'd2, u_sdram.ba2_addr_l); fetch_addr[2]=u_sdram.ba2_addr_l; end
        if(ba_ack[3]) begin note_fetch(2'd3, u_sdram.ba3_addr_l); fetch_addr[3]=u_sdram.ba3_addr_l; end
        for(b=2;b<4;b=b+1) begin
            if(ba_dst[b]) begin beats_left[b]=4; check_beat(b[1:0]); end
            else if(beats_left[b]>0) check_beat(b[1:0]);
        end
    end
end
initial begin beats_left[0]=0; beats_left[1]=0; beats_left[2]=0; beats_left[3]=0; end
`else
always @(negedge clk) begin
    ba_ack=0; ba_dst=0; ba_rdy=0;
    clocks=clocks+1;
    if(clocks>150000000) $fatal(1,"timeout at frame %0d (tx=%0d rom0_cs=%b rom0_ok=%b)",frame,tx,rom0_cs,rom0_ok);
    if(rst) tx=0;
    else case(tx)
        0: if(ba_wr[0] || |ba_rd) begin
            if(ba_wr[0])      begin tx_bank=0; tx_write=1; tx_addr=ba0_addr; tx_data=ba0_din; tx_mask=ba0_dsn; end
            else if(ba_rd[0]) begin tx_bank=0; tx_write=0; tx_addr=ba0_addr; end
            else if(ba_rd[1]) begin tx_bank=1; tx_write=0; tx_addr=ba1_addr; end
            else if(ba_rd[2]) begin tx_bank=2; tx_write=0; tx_addr=ba2_addr; end
            else              begin tx_bank=3; tx_write=0; tx_addr=ba3_addr; end
            if(tx_bank==0 && tx_addr[23]) $fatal(1,"bank 0 access above 16 MiB: %h",tx_addr);
            if(!tx_write && tx_bank!=0) note_fetch(tx_bank,tx_addr);
            latency=2+(clocks%4); tx=1;
        end
        1: if(latency!=0) latency=latency-1;
           else begin ba_ack[tx_bank]=1; beat=0; tx=2; end
        2: if(tx_write) begin
                if(!tx_mask[1]) mem0[tx_addr[22:0]][15:8]=tx_data[15:8];
                if(!tx_mask[0]) mem0[tx_addr[22:0]][7:0]=tx_data[7:0];
                ba_dst[tx_bank]=1; ba_rdy[tx_bank]=1; tx=3;
           end else begin
                if(tx_bank==0) data_read=mem0[(tx_addr[22:0] & 23'h7ffffc)+((tx_addr[22:0]+beat)&3)];
                else data_read={1'b0, tx_bank[0], tx_addr[13:0]}; // never all ones: the drawer must draw, not skip
                ba_dst[tx_bank]=(beat==0);
                ba_rdy[tx_bank]=(beat==3);
                if(beat==3) tx=3; else beat=beat+1;
           end
        3: tx=0;
    endcase
end
`endif

always @(posedge clk) if(pxl_cen && checking && pxl[3:0]!=4'hf) opaque=opaque+1;

// ---------------------------------------------------------------- stimulus
task put(input [25:0] a, input [7:0] b);
begin
    @(negedge clk); ioctl_addr=a; ioctl_dout=b; ioctl_wr=1;
    @(negedge clk); ioctl_wr=0;
    repeat(3) @(negedge clk);
end
endtask

// Prototype header: 8 MiB CPU region, Z80 at 8 MiB, samples at 8.125 MiB,
// graphics at 12.125 MiB, DSP firmware after a 40 MiB graphics region.
task download(input [7:0] capability);
integer i;
reg [63:0] starts;
begin
    starts={16'hd080,16'h3080,16'h2080,16'h2000};
    ioctl_rom=1; rst=1;
    repeat(20) @(negedge clk);
    for(i=0;i<8;i=i+1) put(i,starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(i,8'hff);
    put(12,8'h43); put(13,8'h32); put(14,8'h01); put(15,capability);
    for(i=16;i<64;i=i+1) put(i,8'hff);
    repeat(6000) @(negedge clk); // reset long enough to clear both 2048-entry extension tables
`ifdef REAL_SDRAM
    wait(sdram_init===0); // jtframe holds the game in reset until the SDRAM is initialized
    repeat(20) @(negedge clk);
`endif
    ioctl_rom=0; rst=0;
    wait(hold_rst===0);
    repeat(100) @(negedge clk);
end
endtask

// One CPU write to the object page: A17..A1 as jtcps2_main presents them,
// held until the SDRAM slot reports completion (DTACK equivalent).
task cpu_write(input a15, input a14, input a13, input [9:0] slot, input [1:0] word, input [15:0] data, input [1:0] mask);
begin
    @(negedge clk);
    ram_addr={2'b00,a15,a14,a13,slot,word}; cpu_dout=data; dsn=mask; rnw=0; oram_cs=1;
    @(posedge clk); while(!ram_ok) @(posedge clk);
    @(negedge clk); oram_cs=0; rnw=1; dsn=2'b11;
    @(negedge clk);
end
endtask

task write_entry(input a15, input a14, input [9:0] slot, input [15:0] x, input [15:0] y, input [15:0] code, input [15:0] attr);
begin
    cpu_write(a15,a14,1'b0,slot,2'd0,x,2'b00);
    cpu_write(a15,a14,1'b0,slot,2'd1,y,2'b00);
    cpu_write(a15,a14,1'b0,slot,2'd2,code,2'b00);
    cpu_write(a15,a14,1'b0,slot,2'd3,attr,2'b00);
end
endtask

task expect_obj(input e, input [1:0] bank, input [15:0] code, input [3:0] tile_n, input [3:0] tile_m);
integer n,m;
begin
    for(m=0;m<=tile_m;m=m+1) for(n=0;n<=tile_n;n=n+1)
        expect_key[{e,bank,16'(code+n+(m<<4))}]=1;
end
endtask

task clear_sets;
integer k;
begin
    for(k=0;k<524288;k=k+1) begin expect_key[k]=0; seen_key[k]=0; end
    fetches=0; slice_fetches=0; opaque=0;
end
endtask

// Entries written early in frame F are copied into the shadow during F and
// scanned throughout F+1: observe exactly that frame.
task run_scene(input string label, input integer min_slice, input integer max_slice);
integer target, k, missing;
begin
    target=frame+1;
    while(frame<target) @(posedge clk);
    checking=1;
    while(frame<target+1) @(posedge clk);
    checking=0;
    missing=0;
    for(k=0;k<524288;k=k+1) if(expect_key[k] && !seen_key[k]) begin
        missing=missing+1;
        $display("  missing tile: ext=%b bank=%b code=%h",k[18],k[17:16],k[15:0]);
    end
    if(missing) $fatal(1,"%s: %0d expected tiles never fetched",label,missing);
    if(slice_fetches<min_slice || slice_fetches>max_slice)
        $fatal(1,"%s: %0d slice fetches outside [%0d,%0d]",label,slice_fetches,min_slice,max_slice);
    if(opaque==0) $fatal(1,"%s: no opaque object pixel reached the line buffer",label);
    $display("PASS obj %s: %0d tile fetches (%0d from the slice) matched the expected set, %0d opaque pixels",label,fetches,slice_fetches,opaque);
end
endtask

// The bank-0 list used by scenes 1, 4 and 5. Slot: window, y bank bits, code, size.
//  0 normal            1234  1x1     4 alias, then x rewritten through the normal window 5678
//  1 alias             2345  1x1     5 normal, then one byte of attr through the alias      6789
//  2 alias, bank 01    3456  1x1     6 alias, 2x2 with both flips                           0700
//  3 normal, bank 10   4567  1x1     7 normal, bank 11, 1x3                                 0800
//  8 end marker written through A13 = 1 (the mirror)
task write_list;
begin
    write_entry(0,0,0, 16'h0040,16'h0010,16'h1234,16'h0000);
    write_entry(0,1,1, 16'h0040,16'h0028,16'h2345,16'h0000);
    write_entry(0,1,2, 16'h0040,16'h2040,16'h3456,16'h0000);
    write_entry(0,0,3, 16'h0040,16'h4058,16'h4567,16'h0000);
    write_entry(0,1,4, 16'h0040,16'h0070,16'h5678,16'h0000);
    cpu_write(0,0,0,10'd4,2'd0,16'h0040,2'b00);
    write_entry(0,0,5, 16'h0040,16'h0088,16'h6789,16'h0000);
    cpu_write(0,1,0,10'd5,2'd3,16'h0000,2'b10);
    write_entry(0,1,6, 16'h0040,16'h00a0,16'h0700,16'h1160);
    write_entry(0,0,7, 16'h0040,16'h60d0,16'h0800,16'h0200);
    cpu_write(0,0,1,10'd8,2'd1,16'h8000,2'b00);
end
endtask

task expect_list(input enhanced);
begin
    expect_obj(0,2'b00,16'h1234,0,0);
    expect_obj(enhanced,2'b00,16'h2345,0,0);
    if(!enhanced) expect_obj(0,2'b01,16'h3456,0,0); // enhanced: ext with bank 01 fetches nothing
    expect_obj(0,2'b10,16'h4567,0,0);
    expect_obj(0,2'b00,16'h5678,0,0);
    expect_obj(enhanced,2'b00,16'h6789,0,0);
    expect_obj(enhanced,2'b00,16'h0700,1,1);
    expect_obj(0,2'b11,16'h0800,2,0);
end
endtask

initial if($test$plusargs("MUTATE")) begin
    $display("MUTATION: extension lane write enable forced off");
    force obj.u_objram.we_ext=1'b0;
end

integer settle;
initial begin
    download(8'h03);
    if(ext!==1 || obj_cap!==1) $fatal(1,"capability 03 not enabled: ext=%b obj=%b",ext,obj_cap);
    settle=frame+2;
    while(frame<settle) @(posedge clk);
    // Scene 1: both windows, rewrite clears, byte write sets, blocks, flips,
    // bank bits, ext with bank != 0, A13 mirror, one frame mixing both halves.
    clear_sets; write_list; expect_list(1);
    run_scene("scene 1: alias/normal windows, rewrite-clears, byte-sets, 2x2 flips, 1x3 bank 3, ext+bank!=0 blank, A13 mirror",8,1000000);
    // Scene 2: the other physical bank, written through A15=1 while obank=0,
    // then shown through the swap.
    clear_sets;
    write_entry(1,0,0, 16'h0040,16'h0010,16'h1111,16'h0000); expect_obj(0,2'b00,16'h1111,0,0);
    write_entry(1,1,1, 16'h0040,16'h0028,16'h2222,16'h0000); expect_obj(1,2'b00,16'h2222,0,0);
    cpu_write(1,0,0,10'd2,2'd1,16'h8000,2'b00);
    obank=1;
    run_scene("scene 2: second object bank through the swap",1,1000000);
    // Scene 3: recycled slots follow the last writer. With obank=1 the CPU
    // reaches physical bank 1 through A15=0.
    clear_sets;
    write_entry(0,0,1, 16'h0040,16'h0028,16'h3333,16'h0000); expect_obj(0,2'b00,16'h3333,0,0);
    write_entry(0,1,0, 16'h0040,16'h0010,16'h1111,16'h0000); expect_obj(1,2'b00,16'h1111,0,0);
    run_scene("scene 3: recycled slots take the last writer's window",1,1000000);
    // Scene 4: swap back; bank 0's list and its bits were retained.
    clear_sets; expect_list(1);
    obank=0;
    run_scene("scene 4: swap back, bank 0 list and extension bits retained",8,1000000);
    // Scene 5: legacy profile. A new download with capability 01 clears the
    // tables; the same writes now behave as plain mirrors: never the slice.
    download(8'h01);
    if(ext!==1 || obj_cap!==0) $fatal(1,"capability 01 must leave the slice off: ext=%b obj=%b",ext,obj_cap);
    settle=frame+2;
    while(frame<settle) @(posedge clk);
    clear_sets; write_list; expect_list(0);
    run_scene("scene 5: capability off, alias writes are plain mirrors, never the slice",0,0);
`ifdef REAL_SDRAM
    if(!idone0 || !idone1) $fatal(1,"chip initialization incomplete: %b %b",idone0,idone1);
    if(slice_beats==0 || rd1==0) $fatal(1,"the slice was never read from chip 1");
    if(wr1!=0) $fatal(1,"chip 1 was written (%0d): the object table belongs in chip 0 bank 0",wr1);
    if(wr0==0 || bank3_beats==0) $fatal(1,"chip 0 saw no object table writes or no bank 3 fetches");
    if(refresh0!=refresh1 || refresh0==0) $fatal(1,"refresh counts %0d/%0d",refresh0,refresh1);
    $display("PASS objxl: the five scenes through jtframe_sdram64 (AW=24) and two chips: %0d read beats checked against the (chip,bank,row,column) pattern, %0d from the slice in chip 1 bank 2, %0d from bank 3; chip 1 read %0d bursts and was never written; object table writes in chip 0 (%0d); %0d refreshes per chip",
             beats_checked, slice_beats, bank3_beats, rd1, wr0, refresh0);
`endif
    $display("PASS obj: extension bit through the real object RAM, frame copy, scan, draw and SDRAM slot paths");
    $finish;
end
endmodule
