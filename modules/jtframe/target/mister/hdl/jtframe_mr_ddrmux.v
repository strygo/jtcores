/*  This file is part of JTFRAME.
    JTFRAME program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTFRAME program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTFRAME.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 28-2-2021 */

module jtframe_mr_ddrmux(
    input          rst,
    input          clk,
    input          ioctl_rom,
`ifdef CPSPLUS
    // CPS+ arranged-audio client (read-only, lowest priority)
    input   [ 7:0] cpsp_burstcnt,
    input   [28:0] cpsp_addr,
    input          cpsp_rd,
    output         cpsp_busy,
    output         cpsp_sel,
`ifdef CPS2_UNIFIED
    output         cpsp_idle,
`endif
    input          ddr_dout_ready,  // for burst-boundary grant switching
`endif
    // Fast DDR load
    input   [ 7:0] ddrld_burstcnt,
    input   [28:0] ddrld_addr,
    input          ddrld_rd,
    output         ddrld_busy,
    // Video DDR client: rotation or line-frame buffer
    input          rot_clk,
    input   [ 7:0] rot_burstcnt,
    input   [28:0] rot_addr,
    input          rot_rd,
    input          rot_we,
    input   [ 7:0] rot_be,
    input   [63:0] rot_din,
    output         rot_busy,
    // DDR Signals
    output         ddr_clk,
    input          ddr_busy,
    output  [ 7:0] ddr_burstcnt,
    output  [28:0] ddr_addr,
    output         ddr_rd,
    output  [ 7:0] ddr_be,
    output         ddr_we,
    output  [63:0] ddr_din
);

`ifdef JTFRAME_MR_DDRLOAD
    localparam DDRLOAD=1;
`else
    localparam DDRLOAD=0;
`endif

`ifdef JTFRAME_VERTICAL
    localparam VERTICAL=1;
`else
    localparam VERTICAL=0;
`endif

`ifdef JTFRAME_LF_BUFFER
    localparam LFBUF=1;
`else
    localparam LFBUF=0;
`endif

reg ddrld_en;
`ifdef CPS2_UNIFIED
reg [8:0] beats;
`endif

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ddrld_en <= 0;
    end else if(!ddr_busy
`ifdef CPS2_UNIFIED
        && beats==0 && !ddr_rd && !ddr_we
`endif
    ) begin
        case( {DDRLOAD[0], VERTICAL[0] || LFBUF[0]} )
            2'b00: ddrld_en <= 0; // don't care
            2'b10: ddrld_en <= 1;
            2'b01: ddrld_en <= 0;
            2'b11: ddrld_en <= ioctl_rom;
        endcase
    end
end

`ifdef CPSPLUS
// CPS+ third client: granted when the ROM fast-load is done and the video
// client is quiescent.  Grants switch only on burst boundaries (read beats
// tracked below; rot write bursts hold ddr_we for their whole duration).
// A vertical game actively rotating keeps the bus — video has priority and
// CPS+ packs target horizontal games (see cpsplus INTEGRATION.md).
reg        cpsp_en;
`ifndef CPS2_UNIFIED
reg [ 8:0] beats;                    // outstanding beats of a granted read
`endif
wire       rot_req = rot_rd | rot_we;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cpsp_en <= 0;
        beats   <= 0;
    end else begin
        if( ddr_rd && !ddr_busy )
            beats <= {1'b0, ddr_burstcnt};          // read burst accepted
        else if( ddr_dout_ready && beats != 0 )
            beats <= beats - 1'd1;
        if( beats == 0 && !ddr_rd && !ddr_we && !ddr_busy )
            cpsp_en <= !ioctl_rom && !ddrld_en && !rot_req && cpsp_rd;
    end
end

`ifdef CPS2_UNIFIED
assign cpsp_idle = !cpsp_rd && !(cpsp_en && beats!=0);
`endif
assign cpsp_sel  = cpsp_en;
assign cpsp_busy = ~cpsp_en | ddr_busy;

assign ddr_clk = (ddrld_en | cpsp_en) ? clk : rot_clk;

assign ddr_burstcnt = ddrld_en ? ddrld_burstcnt :
                      cpsp_en  ? cpsp_burstcnt  : rot_burstcnt;
assign ddr_addr     = ddrld_en ? ddrld_addr     :
                      cpsp_en  ? cpsp_addr      : rot_addr;
assign ddr_rd       = ddrld_en ? ddrld_rd       :
                      cpsp_en  ? cpsp_rd        : rot_rd;
assign ddr_be       = (ddrld_en | cpsp_en) ? 8'hff  : rot_be;
assign ddr_we       = (ddrld_en | cpsp_en) ? 1'b0   : rot_we;
assign ddr_din      = (ddrld_en | cpsp_en) ? 64'd0  : rot_din;

assign ddrld_busy   = ~ddrld_en | ddr_busy;
assign rot_busy     =  ddrld_en | cpsp_en | ddr_busy;
`else
assign ddr_clk = ddrld_en ? clk : rot_clk;

// This simple mux allows for bad data transfers when switching from ROM download
// to the frame buffer, but it shouldn't be a problem

assign ddr_burstcnt = ddrld_en ? ddrld_burstcnt : rot_burstcnt;
assign ddr_addr     = ddrld_en ? ddrld_addr     : rot_addr;
assign ddr_rd       = ddrld_en ? ddrld_rd       : rot_rd;
assign ddr_be       = ddrld_en ? 8'hff          : rot_be;
assign ddr_we       = ddrld_en ? 1'b0           : rot_we;
assign ddr_din      = ddrld_en ? 64'd0          : rot_din;

assign ddrld_busy   = ~ddrld_en | ddr_busy;
assign rot_busy     =  ddrld_en | ddr_busy;
`endif

endmodule