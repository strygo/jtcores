`timescale 1ns/1ps
module tb_loader;
reg clk=0;
always #5 clk=~clk;
reg ioctl_rom=1, ioctl_wr=0, ioctl_ram=0;
reg [25:0] ioctl_addr=0;
reg [7:0] ioctl_dout=0;
wire [22:0] prog_addr;
wire [15:0] prog_data;
wire [1:0] prog_mask, prog_ba;
wire prog_we, prom_we, ext;
integer checks=0;
jtcps1_prom_we #(.CPS(2),.SND_OFFSET(23'h380000)) dut(
    .clk(clk), .ioctl_rom(ioctl_rom), .ioctl_wr(ioctl_wr), .ioctl_ram(ioctl_ram),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .prog_rdy(1'b1),
    .prog_addr(prog_addr), .prog_data(prog_data), .prog_mask(prog_mask),
    .prog_ba(prog_ba), .prog_we(prog_we), .prom_we(prom_we), .cps2_prog_ext(ext)
);
task put(input [25:0] addr, input [7:0] data);
begin
    @(negedge clk); ioctl_addr=addr; ioctl_dout=data; ioctl_wr=1;
    @(posedge clk); #1;
end
endtask
task header(input [15:0] cpu_kib, input [31:0] marker);
reg [63:0] starts;
integer i;
begin
    starts={16'hb080,16'h3080,16'h2080,cpu_kib};
    for(i=0;i<8;i=i+1) put(i,starts[i*8+:8]);
    for(i=8;i<12;i=i+1) put(i,8'hff);
    for(i=0;i<4;i=i+1) put(12+i,marker[24-8*i+:8]);
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
    $display("PASS loader: %0d CPU mappings, byte lanes, region boundaries, malformed headers, reload",checks);
    $finish;
end
endmodule
