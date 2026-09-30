`timescale 1ns/1ps
module tb_loader;
reg clk=0;
always #5 clk=~clk;
reg ioctl_rom=1, ioctl_wr=0, ioctl_ram=0;
`ifdef CPS2_QSND24
reg [26:0] ioctl_addr=0; // 27-bit download bus (JTFRAME_SDRAM_XL): the flat QSound image is 64.25 MiB
wire qsnd;
`else
reg [25:0] ioctl_addr=0;
`endif
reg [7:0] ioctl_dout=0;
wire [23:0] prog_addr; // 24-bit SDRAM word address (CPS2_OBJEXT / JTFRAME_SDRAM_XL)
wire [15:0] prog_data;
wire [1:0] prog_mask, prog_ba;
wire prog_we, prom_we, ext, obj;
integer checks=0, gfx_checks=0;
jtcps1_prom_we #(.CPS(2),.SND_OFFSET(23'h380000)) dut(
    .clk(clk), .ioctl_rom(ioctl_rom), .ioctl_wr(ioctl_wr), .ioctl_ram(ioctl_ram),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .prog_rdy(1'b1),
    .prog_addr(prog_addr), .prog_data(prog_data), .prog_mask(prog_mask),
    .prog_ba(prog_ba), .prog_we(prog_we), .prom_we(prom_we), .cps2_prog_ext(ext),
`ifdef CPS2_QSND24
    .cps2_qsnd_ext(qsnd),
`endif
    .cps2_obj_ext(obj)
);
`ifdef CPS2_QSND24
task put(input [26:0] addr, input [7:0] data);
`else
task put(input [25:0] addr, input [7:0] data);
`endif
begin
    @(negedge clk); ioctl_addr=addr; ioctl_dout=data; ioctl_wr=1;
    @(posedge clk); #1;
end
endtask
// Region starts in KiB: CPU, Z80 at cpu_kib, PCM 128 KiB later, graphics 4 MiB
// later, DSP firmware after gfx_kib of graphics (stock fixture: 32 MiB).
task header_gfx(input [15:0] cpu_kib, input [15:0] gfx_kib, input [31:0] marker);
reg [63:0] starts;
integer i;
begin
    starts={16'h3080+gfx_kib,16'h3080,16'h2080,cpu_kib};
    for(i=0;i<8;i=i+1) put(i,starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(i,8'hff);
    for(i=0;i<4;i=i+1) put(12+i,marker[24-8*i+:8]);
end
endtask
task header(input [15:0] cpu_kib, input [31:0] marker);
begin
    header_gfx(cpu_kib, 16'h8000, marker);
end
endtask
`ifdef CPS2_QSND24
// Flat order (marker bit 04): CPU cpu_kib, Z80 z80_kib, samples pcm_kib, firmware fw_kib, graphics after.
task header_flat(input [15:0] cpu_kib, input [15:0] z80_kib, input [15:0] pcm_kib, input [15:0] fw_kib, input [31:0] marker);
reg [63:0] starts;
integer i;
begin
    starts={cpu_kib+z80_kib+pcm_kib, cpu_kib+z80_kib+pcm_kib+fw_kib, cpu_kib+z80_kib, cpu_kib}; // {qsnd, gfx, pcm, snd}
    for(i=0;i<8;i=i+1) put(27'(i),starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(27'(i),8'hff);
    for(i=0;i<4;i=i+1) put(27'(12+i),marker[24-8*i+:8]);
end
endtask
// Stock order with a 16 MiB sample region: CPU 8 MiB, Z80 256 KiB, samples 16 MiB, graphics 32 MiB, firmware.
task header_stock16(input [31:0] marker);
reg [63:0] starts;
integer i;
begin
    starts={16'he100, 16'h6100, 16'h2100, 16'h2000};
    for(i=0;i<8;i=i+1) put(27'(i),starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(27'(i),8'hff);
    for(i=0;i<4;i=i+1) put(27'(12+i),marker[24-8*i+:8]);
end
endtask
`endif
// The CPS-2 graphics download scramble (MAME's per-2 MiB tile unshuffle).
function [25:0] scramble(input [25:0] r);
    scramble = {r[25:21], r[3], r[20:4], r[2:0]};
endfunction
// One graphics byte at region offset r: bank {1, r[23]}, word address
// {slice, r[24], s[22:1]} where slice = r[25] with the capability on.
task gfx_byte_at(input integer base_kib, input integer r, input slice_on);
reg [25:0] s;
begin
    s=scramble(r[25:0]);
    put(64+base_kib*1024+r,8'h5a);
    if(!prog_we || prom_we || prog_ba!=={1'b1,s[23]} || prog_addr!=={slice_on&&s[25],s[24],s[22:1]} ||
       prog_mask!==(r[0] ? 2'b01 : 2'b10))
        $fatal(1,"graphics byte at %h: ba=%h word=%h expected=%h we=%b",r,prog_ba,prog_addr,{slice_on&&s[25],s[24],s[22:1]},prog_we);
    gfx_checks=gfx_checks+1;
end
endtask
task gfx_byte(input integer r, input slice_on);
begin
    gfx_byte_at(16'h3080, r, slice_on);
end
endtask
task cpu_byte(input integer a, input integer physical);
begin
    put(64+a,8'ha5);
    if(!prog_we || prom_we || prog_ba!==0 || prog_addr!==(physical>>1) ||
       prog_mask!==(a[0] ? 2'b01 : 2'b10) || prog_data!==16'ha5a5)
        $fatal(1,"loader at %h: word=%h expected=%h ba=%h we=%b prom=%b mask=%b data=%h",a,prog_addr,physical>>1,prog_ba,prog_we,prom_we,prog_mask,prog_data);
    checks=checks+1;
end
endtask
integer a, i;
initial begin
    header(16'h2000,32'h43320101);
    if(ext!==1) $fatal(1,"valid header rejected");
    // Exhaust every 256-byte boundary plus both byte lanes and region ends.
    for(a=0;a<8388608;a=a+256) begin
        cpu_byte(a, a<4194304 ? a : a+4194304);
        cpu_byte(a+1, a<4194304 ? a+1 : a+4194305);
    end
    cpu_byte(4194303,4194303);
    cpu_byte(8388607,12582911);
    put(64+8388608,8'h5a);
    if(prog_ba!==0 || prog_addr!==23'h380000 || !prog_we)
        $fatal(1,"sound ROM region shifted into CPU extension");
    put(64+16'h2080*1024,0);
    if(prog_ba!==1 || prog_addr!==0 || !prog_we) $fatal(1,"sample region shifted");
    put(64+16'h3080*1024,0);
    if(prog_ba!==2 || prog_addr!==0 || !prog_we) $fatal(1,"graphics region shifted");
    put(64+16'hb080*1024,0);
    if(!prom_we || prog_we) $fatal(1,"firmware region not isolated");
    // Every single-bit mutation of the capability marker must fail closed.
    for(i=0;i<32;i=i+1) begin
        header(16'h2000,32'h43320101 ^ (32'b1<<i));
        if(ext!==0) $fatal(1,"malformed marker enabled extension");
        put(64+4194304,0);
        if(prog_we) $fatal(1,"unauthorized CPU payload overwrites RAM");
    end
    header(16'h1000,32'h43320101);
    if(ext!==0) $fatal(1,"wrong CPU region length enabled extension");
    header(16'h2000,32'h43320101);
    put(0,0);
    if(ext!==0) $fatal(1,"new download retained extension");
    header(16'h1000,32'hffffffff);
    cpu_byte(0,0); cpu_byte(4194303,4194303);
    if(obj!==0) $fatal(1,"object slice enabled without a marker");
    $display("PASS loader: %0d CPU mappings, byte lanes, region boundaries, malformed headers, reload",checks);
    // Capability mask 03: program window plus the 8 MiB object slice, which
    // needs a 40 MiB graphics region. Offsets 32..40 MiB land in bank 2 above
    // 16 MiB (word address bit 23); the 32 MiB library keeps its placement.
    header_gfx(16'h2000,16'ha000,32'h43320103);
    if(ext!==1 || obj!==1) $fatal(1,"marker 03 did not enable both capabilities: ext=%b obj=%b",ext,obj);
    for(a=0;a<41943040;a=a+65536) begin
        gfx_byte(a,1); gfx_byte(a+1,1); gfx_byte(a+9,1); gfx_byte(a+4098,1);
    end
    gfx_byte(33554431,1); gfx_byte(33554432,1); gfx_byte(41943039,1);
    put(64+16'hd080*1024,0);
    if(!prom_we || prog_we) $fatal(1,"firmware region does not follow the 40 MiB graphics region");
    put(64+16'h2080*1024,0);
    if(prog_ba!==1 || prog_addr!==0 || !prog_we) $fatal(1,"sample region moved by the slice");
    // 01 with a 40 MiB region: program only; the slice bytes are dropped, the library is written.
    header_gfx(16'h2000,16'ha000,32'h43320101);
    if(ext!==1 || obj!==0) $fatal(1,"marker 01 must enable the program window only: ext=%b obj=%b",ext,obj);
    gfx_byte(0,0); gfx_byte(33554431,0);
    put(64+16'h3080*1024+33554432,8'h5a);
    if(prog_we) $fatal(1,"unauthorized slice bytes overwrite the library");
    put(64+16'h3080*1024+41943039,8'h5a);
    if(prog_we) $fatal(1,"unauthorized slice bytes overwrite the library (last byte)");
    // 03 with the stock 32 MiB region, or with a 48 MiB region: both capabilities off.
    header_gfx(16'h2000,16'h8000,32'h43320103);
    if(ext!==0 || obj!==0) $fatal(1,"marker 03 accepted without a 40 MiB graphics region");
    header_gfx(16'h2000,16'hc000,32'h43320103);
    if(ext!==0 || obj!==0) $fatal(1,"marker 03 accepted with an oversized graphics region");
    header_gfx(16'h1000,16'ha000,32'h43320103);
    if(ext!==0 || obj!==0) $fatal(1,"marker 03 accepted without an 8 MiB CPU region");
    // Every single-bit mutation of 03 fails closed for the slice; only the
    // mutation that yields 01 keeps the program window.
    for(i=0;i<32;i=i+1) begin
        header_gfx(16'h2000,16'ha000,32'h43320103 ^ (32'b1<<i));
        if(obj!==0) $fatal(1,"malformed marker enabled the object slice");
        if(ext!==((32'h43320103 ^ (32'b1<<i))==32'h43320101)) $fatal(1,"malformed marker %h changed the program capability",32'h43320103 ^ (32'b1<<i));
    end
    header_gfx(16'h2000,16'ha000,32'h43320102);
    if(ext!==0 || obj!==0) $fatal(1,"slice without the program window accepted");
    // A new download clears both capabilities at byte zero.
    header_gfx(16'h2000,16'ha000,32'h43320103);
    put(0,0);
    if(ext!==0 || obj!==0) $fatal(1,"new download retained a capability");
    $display("PASS loader slice: marker 03 = program window + object slice (%0d graphics mappings, 40 MiB region, firmware follows), 01 = program only with slice bytes dropped, wrong region sizes and every marker mutation fail closed, reload clears",gfx_checks);
`ifdef CPS2_QSND24
    // Flat QSound (marker bit 04, patch 0006). The image order becomes CPU,
    // Z80, samples (exactly 16 MiB), DSP firmware (exactly 8 KiB, 8 KiB
    // aligned), graphics (open-ended): the four KiB start fields keep their
    // meaning and stay below 64 MiB while the download itself passes 64 MiB
    // (a 40 MiB graphics region ends at 64.25 MiB). Fixture: CPU 8 MiB at 0,
    // Z80 256 KiB at 0x2000, samples at 0x2100, firmware at 0x6100, graphics
    // at 0x6108 KiB.
    begin : flat_qsound
        integer o, k, sample_checks, fw_checks, flat_gfx, over64;
        reg [23:0] w;
        sample_checks=0; fw_checks=0; flat_gfx=0; over64=0;
        // the stock layouts of the tests above never turn the capability on
        header_gfx(16'h2000,16'ha000,32'h43320103);
        if(qsnd!==0) $fatal(1,"marker 03 enabled flat QSound");
        header(16'h2000,32'h43320101);
        if(qsnd!==0) $fatal(1,"marker 01 enabled flat QSound");
        // marker 07: all three capabilities
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320107);
        if(ext!==1 || obj!==1 || qsnd!==1) $fatal(1,"marker 07 did not enable all three capabilities: ext=%b obj=%b qsnd=%b",ext,obj,qsnd);
        // CPU and Z80 regions unchanged
        cpu_byte(0,0); cpu_byte(4194303,4194303); cpu_byte(4194304,8388608); cpu_byte(8388607,12582911);
        put(64+16'h2000*1024,8'h5a);
        if(prog_ba!==0 || prog_addr!==24'h380000 || !prog_we || prom_we) $fatal(1,"Z80 region moved in the flat order");
        put(64+16'h2100*1024-1,8'h5a);
        if(prog_ba!==0 || prog_addr!==24'h39ffff || !prog_we || prom_we) $fatal(1,"Z80 region end moved in the flat order");
        // samples: 16 MiB to bank 1 words 0..0x7fffff (chip 0), byte lanes by offset parity
        for(o=0;o<16777216;o=o+65536) for(k=0;k<4;k=k+1) begin
            case(k) 0: w=24'(o); 1: w=24'(o+1); 2: w=24'(o+32767); default: w=24'(o+65535); endcase
            put(64+16'h2100*1024+27'(w),8'h5a);
            if(!prog_we || prom_we || prog_ba!==2'd1 || prog_addr!=={1'b0,w[23:1]} || prog_mask!==(w[0] ? 2'b01 : 2'b10))
                $fatal(1,"sample byte %h: ba=%h word=%h we=%b prom=%b",w,prog_ba,prog_addr,prog_we,prom_we);
            sample_checks=sample_checks+1;
        end
        // DSP firmware: 8 KiB right after the samples, before the graphics
        for(o=0;o<8192;o=o+1) begin
            put(64+16'h6100*1024+27'(o),8'h5a);
            if(!prom_we || prog_we || prog_addr[12:0]!==o[12:0]) $fatal(1,"firmware byte %h: prom=%b we=%b addr=%h",o,prom_we,prog_we,prog_addr);
            fw_checks=fw_checks+1;
        end
        // graphics: 40 MiB from 0x6108 KiB, the same scramble and slice rule as marker 03; the last
        // 270,400 bytes lie above the 64 MiB download boundary (ioctl_addr bit 26)
        for(o=0;o<41943040;o=o+65536) begin
            gfx_byte_at(16'h6108,o,1); gfx_byte_at(16'h6108,o+1,1); gfx_byte_at(16'h6108,o+9,1); gfx_byte_at(16'h6108,o+4098,1);
            flat_gfx=flat_gfx+4;
            if(64+16'h6108*1024+o>=27'h4000000) over64=over64+4;
        end
        gfx_byte_at(16'h6108,33554431,1); gfx_byte_at(16'h6108,33554432,1); gfx_byte_at(16'h6108,41943039,1); flat_gfx=flat_gfx+3; over64=over64+1;
        if(64+16'h6108*1024+41943039<27'h4000000) $fatal(1,"fixture: the graphics region does not reach past 64 MiB");
        // beyond the 40 MiB library: dropped, never wrapped
        put(64+16'h6108*1024+27'd41943040,8'h5a);
        if(prog_we || prom_we) $fatal(1,"graphics byte at 40 MiB was written in the flat order");
        put(64+16'h6108*1024+27'd50331647,8'h5a);
        if(prog_we || prom_we) $fatal(1,"graphics byte at 48 MiB-1 was written in the flat order");
        put(27'h7ffffff,8'h5a);
        if(prog_we || prom_we) $fatal(1,"the last 27-bit address was written in the flat order");
        $display("PASS loader qsound: marker 07 = program window + object slice + flat QSound: %0d sample mappings (16 MiB to bank 1), %0d firmware bytes before the graphics, %0d graphics mappings of which %0d above the 64 MiB download boundary, bytes past 40 MiB dropped",sample_checks,fw_checks,flat_gfx,over64);
        // marker 05: flat QSound without the slice; graphics stop at 32 MiB
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320105);
        if(ext!==1 || obj!==0 || qsnd!==1) $fatal(1,"marker 05 wrong: ext=%b obj=%b qsnd=%b",ext,obj,qsnd);
        put(64+16'h2100*1024+27'hffffff,8'h5a);
        if(!prog_we || prog_ba!==2'd1 || prog_addr!==24'h7fffff) $fatal(1,"marker 05: last sample byte not in bank 1 word 7fffff");
        put(64+16'h6100*1024+27'd8191,8'h5a);
        if(!prom_we || prog_we || prog_addr[12:0]!==13'h1fff) $fatal(1,"marker 05: firmware not before the graphics");
        gfx_byte_at(16'h6108,0,0); gfx_byte_at(16'h6108,33554431,0);
        put(64+16'h6108*1024+27'd33554432,8'h5a);
        if(prog_we || prom_we) $fatal(1,"marker 05: graphics byte at 32 MiB was written");
        put(64+16'h6108*1024+27'd41943039,8'h5a);
        if(prog_we || prom_we) $fatal(1,"marker 05: graphics byte at 40 MiB-1 was written");
        // fail closed: wrong sample size, wrong firmware size, misaligned firmware, wrong CPU size, stock order, other masks
        header_flat(16'h2000,16'h100,16'h2000,16'd8,32'h43320107);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 07 accepted with an 8 MiB sample region");
        header_flat(16'h2000,16'h100,16'h4000,16'd16,32'h43320107);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 07 accepted with a 16 KiB firmware region");
        header_flat(16'h2000,16'h101,16'h4000,16'd8,32'h43320107);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 07 accepted with a misaligned firmware start");
        header_flat(16'h1000,16'h100,16'h4000,16'd8,32'h43320107);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 07 accepted without an 8 MiB CPU region");
        header_flat(16'h2000,16'h100,16'h2000,16'd8,32'h43320105);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 05 accepted with an 8 MiB sample region");
        header_gfx(16'h2000,16'ha000,32'h43320107);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 07 accepted with the stock region order");
        header_gfx(16'h2000,16'h8000,32'h43320105);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"marker 05 accepted with the stock region order");
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320104);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"flat QSound without the program window accepted");
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320106);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"mask 06 accepted");
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h4332010f);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"mask 0f accepted");
        // every single-bit mutation of 07: only 05 keeps a capability (program window + flat QSound)
        for(i=0;i<32;i=i+1) begin
            header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320107 ^ (32'b1<<i));
            if(obj!==0) $fatal(1,"malformed marker %h enabled the object slice",32'h43320107 ^ (32'b1<<i));
            if(qsnd!==((32'h43320107 ^ (32'b1<<i))==32'h43320105)) $fatal(1,"malformed marker %h changed flat QSound",32'h43320107 ^ (32'b1<<i));
            if(ext!==((32'h43320107 ^ (32'b1<<i))==32'h43320105)) $fatal(1,"malformed marker %h changed the program capability",32'h43320107 ^ (32'b1<<i));
        end
        // capability off with a 16 MiB sample region in the stock order: the stock loader already maps
        // all 16 MiB to bank 1; nothing above the firmware start reaches SDRAM (the stock top region)
        header_stock16(32'h43320101);
        if(ext!==1 || obj!==0 || qsnd!==0) $fatal(1,"stock order with 16 MiB of samples: ext=%b obj=%b qsnd=%b",ext,obj,qsnd);
        put(64+16'h2100*1024+27'hffffff,8'h5a);
        if(!prog_we || prog_ba!==2'd1 || prog_addr!==24'h7fffff) $fatal(1,"stock order: last sample byte not in bank 1 word 7fffff");
        put(64+16'he100*1024,8'h5a);
        if(!prom_we || prog_we) $fatal(1,"stock order: firmware not at its stock place after the graphics");
        put(27'h4000040,8'h5a);
        if(prog_we) $fatal(1,"stock order: a byte above 64 MiB reached SDRAM");
        // a new download clears all three
        header_flat(16'h2000,16'h100,16'h4000,16'd8,32'h43320107);
        put(0,0);
        if(ext!==0 || obj!==0 || qsnd!==0) $fatal(1,"new download retained a capability");
        $display("PASS loader qsound off: 05 = flat QSound without the slice (graphics stop at 32 MiB), 8 MiB samples / 16 KiB or misaligned firmware / 4 MiB CPU / stock order / masks 04 06 0f and every single-bit mutation of 07 fail closed (05 alone survives), capability off keeps the stock layout with 16 MiB of samples, reload clears");
    end
`endif
    $finish;
end
endmodule
