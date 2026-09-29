`timescale 1ns/1ps
module tb_loader;
reg clk=0;
always #5 clk=~clk;
reg ioctl_rom=1, ioctl_wr=0, ioctl_ram=0;
reg [25:0] ioctl_addr=0;
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
    .cps2_obj_ext(obj)
);
task put(input [25:0] addr, input [7:0] data);
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
// The CPS-2 graphics download scramble (MAME's per-2 MiB tile unshuffle).
function [25:0] scramble(input [25:0] r);
    scramble = {r[25:21], r[3], r[20:4], r[2:0]};
endfunction
// One graphics byte at region offset r: bank {1, r[23]}, word address
// {slice, r[24], s[22:1]} where slice = r[25] with the capability on.
task gfx_byte(input integer r, input slice_on);
reg [25:0] s;
begin
    s=scramble(r[25:0]);
    put(64+16'h3080*1024+r,8'h5a);
    if(!prog_we || prom_we || prog_ba!=={1'b1,s[23]} || prog_addr!=={slice_on&&s[25],s[24],s[22:1]} ||
       prog_mask!==(r[0] ? 2'b01 : 2'b10))
        $fatal(1,"graphics byte at %h: ba=%h word=%h expected=%h we=%b",r,prog_ba,prog_addr,{slice_on&&s[25],s[24],s[22:1]},prog_we);
    gfx_checks=gfx_checks+1;
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
    $finish;
end
endmodule
