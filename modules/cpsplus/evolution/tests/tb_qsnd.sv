`timescale 1ns/1ps
// Flat 24-bit QSound sample addressing (patch 0006, CPS2_QSND24): the real
// download router (jtcps1_prom_we inside jtcps1_sdram) loads a sparse 16 MiB
// sample library through jtframe_sdram64 (AW=24) into the two chip models of
// the 128 MiB module, and the real DSP address latch of jtcps15_sound drives
// the PCM slot of jtcps1_sdram exactly as jtcps2_game wires it:
// qsnd_addr -> pcm_addr -> capability mask -> jtframe_rom_1slot -> bank 1 ->
// controller -> chips -> qsnd_data. The DSP16 stays in reset (the Z80 never
// releases it: its ROM reads as NOPs) and its external bus is forced to the
// cycles the dl-1425 program produces for a sample read: the offset on the
// parallel output bus with a pods_n strobe, then the bank word 0x8000|bank on
// the address bus with cen_cko (dsp_io_map in MAME: the DSP's data address
// bits 14:0 are the bank, the 24-bit ROM space keeps bits 7:0 of it).
//
// Every bank byte 0x00..0xff is fetched at several offsets, including both
// ends of each 64 KiB bank and the signed-16-bit boundary the DSP compares
// against. Library byte L holds f(L) = a function that differs between bank b
// and bank b^0x80, so a dropped or masked bit 23 shows up as wrong data;
// offsets that were never downloaded must return the chip model's (chip 0,
// bank 1, row, column) pattern of the requested word, so the exact SDRAM
// placement is checked as well. Phase 1: marker 07 (flat order: samples,
// firmware, graphics) -> banks 0x80..0xff read the upper 8 MiB. Phase 2: a new
// download with marker 01 and the stock order (the same 16 MiB region, which
// the stock loader also writes to bank 1) -> the capability is off and banks
// 0x80..0xff must mirror banks 0x00..0x7f, byte for byte. Phase 3: marker 05
// (flat QSound without the slice) behaves as phase 1.
//
// Mutations, each of which must turn the test red:
//   +MUTATE=latch   bit 23 of the latched address is held at 0 before the PCM
//                   slot (the stock 7-bit bank latch): phase 1 reads the low
//                   library for bank 0x80.
//   +MUTATE=mirror  the capability is forced on during phase 2: bank 0x80
//                   reads the upper library instead of mirroring bank 0x00.
//
// +FIRMWARE=<hex> (the first 8 KiB of dl-1425.bin, one byte per line) runs
// the real DSP program instead of forcing the bus: the firmware is downloaded
// through the loader's firmware region (flat order: before the graphics), the
// Z80 runs a 44-byte program from the testbench that releases the DSP, waits
// for its ready flag and writes the voice registers the stock driver writes at
// key-on (bank 0x80 for voice 1 at offset 0x1234, bank 0xff for voice 2 at
// offset 0xff00, end 0xffff, loop 0, rate 0: the DSP then reads those samples
// every period), and the SDRAM must see the fetches at bank 1 words 0x40091a
// and 0x7fff80 with marker 07 and, after a marker 01 header alone (the DSP
// keeps its registers), at 0x00091a and 0x3fff80: the mirror.
module tb_qsnd;
import sdram_model_pkg::*;
reg clk=0;
always #5 clk=~clk;          // SDRAM / 96 MHz domain (100 MHz here, the faster jtframe test period)
reg clk48=0;
always @(posedge clk) clk48<=~clk48;
reg rst=1;
wire cen8;
// download
reg [26:0] ioctl_addr=0;
reg [7:0] ioctl_dout=0;
reg ioctl_wr=0, ioctl_rom=1;
wire ext, obj_cap, hold_rst, key_we, prog_we, prog_rd, prog_qsnd;
wire [23:0] prog_addr, ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [15:0] prog_data, ba0_din;
wire [1:0] prog_mask, prog_ba, ba0_dsn;
wire [3:0] ba_rd, ba_wr, ba_ack, ba_dst, ba_rdy, ba_dok;
wire [15:0] data_read;
wire prog_rdy_w, prog_ack_w, prog_dst_w, prog_dok_w, sdram_init;
// sound
wire [23:0] qsnd_addr;
wire [23:0] pcm_addr;
wire qsnd_cs, pcm_ok;
wire [7:0] pcm_data;
wire [18:0] z80_addr;
wire z80_cs;
reg mut_latch=0, mut_mirror=0, firmware_mode=0;
string mutation, firmware_file;
// Z80 program (firmware mode): release the DSP, then per register wait for
// D007 bit 7 (ready) and write hi -> D000, lo -> D001, index -> D002.
//   00: F3          di
//   01: 31 00 F1    ld sp,F100
//   04: 3E 80       ld a,80
//   06: 32 03 D0    ld (D003),a      DSP out of reset, ROM bank 0
//   09: 21 28 00    ld hl,0028       register table
//   0C: 3A 07 D0    ld a,(D007)
//   0F: 07          rlca
//   10: 30 FA       jr nc,0C         wait for ready
//   12: 7E          ld a,(hl)
//   13: 32 00 D0    ld (D000),a      data high
//   16: 23          inc hl
//   17: 7E          ld a,(hl)
//   18: 32 01 D0    ld (D001),a      data low
//   1B: 23          inc hl
//   1C: 7E          ld a,(hl)
//   1D: 32 02 D0    ld (D002),a      register index (raises the DSP interrupt)
//   20: 23          inc hl
//   21: 7D          ld a,l
//   22: FE 40       cp 40            eight registers (table 0x28..0x3f)
//   24: 20 E6       jr nz,0C
//   26: 18 FE       jr 26
reg [7:0] z80rom [0:255];
reg [7:0] fw [0:8191];
initial begin : z80_program
    integer k;
    reg [7:0] code [0:39];
    reg [7:0] regs [0:23];
    for(k=0;k<256;k=k+1) z80rom[k]=8'h00;
    code = '{8'hF3,8'h31,8'h00,8'hF1,8'h3E,8'h80,8'h32,8'h03,8'hD0,8'h21,8'h28,8'h00,
             8'h3A,8'h07,8'hD0,8'h07,8'h30,8'hFA,
             8'h7E,8'h32,8'h00,8'hD0,8'h23,8'h7E,8'h32,8'h01,8'hD0,8'h23,8'h7E,8'h32,8'h02,8'hD0,8'h23,
             8'h7D,8'hFE,8'h40,8'h20,8'hE6,8'h18,8'hFE};
    // bank of voice n is register (n-1)*8: voice 1 bank 0x8080, address 0x1234, end 0xffff, loop 0;
    // voice 2 bank 0x80ff, address 0xff00, end 0xffff, loop 0
    regs = '{8'h80,8'h80,8'h00, 8'h12,8'h34,8'h09, 8'hFF,8'hFF,8'h0D, 8'h00,8'h00,8'h0C,
             8'h80,8'hFF,8'h08, 8'hFF,8'h00,8'h11, 8'hFF,8'hFF,8'h15, 8'h00,8'h00,8'h14};
    for(k=0;k<40;k=k+1) z80rom[k]=code[k];
    for(k=0;k<24;k=k+1) z80rom[8'h28+k]=regs[k];
end
wire [7:0] z80_data = firmware_mode && z80_addr<19'h100 ? z80rom[z80_addr[7:0]] : 8'h00;

// The mutation "latch" is the stock 7-bit bank latch: bit 23 never reaches
// the PCM slot. It is applied in the wiring, not in the RTL.
assign pcm_addr = { qsnd_addr[23] & ~mut_latch, qsnd_addr[22:0] };

jtframe_cen48 u_cen48(.clk(clk48), .cen16(), .cen16b(), .cen12(), .cen8(cen8), .cen6(), .cen4(), .cen4_12(),
    .cen3(), .cen3q(), .cen1p5(), .cen12b(), .cen6b(), .cen3b(), .cen3qb(), .cen1p5b());

jtcps1_sdram #(.CPS(2)) sdram(
    .rst(rst), .clk(clk), .clk_gfx(clk), .clk_cpu(clk48), .LVBL(1'b1), .hold_rst(hold_rst),
    .ioctl_rom(ioctl_rom), .dwnld_busy(), .cfg_we(),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_din(), .ioctl_wr(ioctl_wr), .ioctl_ram(1'b0),
    .prog_addr(prog_addr), .prog_data(prog_data), .prog_mask(prog_mask), .prog_ba(prog_ba),
    .prog_we(prog_we), .prog_rd(prog_rd), .prog_rdy(prog_rdy_w), .prog_qsnd(prog_qsnd),
    .sclk(1'b0), .sdi(1'b0), .sdo(), .scs(1'b0), .kabuki_we(),
    .cps2_key_we(key_we), .cps2_joymode(), .cps2_prog_ext(ext), .cps2_obj_ext(obj_cap), .gfx_oram_ext(),
    .main_rom_cs(1'b0), .main_rom_ok(), .main_rom_addr(22'd0), .main_rom_data(),
    .vram_clr(1'b0), .vram_dma_cs(1'b0), .main_ram_cs(1'b0), .main_vram_cs(1'b0), .main_oram_cs(1'b0),
    .obank(1'b0), .oram_base(16'd0),
    .gfx_oram_addr(13'd0), .gfx_oram_data(), .gfx_oram_ok(), .gfx_oram_clr(1'b0), .gfx_oram_cs(1'b0), .vram_rfsh_en(1'b0),
    .dsn(2'b11), .main_dout(16'd0), .main_rnw(1'b1), .main_ram_ok(), .vram_dma_ok(),
    .main_ram_addr(17'd0), .vram_dma_addr(17'd0), .main_ram_data(), .vram_dma_data(),
    .snd_cs(1'b0), .pcm_cs(qsnd_cs), .snd_ok(), .pcm_ok(pcm_ok), .snd_addr(19'd0), .pcm_addr(pcm_addr), .snd_data(), .pcm_data(pcm_data),
    .rom0_cs(1'b0), .rom1_cs(1'b0), .rom0_ok(), .rom1_ok(), .rom0_addr(20'd0), .rom0_bank(3'd0),
    .rom1_addr(20'd0), .rom0_half(1'b0), .rom1_half(1'b0), .rom0_data(), .rom1_data(),
    .star_bank(1'b0), .star0_addr(13'd0), .star0_data(), .star0_ok(), .star0_cs(1'b0),
    .star1_addr(13'd0), .star1_data(), .star1_ok(), .star1_cs(1'b0),
    .ba0_addr(ba0_addr), .ba1_addr(ba1_addr), .ba2_addr(ba2_addr), .ba3_addr(ba3_addr),
    .ba_rd(ba_rd), .ba_wr(ba_wr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
    .ba_ack(ba_ack), .ba_dst(ba_dst), .ba_dok(ba_dok), .ba_rdy(ba_rdy), .data_read(data_read), .dump_flag()
);

// The Z80 reads NOPs: it never writes the bank register, so the DSP16 stays
// in reset and only the forced bus cycles reach the address latch.
jtcps15_sound snd(
    .rst(rst|hold_rst), .clk96(clk), .clk48(clk48), .cen8(cen8), .vol_up(1'b0), .vol_down(1'b0), .volume(),
    .kabuki_we(1'b0), .kabuki_en(1'b0),
    .main_addr(23'd0), .main_dout(8'd0), .main_din(), .main_ldswn(1'b1), .main_buse_n(1'b1), .main_busakn(), .main_waitn(),
    .rom_addr(z80_addr), .rom_cs(z80_cs), .rom_data(z80_data), .rom_ok(1'b1),
    .qsnd_addr(qsnd_addr), .qsnd_cs(qsnd_cs), .qsnd_data(pcm_data), .qsnd_ok(pcm_ok),
    .prog_addr(prog_addr[12:0]), .prog_data(prog_data[7:0]), .prog_we(prog_qsnd),
    .left(), .right(), .sample()
);

// ------------------------------------------------ the real controller, two chips
reg sdram_rst=1, rfsh=0, ctrl_drive=0;
wire [15:0] sdram_din, sdram_dq, dq0, dq1;
wire [12:0] sdram_a;
wire [1:0] sdram_ba, en0, en1;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke, idone0, idone1;
integer refresh0, refresh1, act0, act1, rd0, rd1, wr0, wr1, cmd0, cmd1, pall0, pall1;
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

// ---------------------------------------------------------------- bookkeeping
integer clocks=0, bank1_reads=0, upper_reads=0, prog_words=0, firmware_bytes=0;
reg [23:0] last_ba1=0;
integer seen_word [longint];   // bank 1 words fetched since the last clear (firmware mode) -> count
integer high_fetches=0;        // bank 1 fetches at or above word 0x400000 since the last clear
integer erase_tail_cnt=0; // the last erase write of the bank 0 slot is issued as hold_rst falls and completes later
wire erase_tail = erase_tail_cnt!=0;
always @(posedge clk) erase_tail_cnt <= hold_rst ? 256 : (erase_tail_cnt!=0 ? erase_tail_cnt-1 : 0);
always @(negedge clk) begin
    clocks=clocks+1;
    if(clocks>400000000) $fatal(1,"timeout");
    if(!sdram_rst) begin
        if((en0 & en1)!=0) $fatal(1,"both chips drive DQ");
        if(ctrl_drive && (en0|en1)!=0) $fatal(1,"a chip drives DQ during the controller's write cycle");
    end
    if(!rst && !hold_rst && !erase_tail) begin
        if(ba_ack[0] || ba_ack[2] || ba_ack[3]) $fatal(1,"a bank other than 1 was accessed: ack=%b rd=%b wr=%b ba0=%h ioctl_rom=%b",ba_ack,ba_rd,ba_wr,ba0_addr,ioctl_rom);
        if(ba_ack[1]) begin
            last_ba1=u_sdram.ba1_addr_l;
            if(last_ba1[23]) $fatal(1,"sample fetch in chip 1: word %h (the 16 MiB library lives in chip 0)",last_ba1);
            bank1_reads=bank1_reads+1;
            if(last_ba1[22]) begin upper_reads=upper_reads+1; high_fetches=high_fetches+1; end
            if(seen_word.exists(longint'(last_ba1))) seen_word[longint'(last_ba1)]=seen_word[longint'(last_ba1)]+1; else seen_word[longint'(last_ba1)]=1;
        end
    end
    if(prog_ack_w) begin
        prog_words=prog_words+1;
        if(u_sdram.prog_ba!=2'd1) $fatal(1,"download wrote bank %0d (only samples are downloaded here)",u_sdram.prog_ba);
    end
    if(prog_qsnd) firmware_bytes=firmware_bytes+1;
end

// the library byte at offset L (both halves), never equal for L and L^0x800000
function automatic [7:0] f(input [23:0] L);
    f = 8'(L[23:16]*8'd7 + L[15:8]*8'd13 + L[7:0]*8'd3 + (L[23] ? 8'h55 : 8'h00)) ^ 8'ha5;
endfunction
// unwritten library bytes: the chip pattern of the word (chip 0, bank 1) by the 0004 address contract
function automatic [7:0] pattern_byte(input [23:0] L);
    reg [23:0] w;
    reg [15:0] p;
begin
    w = {1'b0, L[23:1]};
    p = sdram_pattern(0, 2'd1, w[21:9], {w[22], w[8:0]});
    pattern_byte = L[0] ? p[15:8] : p[7:0];
end
endfunction

// ---------------------------------------------------------------- download
task put(input [26:0] a, input [7:0] b);
integer n;
begin
    @(negedge clk); ioctl_addr=a; ioctl_dout=b; ioctl_wr=1;
    @(negedge clk); ioctl_wr=0;
    n=0;
    @(negedge clk);
    while(prog_we) begin @(negedge clk); n=n+1; if(n>2000) $fatal(1,"download stalled at %h",a); end
    @(negedge clk);
end
endtask

localparam [15:0] CPU_KIB=16'h2000, Z80_KIB=16'h100, PCM_KIB=16'h4000, FW_KIB=16'd8, GFX32_KIB=16'h8000;
localparam [15:0] PCM_START=CPU_KIB+Z80_KIB;                 // 0x2100 in both orders
localparam [26:0] PCM_BASE=27'd64+{PCM_START,10'd0};
localparam [26:0] FW_FLAT_BASE=27'd64+{PCM_START+PCM_KIB,10'd0};

// header: fields {qsnd_start, gfx_start, pcm_start, snd_start} in KiB
// reset=1 also resets the game side (bank 0 erase, about 150 ms of simulated
// time through the controller); the later downloads only need the loader.
task header(input [15:0] snd_start, input [15:0] pcm_start, input [15:0] gfx_start, input [15:0] qsnd_start, input [7:0] capability, input reset);
integer i;
reg [63:0] starts;
begin
    starts={qsnd_start, gfx_start, pcm_start, snd_start};
    ioctl_rom=1; if(reset) rst=1;
    repeat(20) @(negedge clk);
    for(i=0;i<8;i=i+1) put(27'(i),starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(27'(i),8'hff);
    put(12,8'h43); put(13,8'h32); put(14,8'h01); put(15,capability);
    for(i=16;i<64;i=i+1) put(27'(i),8'hff);
    wait(sdram_init===0); // the programmer answers only once both chips are initialized
    repeat(100) @(negedge clk);
end
endtask

integer sweep_offsets [0:5];
integer blank_offsets [0:1];
initial begin
    sweep_offsets[0]=0; sweep_offsets[1]=1; sweep_offsets[2]='h7ffe; sweep_offsets[3]='h8001; sweep_offsets[4]='hfffe; sweep_offsets[5]='hffff;
    blank_offsets[0]='h1234; blank_offsets[1]='h9abd;
end

// the sparse library: f(L) at the sweep offsets of every bank
task download_library;
integer b, k;
reg [23:0] L;
begin
    for(b=0;b<256;b=b+1) for(k=0;k<6;k=k+1) begin
        L = {b[7:0], sweep_offsets[k][15:0]};
        put(PCM_BASE+27'(L), f(L));
    end
end
endtask

task finish_download;
begin
    repeat(20) @(negedge clk);
    ioctl_rom=0; rst=0;
    wait(hold_rst===0);
    repeat(200) @(negedge clk);
end
endtask

// ---------------------------------------------------------------- the DSP side
// One sample read as the dl-1425 program performs it: the 16-bit offset on the
// parallel output bus (pods_n strobe), then the bank word 0x8000|bank on the
// address bus during a cen_cko cycle. Both are forced on the DSP16's outputs.
integer fetches=0, pattern_fetches=0;
task dsp_fetch(input [7:0] bank, input [15:0] offset, output [7:0] data);
integer n;
begin
    force snd.dsp_pbus_out = offset;
    force snd.dsp_pods_n = 1'b0;
    repeat(2) @(negedge clk);
    force snd.dsp_pods_n = 1'b1;
    repeat(2) @(negedge clk);
    force snd.dsp_ab = {1'b1, 7'd0, bank};
    force snd.dsp_cen_cko = 1'b1;
    @(negedge clk);
    force snd.dsp_cen_cko = 1'b0;
    force snd.dsp_ab = 16'h0000;   // the bus moves on; the latch must hold the bank
    repeat(2) @(negedge clk);
    if(qsnd_addr!=={bank,offset}) $fatal(1,"latch: bank %h offset %h latched as %h",bank,offset,qsnd_addr);
    n=0;
    while(!pcm_ok) begin @(negedge clk); n=n+1; if(n>5000) $fatal(1,"no data for bank %h offset %h",bank,offset); end
    data=pcm_data;
end
endtask

task sweep(input flat, input string label);
integer b, k;
reg [23:0] L, phys;
reg [7:0] got, exp;
begin
    for(b=0;b<256;b=b+1) begin
        for(k=0;k<6;k=k+1) begin
            L = {b[7:0], sweep_offsets[k][15:0]};
            phys = flat ? L : {1'b0, L[22:0]};
            exp = f(phys);
            dsp_fetch(b[7:0], sweep_offsets[k][15:0], got);
            if(got!==exp) $fatal(1,"%s: bank %02h offset %04h read %02h, expected %02h (library byte %06h)",label,b,sweep_offsets[k],got,exp,phys);
            fetches=fetches+1;
        end
        for(k=0;k<2;k=k+1) begin
            L = {b[7:0], blank_offsets[k][15:0]};
            phys = flat ? L : {1'b0, L[22:0]};
            exp = pattern_byte(phys);
            dsp_fetch(b[7:0], blank_offsets[k][15:0], got);
            if(got!==exp) $fatal(1,"%s: bank %02h offset %04h (never downloaded) read %02h, expected the chip pattern %02h of library byte %06h",label,b,blank_offsets[k],got,exp,phys);
            if(last_ba1[22:0]!==phys[23:1]) $fatal(1,"%s: bank %02h offset %04h fetched SDRAM word %h, expected %h",label,b,blank_offsets[k],last_ba1,phys[23:1]);
            pattern_fetches=pattern_fetches+1;
        end
    end
end
endtask

// firmware mode: the 8 KiB DSP program through the loader's firmware region
task download_firmware(input [26:0] base);
integer k;
begin
    for(k=0;k<8192;k=k+1) begin
        put(base+27'(k), fw[k]);
        // prom_we is a level the loader holds through the firmware region; the DSP
        // ROM port sees prog_addr[12:0] with the byte
        if(!prog_qsnd || prog_we || prog_addr[12:0]!==k[12:0]) $fatal(1,"firmware byte %0d: prom_we=%b prog_we=%b addr=%h",k,prog_qsnd,prog_we,prog_addr);
    end
end
endtask

// Wait until the DSP has read both voices at the expected words, then keep
// counting for 100 more sample periods (4000 clocks each): the steady state
// must repeat them (the DSP reads every voice every period) and must never
// produce `absent`. Transient addresses do occur while the latch holds one
// voice's bank with the next voice's offset (the stock latch behaves the
// same), so only words that no transient can form are asserted absent.
function automatic integer count_of(input [23:0] w);
    count_of = seen_word.exists(longint'(w)) ? seen_word[longint'(w)] : 0;
endfunction
task await_words(input [23:0] w1, input [23:0] w2, input [23:0] absent, input string label);
integer n;
begin
    seen_word.delete(); high_fetches=0;
    n=0;
    while(!(seen_word.exists(longint'(w1)) && seen_word.exists(longint'(w2)))) begin
        repeat(1000) @(negedge clk);
        n=n+1;
        if(n>40000) $fatal(1,"%s: the DSP never fetched words %h and %h (%0d bank-1 bursts so far, last %h)",label,w1,w2,bank1_reads,last_ba1);
    end
    repeat(400000) @(negedge clk);
    if(count_of(w1)<50 || count_of(w2)<50)
        $fatal(1,"%s: words %h/%h fetched only %0d/%0d times in the steady state",label,w1,w2,count_of(w1),count_of(w2));
    if(count_of(absent)!=0) $fatal(1,"%s: word %h was fetched %0d times",label,absent,count_of(absent));
end
endtask

integer upper_after_1, reads_after_1;
initial begin
    if(!$value$plusargs("MUTATE=%s",mutation)) mutation="";
    firmware_mode = $value$plusargs("FIRMWARE=%s",firmware_file);
    if(firmware_mode) begin : firmware_phases
        integer high_seen;
        if(mutation!="") $fatal(1,"mutations apply to the forced-bus run");
        $readmemh(firmware_file, fw);
        // marker 07, flat order: header, the firmware before the graphics, the sparse library
        header(CPU_KIB, PCM_START, PCM_START+PCM_KIB+FW_KIB, PCM_START+PCM_KIB, 8'h07, 1'b1);
        if(sdram.cps2_qsnd_ext!==1) $fatal(1,"marker 07 rejected");
        download_firmware(FW_FLAT_BASE);
        download_library();
        finish_download();
        // the Z80 program releases the DSP and writes the voice registers; the
        // dl-1425 program then reads voice 1 at bank 0x80 offset 0x1234 and voice 2
        // at bank 0xff offset 0xff00 every sample period
        await_words(24'h40091a, 24'h7fff80, 24'h3fff80, "flat firmware");
        $display("PASS qsnd firmware flat: dl-1425 on jtdsp16, stock key-on registers with bank bytes 0x80 and 0xff, fetched bank 1 words 40091a (%0d times) and 7fff80 (%0d times) in the upper 8 MiB of chip 0 through the real latch, slot and controller, never the bank-0x7f mirror word; %0d bank-1 bursts, %0d above 8 MiB", count_of(24'h40091a), count_of(24'h7fff80), bank1_reads, upper_reads);
        // a marker 01 header alone (stock order): the DSP keeps its registers, the
        // capability goes off, the same voices must now read the mirror
        header(CPU_KIB, PCM_START, PCM_START+PCM_KIB, PCM_START+PCM_KIB+GFX32_KIB, 8'h01, 1'b0);
        if(sdram.cps2_qsnd_ext!==0) $fatal(1,"marker 01 left the capability on");
        finish_download();
        repeat(20000) @(negedge clk);   // requests issued before the switch drain
        await_words(24'h00091a, 24'h3fff80, 24'h7fff80, "mirror firmware");
        if(high_fetches!=0) $fatal(1,"mirror firmware: %0d fetches above 8 MiB with the capability off",high_fetches);
        $display("PASS qsnd firmware mirror: capability off, the same DSP voices read bank 1 words 00091a (%0d times) and 3fff80 (%0d times), banks 0x00 and 0x7f, no fetch above 8 MiB", count_of(24'h00091a), count_of(24'h3fff80));
        $display("PASS qsnd: real DSP program, %0d bank-1 bursts in total, chip 1 never read", bank1_reads);
        $finish;
    end
    mut_latch = mutation=="latch";
    mut_mirror = mutation=="mirror";
    if(mutation!="" && !mut_latch && !mut_mirror) $fatal(1,"unknown mutation %s",mutation);
    // Phase 1: marker 07, flat order: CPU 8 MiB, Z80 256 KiB, samples 16 MiB, firmware 8 KiB, graphics.
    header(CPU_KIB, PCM_START, PCM_START+PCM_KIB+FW_KIB, PCM_START+PCM_KIB, 8'h07, 1'b1);
    if(ext!==1 || obj_cap!==1 || sdram.cps2_qsnd_ext!==1) $fatal(1,"marker 07 rejected: ext=%b obj=%b qsnd=%b",ext,obj_cap,sdram.cps2_qsnd_ext);
    download_library();
    finish_download();
    if(sdram.cps2_qsnd_ext!==1) $fatal(1,"capability lost after the download");
    sweep(1'b1, "flat");
    if(upper_reads==0) $fatal(1,"no fetch reached the upper 8 MiB of bank 1");
    upper_after_1=upper_reads; reads_after_1=bank1_reads;
    $display("PASS qsnd flat: marker 07, 256 banks x 6 downloaded offsets read back f(bank<<16|offset) through the DSP latch, the PCM slot, jtframe_sdram64 and chip 0 bank 1 (%0d fetches, %0d of them never downloaded and matching the chip pattern at the exact word, %0d SDRAM bursts, %0d from the upper 8 MiB)",
        fetches+pattern_fetches, pattern_fetches, bank1_reads, upper_reads);
    // Phase 2: marker 01, stock order with a 16 MiB sample region (the stock loader writes all of it
    // to bank 1); the capability is off so the DSP's bank bit 7 must be ignored: a mirror.
    fetches=0; pattern_fetches=0;
    header(CPU_KIB, PCM_START, PCM_START+PCM_KIB, PCM_START+PCM_KIB+GFX32_KIB, 8'h01, 1'b0);
    if(ext!==1 || obj_cap!==0 || sdram.cps2_qsnd_ext!==0) $fatal(1,"marker 01 (stock order) wrong: ext=%b obj=%b qsnd=%b",ext,obj_cap,sdram.cps2_qsnd_ext);
    download_library();
    finish_download();
    if(mut_mirror) force sdram.cps2_qsnd_ext = 1'b1;
    sweep(1'b0, "mirror");
    if(upper_reads!=upper_after_1) $fatal(1,"capability off: %0d fetches reached the upper 8 MiB",upper_reads-upper_after_1);
    $display("PASS qsnd mirror: marker 01 with the same 16 MiB region in the stock order, banks 0x80..0xff read banks 0x00..0x7f byte for byte (%0d fetches, %0d pattern fetches at the mirrored word, 0 upper-half bursts)",
        fetches+pattern_fetches, pattern_fetches);
    // Phase 3: marker 05, flat order without the slice.
    fetches=0; pattern_fetches=0;
    header(CPU_KIB, PCM_START, PCM_START+PCM_KIB+FW_KIB, PCM_START+PCM_KIB, 8'h05, 1'b0);
    if(ext!==1 || obj_cap!==0 || sdram.cps2_qsnd_ext!==1) $fatal(1,"marker 05 wrong: ext=%b obj=%b qsnd=%b",ext,obj_cap,sdram.cps2_qsnd_ext);
    finish_download();
    sweep(1'b1, "flat05");
    $display("PASS qsnd flat05: marker 05 (no slice) reads the upper 8 MiB as marker 07 does (%0d fetches)", fetches+pattern_fetches);
    $display("PASS qsnd: flat 24-bit QSound sample address through the DSP latch, the capability mask, the PCM slot and the 128 MiB controller: %0d bank-1 bursts in total, chip 1 never read, %0d download words all in bank 1",
        bank1_reads, prog_words);
    $finish;
end
endmodule
