`timescale 1ns/1ps
// Geometry under test (module defaults): X0=Y0=8, SIZE=16, CELL_SH=3.
//   status square : x 8..23,  y 8..23
//   bit read-out  : y 26..33, nine 8 px cells from x=8 -> x 8..79
//                   cell 0 (MSB) x 8..15 ... cell 8 (mapped flag) x 72..79
// The frame is 96x48 so the WHOLE read-out including the flag cell is covered.
// It was 40x40, which left the flag cell off-screen and -- after the cell width
// changed from 6 to 8 -- also pushed the "safely outside" probe past the last
// pixel, so the background check silently sampled nothing and still read as a
// pass. Probe windows are asserted non-empty below for that reason.
module tb;
reg clk=0, pxl_cen=0, LHBL=0, LVBL=0, playing=0;
reg [3:0] status=0;
reg [7:0] last_cmd=8'h00;
reg last_mapped=0;
integer bits_lit, flag_green, flag_red, bg_seen;
wire [7:0] r,g,b;
integer x, y, hits_green, hits_red, outside;
cpsplus_dbg_overlay #(.X0(8),.Y0(8),.SIZE(16),.CELL_SH(3),.CW(8)) dut(
  .clk(clk), .pxl_cen(pxl_cen), .LHBL(LHBL), .LVBL(LVBL),
  .status(status), .playing(playing),
  .last_cmd(last_cmd), .last_mapped(last_mapped),
  .red_in(8'h20), .green_in(8'h20), .blue_in(8'h20),
  .red_out(r), .green_out(g), .blue_out(b));
always #5 clk = ~clk;
task frame(input _playing, input [3:0] _status, output integer box_green,
           output integer box_red, output integer bg_ok);
  begin
    playing=_playing; status=_status;
    box_green=0; box_red=0; bg_ok=0; bits_lit=0;
    flag_green=0; flag_red=0; bg_seen=0;
    LVBL=1;
    for( y=0; y<48; y=y+1 ) begin
      LHBL=1;
      for( x=0; x<96; x=x+1 ) begin
        @(posedge clk) pxl_cen=1; @(posedge clk) pxl_cen=0;
        @(posedge clk);
        if( x>=9 && x<23 && y>=9 && y<23 ) begin      // safely inside the box
          if( g==8'hff && r==8'h00 && b==8'h00 ) box_green=box_green+1;
          if( r==8'hff && g==8'h00 && b==8'h00 ) box_red=box_red+1;
        end
        if( y>=1 && y<7 ) begin                        // above everything drawn
          bg_seen=bg_seen+1;
          if( r==8'h20 && g==8'h20 && b==8'h20 ) bg_ok=bg_ok+1;
        end
        if( y>=27 && y<33 && x>=9 && x<15 )            // bit cell 0 (MSB)
          if( r==8'hff && g==8'hff && b==8'hff ) bits_lit=bits_lit+1;
        if( y>=27 && y<33 && x>=73 && x<79 ) begin     // cell 8: mapped flag
          if( g==8'hff && r==8'h00 ) flag_green=flag_green+1;
          if( r==8'hff && g==8'h00 ) flag_red=flag_red+1;
        end
      end
      LHBL=0; @(posedge clk); @(posedge clk);
    end
    LVBL=0; repeat(4) @(posedge clk);
  end
endtask
task chk(input [255:0] what, input integer got, input integer want_min);
  $display("  %-0s%0d %s", what, got, (got>=want_min)?"ok":"** FAIL **");
endtask
initial begin
  repeat(4) @(posedge clk);
  frame(1'b1, 4'd2, hits_green, hits_red, outside);
  $display("  playing=1      : box green=%0d red=%0d | bg %0d/%0d intact",
           hits_green, hits_red, outside, bg_seen);
  if( bg_seen==0 ) $display("  ** background probe sampled NOTHING -- vacuous **");
  if( hits_green==0 || hits_red!=0 ) $display("  ** FAIL: box should be green **");
  frame(1'b0, 4'd4, hits_green, hits_red, outside);
  $display("  status=4 (ptr) : box green=%0d red=%0d | bg %0d/%0d intact",
           hits_green, hits_red, outside, bg_seen);
  if( hits_red==0 || hits_green!=0 ) $display("  ** FAIL: box should be red **");
  last_cmd=8'h80; last_mapped=1'b1;              // MSB set -> cell 0 lit, flag green
  frame(1'b0, 4'd2, hits_green, hits_red, outside);
  $display("  cmd=0x80 mapped: cell0 lit=%0d  flag green=%0d red=%0d",
           bits_lit, flag_green, flag_red);
  if( bits_lit==0 || flag_green==0 || flag_red!=0 ) $display("  ** FAIL **");
  last_cmd=8'h7f; last_mapped=1'b0;              // MSB clear -> cell 0 dark, flag red
  frame(1'b0, 4'd2, hits_green, hits_red, outside);
  $display("  cmd=0x7f unmapd: cell0 lit=%0d  flag green=%0d red=%0d",
           bits_lit, flag_green, flag_red);
  if( bits_lit!=0 || flag_red==0 || flag_green!=0 ) $display("  ** FAIL **");
  $finish;
end
endmodule
