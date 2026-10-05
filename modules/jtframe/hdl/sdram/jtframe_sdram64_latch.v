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
    Date: 29-4-2021 */
/* verilator coverage_off */
module jtframe_sdram64_latch #(parameter LATCH=0, AW=22)(
    input               rst,
    input               clk,
    input      [AW-1:0] ba0_addr,
    input      [AW-1:0] ba1_addr,
    input      [AW-1:0] ba2_addr,
    input      [AW-1:0] ba3_addr,
    output reg [AW-1:0] ba0_addr_l,
    output reg [AW-1:0] ba1_addr_l,
    output reg [AW-1:0] ba2_addr_l,
    output reg [AW-1:0] ba3_addr_l,
`ifdef JTFRAME_SDRAM_XL
    input      [(AW==24?14:13)-1:0] ba0_row, // AW==24: {chip, row}
    input      [(AW==24?14:13)-1:0] ba1_row,
    input      [(AW==24?14:13)-1:0] ba2_row,
    input      [(AW==24?14:13)-1:0] ba3_row,
`else
    input      [  12:0] ba0_row,
    input      [  12:0] ba1_row,
    input      [  12:0] ba2_row,
    input      [  12:0] ba3_row,
`endif
    input         [3:0] rd,
    input         [3:0] wr,
    input         [3:0] rdy,
    input               prog_en,
    input               prog_rd,
    input               prog_wr,
    output reg    [3:0] rd_l,
    output reg    [3:0] wr_l,
    output reg    [3:0] match,
    output reg          noreq
);

`ifdef JTFRAME_SDRAM_XL
localparam XL   = AW==24,
           RMSB = AW==22 ? AW-1 : (XL ? AW-3 : AW-2),
           RLSB = RMSB-12,
           RW   = XL ? 14 : 13;

wire prog_rq = prog_en &(prog_wr | prog_rd);

// The open-row key of a request. AW==24 (128 MiB module) adds the chip bit:
// bank N of chip 0 and bank N of chip 1 are different SDRAM banks, so a row
// open in one chip must not count as a hit for the other.
wire [RW-1:0] ba0_key, ba1_key, ba2_key, ba3_key;

generate if( XL ) begin : g_xlkey
    assign ba0_key = { ba0_addr[AW-1], ba0_addr[RMSB:RLSB] };
    assign ba1_key = { ba1_addr[AW-1], ba1_addr[RMSB:RLSB] };
    assign ba2_key = { ba2_addr[AW-1], ba2_addr[RMSB:RLSB] };
    assign ba3_key = { ba3_addr[AW-1], ba3_addr[RMSB:RLSB] };
end else begin : g_key
    assign ba0_key = ba0_addr[RMSB:RLSB];
    assign ba1_key = ba1_addr[RMSB:RLSB];
    assign ba2_key = ba2_addr[RMSB:RLSB];
    assign ba3_key = ba3_addr[RMSB:RLSB];
end endgenerate

generate
    if( LATCH==1 ) begin
        always @(posedge clk) begin
            if( rst ) begin
                ba0_addr_l <= 0;
                ba1_addr_l <= 0;
                ba2_addr_l <= 0;
                ba3_addr_l <= 0;
                wr_l       <= 0;
                rd_l       <= 0;
                noreq      <= 1;
            end else begin
                ba0_addr_l <= ba0_addr;
                ba1_addr_l <= ba1_addr;
                ba2_addr_l <= ba2_addr;
                ba3_addr_l <= ba3_addr;
                match[0]   <= ba0_key===ba0_row;
                match[1]   <= ba1_key===ba1_row;
                match[2]   <= ba2_key===ba2_row;
                match[3]   <= ba3_key===ba3_row;
                wr_l       <= wr & ~rdy;
                rd_l       <= rd;
                noreq      <= ~|{wr,rd,prog_rq};
            end
        end
    end else begin
        always @(*) begin
                ba0_addr_l = ba0_addr;
                ba1_addr_l = ba1_addr;
                ba2_addr_l = ba2_addr;
                ba3_addr_l = ba3_addr;
                match[0]   = ba0_key===ba0_row;
                match[1]   = ba1_key===ba1_row;
                match[2]   = ba2_key===ba2_row;
                match[3]   = ba3_key===ba3_row;
                wr_l       = wr;
                rd_l       = rd;
                noreq      = ~|{wr,rd,prog_rq};
        end
    end
endgenerate
`else
localparam RMSB = AW==22 ? AW-1 : AW-2,
           RLSB = RMSB-12;

wire prog_rq = prog_en &(prog_wr | prog_rd);

generate
    if( LATCH==1 ) begin
        always @(posedge clk) begin
            if( rst ) begin
                ba0_addr_l <= 0;
                ba1_addr_l <= 0;
                ba2_addr_l <= 0;
                ba3_addr_l <= 0;
                wr_l       <= 0;
                rd_l       <= 0;
                noreq      <= 1;
            end else begin
                ba0_addr_l <= ba0_addr;
                ba1_addr_l <= ba1_addr;
                ba2_addr_l <= ba2_addr;
                ba3_addr_l <= ba3_addr;
                match[0]   <= ba0_addr[RMSB:RLSB]===ba0_row;
                match[1]   <= ba1_addr[RMSB:RLSB]===ba1_row;
                match[2]   <= ba2_addr[RMSB:RLSB]===ba2_row;
                match[3]   <= ba3_addr[RMSB:RLSB]===ba3_row;
                wr_l       <= wr & ~rdy;
                rd_l       <= rd;
                noreq      <= ~|{wr,rd,prog_rq};
            end
        end
    end else begin
        always @(*) begin
                ba0_addr_l = ba0_addr;
                ba1_addr_l = ba1_addr;
                ba2_addr_l = ba2_addr;
                ba3_addr_l = ba3_addr;
                match[0]   = ba0_addr[RMSB:RLSB]===ba0_row;
                match[1]   = ba1_addr[RMSB:RLSB]===ba1_row;
                match[2]   = ba2_addr[RMSB:RLSB]===ba2_row;
                match[3]   = ba3_addr[RMSB:RLSB]===ba3_row;
                wr_l       = wr;
                rd_l       = rd;
                noreq      = ~|{wr,rd,prog_rq};
        end
    end
endgenerate
`endif

endmodule
