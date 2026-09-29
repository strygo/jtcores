`timescale 1ns/1ps
// One 64 MiB SDR SDRAM chip at command level, for Verilator. AS4C32M16SB class
// (4 banks x 8M words x 16; row A0-A12, column A0-A9, A10 = auto/all-bank
// precharge; 8192 refresh cycles per 64 ms), the part on the MiSTer 64 MiB
// module and, twice, on the 128 MiB module (SDRAM XS-DS: every pin shared,
// the header's nCS straight into U1 and through an inverter into U2). The data
// bus is split as jtframe's Verilator build splits it: the controller's write
// data arrives on din, the chip's read data leaves on dout with a per-byte
// drive enable, and the testbench resolves the shared bus and reports
// contention. Timing is checked in ns against the -6 grade datasheet
// (tRCD/tRP 18, tRAS 42..120000, tRC 60, tRRD 12, tWR 12, tMRD 12) with the
// 66 ns tRFC of the Micron model jtframe's own controller tests use. Unwritten
// words read back sdram_pattern(chip, bank, row, column), so a wrong address
// split shows up as wrong data even where nothing was written. The JEDEC
// power-up order (precharge all, at least two refreshes, load mode) must be
// complete before the first activate.
package sdram_model_pkg;
    function automatic [15:0] sdram_pattern(input integer chip, input [1:0] bank, input [12:0] row, input [9:0] col);
        sdram_pattern = (16'(row)*16'd769 + 16'(col)*16'd37 + 16'(bank)*16'd7777 + 16'(chip)*16'd21845) ^ 16'h5a5a;
    endfunction
endpackage

module sdram_chip_model #(parameter ID=0)(
    input             clk,
    input             cs_n, ras_n, cas_n, we_n,
    input      [1:0]  ba,
    input      [12:0] a,
    input      [1:0]  dqm,
    input      [15:0] din,        // what the controller drives on DQ
    output reg [15:0] dout,       // what this chip drives on DQ
    output reg [1:0]  dout_en,    // per byte
    output integer    refreshes, activates, reads, writes, commands, pre_alls,
    output reg        init_done
);
import sdram_model_pkg::*;
localparam real tRCD=18.0, tRP=18.0, tRAS=42.0, tRASMAX=120000.0, tRC=60.0, tRFC=66.0, tRRD=12.0, tWR=12.0, tMRD=12.0;
localparam PD=16; // read pipeline depth in clocks

logic [15:0] mem [longint];   // {bank,row,col} -> word; unwritten words read the pattern
reg        active [0:3];
reg [12:0] open_row [0:3];
realtime   t_act [0:3], t_pre [0:3], t_wr [0:3], t_ap [0:3];
reg        ap_pend [0:3];
realtime   t_ref, t_lmr, t_anyact;
integer    cl=0, bl=0;            // 0: mode register not loaded (or loaded with a value this model does not support)
reg        wr_single=0, lmr_seen=0;
reg [15:0] pipe_data [0:PD-1];
reg        pipe_val  [0:PD-1];
integer    tick=0, wr_left=0, wr_beat=0, b, i, slot;
reg [1:0]  dqm_d1=0, wr_bank;
reg [12:0] wr_row;
reg [9:0]  wr_col;
reg [2:0]  cmd;
realtime   tck=0, t_last=0;
reg        trace=0;
initial trace = $test$plusargs("SDRAM_TRACE");

task fail(input string msg);
begin
    $display("ERROR: sdram chip %0d at %t: %s (bank %0d a=%h)", ID, $realtime, msg, ba, a);
    $fatal(1);
end
endtask

function longint key(input [1:0] bk, input [12:0] r, input [9:0] c);
    key = {39'd0, bk, r, c};
endfunction

function [15:0] rd_word(input [1:0] bk, input [12:0] r, input [9:0] c);
    longint k;
begin
    k = key(bk,r,c);
    rd_word = mem.exists(k) ? mem[k] : sdram_pattern(ID,bk,r,c);
end
endfunction

task wr_word(input [1:0] bk, input [12:0] r, input [9:0] c, input [15:0] d, input [1:0] m);
    reg [15:0] cur;
begin
    cur = rd_word(bk,r,c);
    if(!m[1]) cur[15:8]=d[15:8];
    if(!m[0]) cur[7:0]=d[7:0];
    mem[key(bk,r,c)] = cur;
end
endtask

function [9:0] burst_col(input [9:0] c, input integer n);
    reg [9:0] inc;
begin
    inc = c + 10'(n);
    case(bl)
        1: burst_col = c;
        2: burst_col = {c[9:1], inc[0]};
        4: burst_col = {c[9:2], inc[1:0]};
        default: burst_col = {c[9:3], inc[2:0]};
    endcase
end
endfunction

function all_idle;
begin
    all_idle = !(active[0] || active[1] || active[2] || active[3]);
end
endfunction

initial begin
    refreshes=0; activates=0; reads=0; writes=0; commands=0; pre_alls=0; init_done=0;
    dout=0; dout_en=0; t_ref=-1000; t_lmr=-1000; t_anyact=-1000;
    for(b=0;b<4;b=b+1) begin active[b]=0; open_row[b]=0; t_act[b]=-1000; t_pre[b]=-1000; t_wr[b]=-1000; t_ap[b]=0; ap_pend[b]=0; end
    for(i=0;i<PD;i=i+1) begin pipe_val[i]=0; pipe_data[i]=0; end
end

always @(posedge clk) begin
    if(t_last!=0) tck = $realtime - t_last;
    t_last = $realtime;
    // auto-precharge completion and tRAS max
    for(b=0;b<4;b=b+1) begin
        if(ap_pend[b] && $realtime >= t_ap[b]) begin ap_pend[b]=0; active[b]=0; t_pre[b]=t_ap[b]; end
        if(active[b] && ($realtime - t_act[b]) > tRASMAX) fail($sformatf("tRAS max: bank %0d row open for more than 120 us", b));
    end
    // read beat scheduled for this clock (masked by the DQM registered one clock earlier: 2-clock read DQM latency)
    slot = tick % PD;
    if(pipe_val[slot]) begin
        dout    <= pipe_data[slot];
        dout_en <= ~dqm_d1;
        pipe_val[slot] = 0;
        if(trace) $display("  chip %0d t=%0t tick %0d drives %h (dqm_d1=%b)", ID, $realtime, tick, pipe_data[slot], dqm_d1);
    end else dout_en <= 2'b00;
    dqm_d1 <= dqm;
    // continuation of a multi-beat write
    if(wr_left>0) begin
        wr_word(wr_bank, wr_row, burst_col(wr_col, wr_beat), din, dqm);
        t_wr[wr_bank] = $realtime;
        wr_beat = wr_beat+1; wr_left = wr_left-1;
    end
    if(!cs_n) begin
        cmd = {ras_n, cas_n, we_n};
        if(cmd!=3'b111) commands = commands+1;
        if(trace && cmd!=3'b111) $display("chip %0d t=%0t tick %0d cmd %s ba=%0d a=%h dqm=%b din=%h", ID, $realtime, tick,
            cmd==0 ? "LMR" : cmd==1 ? "REF" : cmd==2 ? "PRE" : cmd==3 ? "ACT" : cmd==4 ? "WR " : cmd==5 ? "RD " : "BST", ba, a, dqm, din);
        case(cmd)
        3'b000: begin // LOAD MODE
            if(!all_idle()) fail("LOAD MODE with an active bank");
            if($realtime - t_ref < tRFC) fail("tRFC before LOAD MODE");
            for(b=0;b<4;b=b+1) if($realtime - t_pre[b] < tRP) fail("tRP before LOAD MODE");
            // A mode this model does not support (interleaved, full page, CL other
            // than 2/3, including the all-zero word an FPGA's cleared command
            // register shows for one clock after configuration) leaves the
            // mode undefined: only a later read or write with it fails.
            case(a[6:4]) 3'd2: cl=2; 3'd3: cl=3; default: cl=0; endcase
            case(a[2:0]) 3'd0: bl=1; 3'd1: bl=2; 3'd2: bl=4; 3'd3: bl=8; default: bl=0; endcase
            if(a[3]) bl=0;
            wr_single = a[9];
            lmr_seen = cl!=0 && bl!=0; t_lmr = $realtime;
        end
        3'b001: begin // AUTO REFRESH
            if(!all_idle()) fail("AUTO REFRESH with an active bank (this chip was not precharged)");
            if($realtime - t_ref < tRFC) fail("tRFC between refreshes");
            if($realtime - t_lmr < tMRD) fail("tMRD before refresh");
            for(b=0;b<4;b=b+1) if($realtime - t_pre[b] < tRP) fail("tRP before refresh");
            refreshes = refreshes+1; t_ref = $realtime;
        end
        3'b010: begin // PRECHARGE
            if($realtime - t_ref < tRFC) fail("tRFC before precharge");
            if(a[10]) pre_alls = pre_alls+1;
            for(b=0;b<4;b=b+1) if(a[10] || ba==b[1:0]) begin
                if(active[b] || ap_pend[b]) begin
                    if($realtime - t_act[b] < tRAS) fail($sformatf("tRAS min: bank %0d precharged too early", b));
                    if($realtime - t_wr[b] < tWR) fail($sformatf("tWR: bank %0d precharged too early after a write", b));
                end
                active[b]=0; ap_pend[b]=0; t_pre[b]=$realtime;
                if(wr_left>0 && wr_bank==b[1:0]) wr_left=0;
            end
        end
        3'b011: begin // ACTIVATE
            if(!init_done) fail("ACTIVATE before precharge-all, two refreshes and load mode");
            if(active[ba] || ap_pend[ba]) fail("ACTIVATE on a bank that is already active: data can be corrupted");
            if($realtime - t_pre[ba] < tRP) fail("tRP before activate");
            if($realtime - t_act[ba] < tRC) fail("tRC between activates of the same bank");
            if($realtime - t_anyact < tRRD) fail("tRRD between activates");
            if($realtime - t_ref < tRFC) fail("tRFC before activate");
            if($realtime - t_lmr < tMRD) fail("tMRD before activate");
            active[ba]=1; open_row[ba]=a; t_act[ba]=$realtime; t_anyact=$realtime;
            activates = activates+1;
        end
        3'b100: begin // WRITE
            if(!active[ba] || ap_pend[ba]) fail("WRITE to a bank that is not active");
            if(cl==0 || bl==0) fail("WRITE with an undefined mode register");
            if($realtime - t_act[ba] < tRCD) fail("tRCD before write");
            for(i=0;i<PD;i=i+1) if(pipe_val[i]) fail("WRITE while this chip still has read data to drive");
            wr_word(ba, open_row[ba], a[9:0], din, dqm);
            t_wr[ba] = $realtime; writes = writes+1;
            if(!wr_single && bl>1) begin wr_left=bl-1; wr_beat=1; wr_bank=ba; wr_row=open_row[ba]; wr_col=a[9:0]; end
            if(a[10]) begin // auto precharge after tWR, never before tRAS
                ap_pend[ba]=1;
                t_ap[ba] = ($realtime + tWR + tck) > (t_act[ba] + tRAS) ? ($realtime + tWR + tck) : (t_act[ba] + tRAS);
            end
        end
        3'b101: begin // READ
            if(!active[ba] || ap_pend[ba]) fail("READ from a bank that is not active");
            if(cl==0 || bl==0) fail("READ with an undefined mode register");
            if($realtime - t_act[ba] < tRCD) fail("tRCD before read");
            for(i=0;i<PD;i=i+1) pipe_val[i]=0; // a new read interrupts any burst in flight
            for(i=0;i<bl;i=i+1) begin
                pipe_data[(tick+cl-1+i)%PD] = rd_word(ba, open_row[ba], burst_col(a[9:0], i));
                pipe_val [(tick+cl-1+i)%PD] = 1;
            end
            reads = reads+1;
            if(a[10]) begin // auto precharge: a burst length after the command, never before tRAS
                ap_pend[ba]=1;
                t_ap[ba] = ($realtime + bl*tck) > (t_act[ba] + tRAS) ? ($realtime + bl*tck) : (t_act[ba] + tRAS);
            end
        end
        3'b110: begin // BURST TERMINATE
            for(i=0;i<PD;i=i+1) pipe_val[i]=0;
            wr_left=0;
        end
        default: ; // NOP
        endcase
        if(!init_done && pre_alls>0 && refreshes>=2 && lmr_seen) init_done = 1;
    end
    tick = tick+1;
end
endmodule
