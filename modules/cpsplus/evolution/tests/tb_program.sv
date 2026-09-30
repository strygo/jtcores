`timescale 1ns/1ps
// Actual CPS2 CPU/decrypt/SDRAM-slot RTL. Only external SDRAM is modeled.
module tb_program;
reg clk=0;
always #5 clk=~clk;
reg clk_cpu=0;
always #10 clk_cpu=~clk_cpu; // preserve the core's 96:48 MHz domain ratio
reg rst=1, lvbl=1;
reg [7:0] ioctl_dout=0;
reg [25:0] ioctl_addr=0;
reg ioctl_wr=0, ioctl_rom=1;
wire ext, hold_rst, rom_cs, rom_ok, ram_ok, rnw;
wire [22:1] rom_addr;
wire [17:1] ram_addr;
wire [15:0] rom_data, ram_data, cpu_dout;
wire ram_cs, vram_cs, oram_cs, udswn, ldswn, obank;
wire [15:0] oram_base;
wire [23:0] ba0_addr, prog_addr; // 24-bit SDRAM word addresses (CPS2_OBJEXT / JTFRAME_SDRAM_XL); bank 0 stays below 16 MiB
wire [3:0] ba_rd, ba_wr;
wire [15:0] ba0_din, prog_data;
wire [1:0] ba0_dsn, prog_ba, prog_mask;
wire prog_we, key_we;
reg [3:0] ba_ack=0, ba_dst=0, ba_rdy=0;
reg [15:0] data_read=0;
reg [15:0] mem[0:8388607];
integer tx=0, beat=0, latency=0, clocks=0, reads=0, ext_reads=0, passes=0;
reg [23:0] tx_addr;
integer hold_addr, hold_idx;
reg tx_write;
reg [15:0] tx_data;
reg [1:0] tx_mask;
reg irq_sent=0;
reg sweep_enable=0;
reg [23:1] sweep_address=0;
reg [2:0] sweep_fc=0;
integer decode_checks=0;
integer bound_page='h3ff, window_reads=0;
reg inwindow_mode=0;
string program_file;
// The QSound side as the 68K sees it: the Z80 grants its bus one CPU clock
// after the request, reads return 0xff (the driver's acknowledge, so a hook's
// ack polls end at once) except the driver's ready mark 0x77 at Z80 0xcfff,
// and every write is logged. Writes to the
// command record (Z80 0xc000/0xc001) followed by a 0x00 handshake at 0xc00f
// are the posted sound commands; +QSCMDS=<hex> names the expected list.
reg qs_busakn=1, qs_seen=0;
wire [7:0] qs_din = main.main2qs_addr[16:1]==16'hcfff ? 8'h77 : 8'hff;
reg [7:0] qs_hi=0, qs_lo=0;
reg [15:0] qs_cmds [0:63];
integer qs_posted=0, qs_writes=0;
string qs_expect;
always @(posedge clk_cpu) begin
    qs_busakn <= ~main.main2qs_cs;
    if(!main.main2qs_cs) qs_seen<=0;
    else if(!rnw && !ldswn && !qs_seen) begin
        qs_seen<=1; qs_writes=qs_writes+1;
        case(main.main2qs_addr[16:1])
            16'hc000: qs_hi=cpu_dout[7:0];
            16'hc001: qs_lo=cpu_dout[7:0];
            16'hc00f: if(cpu_dout[7:0]==8'h00 && qs_posted<64) begin qs_cmds[qs_posted]={qs_hi,qs_lo}; qs_posted=qs_posted+1; end
            default: ;
        endcase
    end
end

task check_decode(input integer byte_address);
reg expected_rom, expected_ext;
integer logical_byte, physical_byte;
begin
    sweep_address=byte_address[23:1];
    repeat(6) @(negedge clk);
    expected_ext=sweep_enable && byte_address>='ha00000 && byte_address<'he00000;
    expected_rom=byte_address<'h400000 || expected_ext;
    if(rom_cs!==expected_rom) $fatal(1,"ROM decode mismatch at %h enhanced=%b",byte_address,sweep_enable);
    if(expected_rom) begin
        logical_byte=expected_ext ? byte_address-'h600000 : byte_address;
        physical_byte=expected_ext ? byte_address-'h200000 : byte_address;
        if(rom_addr!==(logical_byte>>1) || sdram.main_rom_phys!==(physical_byte>>1))
            $fatal(1,"runtime address mismatch at %h logical=%h physical=%h",byte_address,rom_addr,sdram.main_rom_phys);
    end
    if(main.pre_ram_cs !== (byte_address>='hff0000) ||
       main.pre_vram_cs !== (byte_address>='h900000 && byte_address<'h930000) ||
       main.main2qs_cs !== (byte_address>='h600000 && byte_address<'h620000) ||
       main.io_cs !== (byte_address>='h800000 && byte_address<'h880000))
        $fatal(1,"original device decode changed at %h",byte_address);
    // Force the encrypted result to a distinct sentinel, with encryption
    // enabled over the entire address space. Only extension fetches bypass it.
    // Opcode fetches decrypt only through the key's last encrypted page.
    if(main.rom_dec !== ((sweep_fc[1:0]==2 && !expected_ext && (byte_address>>14)<=bound_page) ? 16'h1234 : 16'habcd))
        $fatal(1,"opcode/data selection failed at %h fc=%h bound=%h",byte_address,sweep_fc,bound_page);
    decode_checks=decode_checks+1;
end
endtask

jtcps2_main main(
    .rst(rst|hold_rst|ioctl_rom), .clk(clk_cpu), .clk_rom(clk), .prog_ext(ext),
    .V(9'd0), .LVBL(lvbl), .LHBL(1'b1), .skip_en(1'b0),
    .mmr_dout(16'hffff), .raster(1'b0),
    .UDSWn(udswn), .LDSWn(ldswn), .prog_din(ioctl_dout), .key_we(key_we),
    .joymode(2'd0), .joystick1(10'h3ff), .joystick2(10'h3ff),
    .joystick3(10'h3ff), .joystick4(10'h3ff), .dial_x(2'd0), .dial_y(2'd0),
    .cab_1p(4'hf), .coin(4'hf), .service(1'b1), .tilt(1'b1), .dipsw(32'd0),
    .busreq(1'b0), .RnW(rnw), .addr(ram_addr), .cpu_dout(cpu_dout),
    .ram_cs(ram_cs), .vram_cs(vram_cs), .oram_cs(oram_cs), .obank(obank),
    .oram_base(oram_base), .ram_data(ram_data), .ram_ok(ram_ok),
    .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
    .dip_test(1'b1), .dip_pause(1'b1), .eeprom_sdo(1'b1),
    .main2qs_din(qs_din), .main2qs_busakn(qs_busakn), .main2qs_waitn(1'b1),
    .volume(13'd0), .debug_bus(8'd0)
);
jtcps1_sdram #(.CPS(2)) sdram(
    .rst(rst), .clk(clk), .clk_cpu(clk_cpu), .clk_gfx(clk), .LVBL(lvbl), .hold_rst(hold_rst),
    .ioctl_rom(ioctl_rom), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wr(ioctl_wr), .ioctl_ram(1'b0), .prog_rdy(1'b1),
    .prog_addr(prog_addr), .prog_ba(prog_ba), .prog_mask(prog_mask),
    .prog_data(prog_data), .prog_we(prog_we), .cps2_prog_ext(ext), .cps2_key_we(key_we),
    .sclk(1'b0), .sdi(1'b0), .scs(1'b0),
    .main_rom_cs(rom_cs), .main_rom_addr(rom_addr), .main_rom_data(rom_data), .main_rom_ok(rom_ok),
    .vram_clr(1'b0), .vram_dma_cs(1'b0), .main_ram_cs(ram_cs), .main_vram_cs(vram_cs),
    .main_oram_cs(oram_cs), .obank(obank), .oram_base(oram_base),
    .gfx_oram_addr(13'd0), .gfx_oram_clr(1'b0), .gfx_oram_cs(1'b0), .vram_rfsh_en(1'b0),
    .dsn({udswn,ldswn}), .main_dout(cpu_dout), .main_rnw(rnw), .main_ram_ok(ram_ok),
    .main_ram_addr(ram_addr), .vram_dma_addr(17'd0), .main_ram_data(ram_data),
    .snd_cs(1'b0), .pcm_cs(1'b0), .snd_addr(19'd0), .pcm_addr(23'd0),
    .rom0_cs(1'b0), .rom1_cs(1'b0), .rom0_addr(20'd0), .rom0_bank(3'd0),
    .rom1_addr(20'd0), .rom0_half(1'b0), .rom1_half(1'b0),
    .star_bank(1'b0), .star0_addr(13'd0), .star0_cs(1'b0), .star1_addr(13'd0), .star1_cs(1'b0),
    .ba0_addr(ba0_addr), .ba_rd(ba_rd), .ba_wr(ba_wr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
    .ba_ack(ba_ack), .ba_dst(ba_dst), .ba_dok(4'd0), .ba_rdy(ba_rdy), .data_read(data_read)
);

// Four-word burst model, variable request latency. This is not electrical
// SDRAM validation: the real controller/PHY is a separate Quartus/hardware gate.
always @(negedge clk) begin
    ba_ack=0; ba_dst=0; ba_rdy=0;
    clocks=clocks+1;
    if(clocks>30000000) $fatal(1,"timeout CPU addr=%h status=%h hold=%b tx=%d",{main.A,1'b0},mem['h300000],hold_rst,tx);
    if(rst) tx=0;
    else case(tx)
        0: if(ba_rd[0] || ba_wr[0]) begin
            tx_addr=ba0_addr; tx_write=ba_wr[0]; tx_data=ba0_din; tx_mask=ba0_dsn;
            if(tx_addr[23]) $fatal(1,"bank 0 access above 16 MiB: %h",tx_addr);
            latency=2+(reads%5); tx=1;
        end
        1: if(latency!=0) latency=latency-1;
           else begin ba_ack[0]=1; beat=0; tx=2; end
        2: begin
            if(tx_write) begin
                if(!tx_mask[1]) mem[tx_addr][15:8]=tx_data[15:8];
                if(!tx_mask[0]) mem[tx_addr][7:0]=tx_data[7:0];
                if(tx_addr==24'h300001 && tx_data==16'h1234 && !hold_rst && !irq_sent) begin
                    lvbl=0; irq_sent=1;
                end
                data_read=mem[tx_addr]; ba_dst[0]=1; ba_rdy[0]=1; tx=3;
            end else begin
                data_read=mem[(tx_addr & 24'h7ffffc)+((tx_addr+beat)&3)];
                ba_dst[0]=(beat==0);
                ba_rdy[0]=(beat==3);
                if(beat==3) begin
                    reads=reads+1;
                    if(tx_addr>=24'h400000) ext_reads=ext_reads+1;
                    if(tx_addr>=24'h1fd880 && tx_addr<24'h200000) window_reads=window_reads+1; // bytes 3fb100..3fffff
                    tx=3;
                end else beat=beat+1;
            end
        end
        3: tx=0;
    endcase
    if(!hold_rst && !ioctl_rom && !rst) begin
        if(mem['h300000]===16'hdead) $fatal(1,"diagnostic reported failure: addr=%h irq=%b bursts=%d",{main.A,1'b0},irq_sent,reads);
    end
end
task put(input [25:0] a,input [7:0] b);
begin
    @(negedge clk); ioctl_addr=a; ioctl_dout=b; ioctl_wr=1;
    @(negedge clk); ioctl_wr=0;
    repeat(3) @(negedge clk);
end
endtask
integer i;
reg [63:0] starts=64'hb080308020802000;
reg [7:0] rom_key[0:19];
reg hook_mode=0;
integer reset_entry, entry_opcode;
initial begin
    hook_mode=$test$plusargs("HOOK");
    // Sparse ROM image was constructed through the tested download mapping.
    if(hook_mode) begin
        if(!$value$plusargs("PROGRAM=%s",program_file)) program_file="hook-program.hex";
        inwindow_mode=$test$plusargs("INWINDOW");
        $readmemh(program_file,mem);
        $readmemh("key.hex",rom_key);
        if(!$value$plusargs("ENTRY=%h",reset_entry) || !$value$plusargs("OPCODE=%h",entry_opcode))
            $fatal(1,"missing verified original entry identity");
        // A hook that holds a picture on screen keeps its hold count as a long
        // word in the extension window; the RTL run shortens only that count.
        if($value$plusargs("HOLD_ADDR=%h",hold_addr)) begin
            if(hold_addr<'ha00000 || hold_addr>='hc00000 || hold_addr[0]) $fatal(1,"hold count outside the extension window");
            hold_idx='h400000 | ((hold_addr-'ha00000)>>1);
            mem[hold_idx]=16'h0000;
            mem[hold_idx+1]=16'h0002;
        end
    end else begin
        $readmemh("program.hex",mem);
        for(i=0;i<20;i=i+1) rom_key[i]=8'hff;
    end
    for(i=0;i<8;i=i+1) put(i,starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(i,8'hff);
    put(12,8'h43); put(13,8'h32); put(14,1); put(15,1);
    for(i=16;i<44;i=i+1) put(i,8'hff);
    for(i=0;i<20;i=i+1) put(44+i,rom_key[i]);
    repeat(20) @(negedge clk);
    if(ext!==1) $fatal(1,"extension header not enabled");
    ioctl_rom=0; rst=0;
    if(hook_mode) begin
        wait(!hold_rst && main.A==reset_entry[23:1] && main.FC==6 && rom_ok && main.rom_ok2 && main.rom_dec==entry_opcode[15:0]);
        if(ext_reads<4) $fatal(1,"game hook never traversed extension");
        if($value$plusargs("QSCMDS=%s",qs_expect)) begin : qscmds
            integer n;
            n = qs_expect.len()/4;
            if(qs_posted!=n) $fatal(1,"hook posted %0d sound commands, expected %0d (%0d QSound writes)",qs_posted,n,qs_writes);
            for(i=0;i<n;i=i+1) if(qs_cmds[i]!==16'(qs_expect.substr(4*i,4*i+3).atohex()))
                $fatal(1,"sound command %0d was %h, expected %s",i,qs_cmds[i],qs_expect.substr(4*i,4*i+3));
            $display("PASS game hook sound: %0d commands posted at the QSound port in the expected order (%s), %0d QSound writes",n,qs_expect,qs_writes);
        end else if(qs_posted!=0) $fatal(1,"hook posted %0d unexpected sound commands",qs_posted);
        if(inwindow_mode && window_reads<1) $fatal(1,"in-window hook never fetched above the key bound");
        if(inwindow_mode)
            $display("PASS game hook: encrypted reset vector executes plaintext code above the key bound inside the original window, then the extension, and returns to original encrypted entry %h; full-game boot remains untested",reset_entry);
        else
            $display("PASS game hook: encrypted reset vector executes plaintext extension and returns to original encrypted entry %h; full-game boot remains untested",reset_entry);
        $finish;
    end
    wait(mem['h300000]===16'h600d);
    if(ext_reads<5 || !irq_sent || mem['h300002]!==16'h6789)
        $fatal(1,"insufficient execution coverage");
    $display("PASS CPU run 1: extension JSR/RTS, data, split boundary, cache alternation, interrupt/RTE (%0d ROM bursts)",reads);
    @(negedge clk); rst=1; lvbl=1; irq_sent=0;
    repeat(20) @(negedge clk);
    rst=0;
    wait(hold_rst===0);
    wait(mem['h300000]===16'h0000);
    wait(mem['h300000]===16'h600d);
    if(ext!==1 || !irq_sent) $fatal(1,"reset lost extension or skipped interrupt");
    $display("PASS CPU run 2: reset restarts diagnostic, invalidates cache and preserves image capability");
    force main.A=sweep_address;
    force main.ASn=0;
    force main.BGACKn=1;
    force main.RnW=1;
    force main.FC=sweep_fc;
    // Decode sweep has no bus handshakes; bus timing was checked by the
    // executing diagnostic above. Prevent this artificial traffic counting
    // as stalled CPU cycles in the compensation circuit.
    force main.u_dtack.bus_busy=0;
    force main.prog_ext=sweep_enable;
    force main.u_decrypt.dec_en=1;
    force main.u_decrypt.addr_rng=16'h0000; // field 0 = bound page 0x3ff: encryption over the entire space
    force main.u_decrypt.dec_data=16'h1234;
    force main.u_decrypt.din=16'habcd;
    for(integer mode=0;mode<2;mode=mode+1) begin
        sweep_enable=mode[0];
        sweep_fc=6;
        for(integer address=0;address<'h1000000;address=address+256) begin
            check_decode(address);
            check_decode(address+254);
        end
        for(integer fc=0;fc<8;fc=fc+1) begin
            sweep_fc=fc[2:0];
            check_decode('h0); check_decode('h3ffffe);
            check_decode('h9ffffe); check_decode('ha00000);
            check_decode('hbffffe); check_decode('hc00000);
            check_decode('hdffffe); check_decode('he00000);
        end
    end
    $display("PASS decode: %0d cases, legacy/extension selection, device isolation and opcode/data views",decode_checks);
    // The key's encrypted address range: pages 0..~field. vsav2/vhunt2/vsavj/sfa3
    // carry field 0x3c0 (first 1 MiB); an ssf2t-class key carries 0x200 (whole window).
    begin : key_range
        integer range_start;
        range_start=decode_checks;
        for(integer variant=0;variant<2;variant=variant+1) begin
            if(variant==0) begin force main.u_decrypt.addr_rng=16'h03c0; bound_page='h3f; end
            else begin force main.u_decrypt.addr_rng=16'h0200; bound_page='h1ff; end
            for(integer mode=0;mode<2;mode=mode+1) begin
                sweep_enable=mode[0];
                for(integer fc=0;fc<8;fc=fc+1) begin
                    sweep_fc=fc[2:0];
                    for(integer address=0;address<'h400000;address=address+'h4000) begin
                        check_decode(address);
                        check_decode(address+'h3ffe);
                    end
                    check_decode('ha00000); check_decode('hdffffe);
                end
            end
        end
        $display("PASS key range: %0d cases, opcode fetches decrypted only through page ~field (1 MiB and whole-window keys), data and extension untouched",decode_checks-range_start);
        force main.u_decrypt.addr_rng=16'h0000; bound_page='h3ff; sweep_fc=6;
    end
    force main.RnW=0;
    sweep_enable=1; sweep_address=23'h500000;
    repeat(6) @(negedge clk);
    if(rom_cs || main.pre_ram_cs || main.pre_vram_cs || main.pre_oram_cs)
        $fatal(1,"extension write selected ROM or RAM");
    force main.BGACKn=0;
    force main.RnW=1;
    repeat(6) @(negedge clk);
    if(rom_cs) $fatal(1,"CPU extension request asserted during DMA bus ownership");
    $display("PASS extension write rejection and DMA bus ownership");
    $finish;
end
endmodule
