`timescale 1ns/1ps
module sat_tb;
function signed [15:0] sat( input signed [17:0] v );
    sat = (v >  18'sd32767) ?  16'sd32767 :
          (v < -18'sd32768) ? -16'sd32768 : v[15:0];
endfunction
reg signed [15:0] l; wire signed [17:0] x = {{2{l[15]}}, l};
integer i; reg signed [15:0] r;
initial begin
  l = 16'sd30000; #1 r = sat(x + (x>>>1));
  $display("  +30000 x1.5 -> %0d  (expect 32767, saturated)", r);
  l = -16'sd30000; #1 r = sat(x + (x>>>1));
  $display("  -30000 x1.5 -> %0d  (expect -32768, saturated)", r);
  l = 16'sd10000; #1 r = sat(x + (x>>>2));
  $display("  +10000 x1.25 -> %0d  (expect 12500)", r);
  l = -16'sd8000; #1 r = sat(x + (x>>>1));
  $display("   -8000 x1.5 -> %0d  (expect -12000)", r);
  $finish;
end
endmodule
