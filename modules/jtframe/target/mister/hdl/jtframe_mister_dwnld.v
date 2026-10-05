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

/*

DDRAM Signals

{signal: [
  {name: 'DDRAM_CLK',wave:'p.......|...'},
  {name: 'DDRAM_RD',wave:'0.1|.0...|..'},
  {name: 'DDRAM_BE',wave:'=.=.........',data:["00","FF"]},
  {name: 'DDRAM_ADDR',wave:'xx=.........',data:["address"]},
  {name: 'DDRAM_DOUT_READY',wave:'0.....1..|.0'},
  {name: 'DDRAM_DOUT',wave:'xxxxxx=x|==x',data:["data0","data1","n-1","n"]},
  {name: 'DDRAM_BUSY', wave: 'x01|0....|..'},
  {},
]}

*/

module jtframe_mister_dwnld(
    input             rst,
    input             clk,

    input             dwnld_busy,

    input             prog_we,
    input             prog_rdy,

    input             hps_download, // signal indicating an active download
    input             hps_upload,   // signal indicating an active upload
    input      [ 7:0] hps_index,    // menu index used to upload the file
    input             hps_wr,
    `ifdef CPS2_NATIVE128
    input             hps_overflow,
`endif
    input      [26:0] hps_addr,     // in WIDE mode address will be incremented by 2
    input      [ 7:0] hps_dout,
    output            hps_wait,
`ifdef CPS2_UNIFIED
    output            load_busy,
    output            load_native,
    output      [3:0] load_error,
`endif

    output reg        ioctl_rom,
    output reg        ioctl_wr,     // any IOCTL write to the core
    output reg        ioctl_ram,
    output reg        ioctl_cart,
    output reg        ioctl_cheat,
    output reg        ioctl_lock,
    output reg [26:0] ioctl_addr,
    output reg [ 7:0] ioctl_dout,

    // Configuration
    output reg [ 6:0] core_mod,
    output reg [ 7:0] game_vol=8'h80,
    input      [31:0] status,
    output     [31:0] dipsw,
    output     [31:0] cheat,

    // DDR3 RAM
    input             ddram_busy,
    output     [ 7:0] ddram_burstcnt,
    output     [28:0] ddram_addr,
    input      [63:0] ddram_dout,
    input             ddram_dout_ready,
    output reg        ddram_rd
);

localparam [5:0] IDX_ROM          = 6'h0,
                 IDX_MOD          = 6'h1,
                 IDX_NVRAM        = 6'h2,
                 IDX_CART         = 6'h4, // console cartridge
                 IDX_CHEAT        = 6'h10,
                 IDX_LOCK         = 6'h11;
localparam [7:0] IDX_DIPSW        = 8'd254,
                 IDX_CHEAT_STATUS = 8'd255;

localparam [26:0] CART_OFFSET = `ifdef JTFRAME_CART_OFFSET `JTFRAME_CART_OFFSET `else 27'd0 `endif ;

wire is_rom, is_cart, is_nvram;

always @(posedge clk) begin
    if( rst ) begin
        core_mod <= 0;
    end else begin
        // The hps_addr[0]==1'b0 condition is needed in case JTFRAME_MR_FASTIO is enabled
        // as it always creates two write events and the second would delete the data of the first
        if (hps_wr && hps_index==IDX_MOD) case (hps_addr[1:0])
            0: core_mod <= hps_dout[6:0];
            1: game_vol <= hps_dout;
        endcase
    end
end


// Dip switches through MRA file
// Support for 32 bits only for now.
reg  [ 7:0] dsw[4];

`ifndef SIMULATION
    assign dipsw = {dsw[3],dsw[2],dsw[1],dsw[0]};
`else // SIMULATION:
    `ifndef JTFRAME_SIM_DIPS
        assign dipsw = ~32'd0;
    `else
        assign dipsw = `JTFRAME_SIM_DIPS;
    `endif
`endif

always @(posedge clk) begin
    if (hps_wr && (hps_index==IDX_DIPSW) && !hps_addr[24:2])
        dsw[hps_addr[1:0]] <= hps_dout;
end

// Cheat
reg [ 7:0] cheat_flags[4];
assign cheat = { cheat_flags[3], cheat_flags[2], cheat_flags[1], cheat_flags[0] };
always @(posedge clk) begin
    if( rst ) begin
        cheat_flags[3] <= 0;
        cheat_flags[2] <= 0;
        cheat_flags[1] <= 0;
        cheat_flags[0] <= 0;
    end else begin
        if (hps_wr && (hps_index==IDX_CHEAT_STATUS) && !hps_addr[24:2])
            cheat_flags[hps_addr[1:0]] <= hps_dout;
    end
end


// DDR ROM download
localparam BW=7;
reg  [BW-1:0] ddram_cnt;
reg  [  26:0] dump_cnt;
wire [  63:0] dump_data;
reg  [  63:0] dump_ser;
reg           tx_start, tx_done;
reg           game_rom, game_cart;
wire          buffer_we;

jtframe_rpwp_ram #(.DW(64),.AW(BW)) u_buffer(
    .clk    ( clk        ),
    // Port 0: write
    .din    ( ddram_dout ),
    .wr_addr( ddram_cnt  ),
    .we     ( buffer_we  ),
    // Port 1: read
    .rd_addr( dump_cnt[BW+2:3]  ),
    .dout   ( dump_data  )
);

reg        ddr_dwn, last_dwn, last_dwnbusy, wr_latch;
reg        dump_we;
reg [26:0] ddr_len;

`ifdef CPSPLUS
// CPS+ pack appended to the ROM image: image bytes 8-9 (a reserved slot in
// the CPS header start-pointer area, little-endian, 1 kB units) point at
// the pack; 0x0000/0xFFFF (header fill) = no pack.  The DDR->core readback
// must stop at the pack: the trailing pack bytes are not ROM data (they
// would stream into the last download region), and images larger than
// 128 MB wrap hps_addr so ddr_len cannot be trusted.  The pack itself
// stays in DDR at 0x30000000 for the in-core cpsplus_ddr loader.
reg  [15:0] pack_ptr, pad_len;
// bytes 10-11 hold the pad (ROM end -> pack, <1 kB).  Those pad bytes must NOT
// reach the core: everything at/after qsnd_start goes to the QSound DSP ROM at
// a 13-bit (8 kB) WRAPPING address with no upper bound (jtcps1_prom_we.v
// is_qsnd/prog_addr), so trailing bytes overwrite the START of the DSP
// firmware -> dead DSP (measured: jtcps15 black screen 2026-07-27).  Stop at
// the true ROM end.  0xffff (unpatched image) means pad 0.
wire [ 9:0] pad_eff  = pad_len >= 16'd1024 ? 10'd0 : pad_len[9:0];
wire [26:0] dump_end = (pack_ptr != 16'h0000 && pack_ptr != 16'hffff)
                     ? {1'b0, pack_ptr, 10'd0} - {17'd0, pad_eff} : ddr_len;
`endif

`ifdef CPS2_NATIVE128
`include "jtframe_cps2_native.vh"
reg native_mode=0, native_bad=0, native_error=0, native_preflight=0;
reg native_extent_bad=0;
wire new_rom_download = hps_download && !last_dwn && is_rom;
reg [3:0] image_error=0; // 1 header, 2 extent/overflow; retained until reload
`ifdef CPS2_QSND32
reg native_sample32=0;
reg [63:0] native_mirror=0;
wire native_early_wide = ddram_cnt==1 ? ddram_dout[55:48]==3 : native_sample32;
wire [26:0] native_end = native_sample32 ? NATIVE32_END : NATIVE_END;
wire native_mirror_ok = native_mirror == (native_sample32 ? 64'ha100a10821002000 : 64'h6100610821002000);
always @(posedge clk, posedge rst) begin
    if(rst) begin native_sample32<=0; native_mirror<=0; end
    else if(new_rom_download) begin native_sample32<=0; native_mirror<=0; end
    else if(ddr_dwn && ddram_wait && !ddram_busy && ddram_dout_ready && ddram_page==0) begin
        if(ddram_cnt==0) native_mirror<=ddram_dout;
        if(ddram_cnt==1) native_sample32<=ddram_dout[55:48]==3;
    end
end
`endif
integer header_lane;
reg header_word_bad;
always @(*) begin
    header_word_bad=0;
    for(header_lane=0;header_lane<8;header_lane=header_lane+1)
        if(native_fixed({ddram_cnt[3:0],3'b000}+header_lane[6:0]) &&
`ifdef CPS2_QSND32
           (ddram_cnt==0 ?
            (ddram_dout[header_lane*8+:8] != native_expected_profile({ddram_cnt[3:0],3'b000}+header_lane[6:0],0) &&
             ddram_dout[header_lane*8+:8] != native_expected_profile({ddram_cnt[3:0],3'b000}+header_lane[6:0],1)) :
             ddram_dout[header_lane*8+:8] != native_expected_profile({ddram_cnt[3:0],3'b000}+header_lane[6:0],native_early_wide)))
`else
           ddram_dout[header_lane*8+:8] != native_expected({ddram_cnt[3:0],3'b000}+header_lane[6:0]))
`endif
            header_word_bad=1;
end
always @(posedge clk, posedge rst) begin
    if(rst) begin
        native_mode<=0;
        native_bad<=0;
        native_error<=0;
        native_preflight<=0;
        native_extent_bad<=0;
        image_error<=0;
    end else if(new_rom_download) begin
        native_mode<=0;
        native_bad<=0;
        native_error<=0;
        native_preflight<=0;
        native_extent_bad<=0;
        image_error<=0;
    end else begin
        if(!hps_download && last_dwn && ioctl_rom && !wr_latch) begin
            native_preflight<=1;
            `ifdef CPS2_QSND32
            native_extent_bad<=hps_overflow;
`else
            native_extent_bad<=hps_overflow || hps_addr!=NATIVE_END;
`endif
        end
        if(ddr_dwn && ddram_wait && !ddram_busy && ddram_dout_ready && ddram_page==0) begin
            if(ddram_cnt<16 && header_word_bad) native_bad<=1;
            // Either identity recognizes this profile; corrupting one cannot
            // downgrade it into a legacy payload. Legacy versions 1/7f stay exact.
            if(ddram_cnt==1 && ddram_dout[47:32]==16'h3243 &&
               ddram_dout[55:48]!=1 && ddram_dout[55:48]!=8'h7f) native_mode<=1;
            if(ddram_cnt==8 && ddram_dout[31:0]==32'h58453243) native_mode<=1;
            if(cnt_over) begin
                native_preflight<=0;
`ifdef CPS2_QSND32
                native_error<=native_mode && (native_bad || !native_mirror_ok || native_extent_bad || hps_addr!=native_end);
                if(native_mode && (native_bad || !native_mirror_ok || native_extent_bad || hps_addr!=native_end))
                    image_error<=(native_bad || !native_mirror_ok) ? 4'd1 : 4'd2;
`else
                native_error<=native_mode && (native_bad || native_extent_bad);
                if(native_mode && (native_bad || native_extent_bad))
                    image_error<=native_bad ? 4'd1 : 4'd2;
`endif
            end
        end
    end
end
`endif
assign hps_wait = ddr_dwn;
`ifdef CPS2_UNIFIED
assign load_busy = ddr_dwn;
assign load_native = native_mode;
assign load_error = image_error;
`endif
assign is_rom   = hps_index[5:0]==IDX_ROM;
assign is_cart  = hps_index[5:0]==IDX_CART;
assign is_nvram = hps_index[5:0]==IDX_NVRAM;

// download signals mux — registered to break long combinational path
// from ddr_dwn through jtframe_dwnld (Add0 → LessThan3 → Selector9 → Add1 → prog_addr)
always @(posedge clk) begin
    `ifdef CPS2_NATIVE128
    ioctl_wr   <= ddr_dwn ? (dump_we && !native_preflight && !native_error) :
`else
    ioctl_wr   <= ddr_dwn ? dump_we :
`endif
                             hps_wr && (game_rom || is_nvram);
    ioctl_dout <= ddr_dwn ? dump_ser[7:0] : hps_dout;
    ioctl_addr <= ddr_dwn ? dump_cnt :
                 game_cart ? hps_addr + CART_OFFSET : hps_addr;
end

// Detect DDR download start and stop conditions
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        wr_latch    <= 0;
        last_dwn    <= 0;
        ddr_dwn     <= 0;
        ioctl_rom   <= 0;
        ddr_len     <= 27'd0;
        game_rom    <= 0;
        game_cart   <= 0;
        ioctl_ram   <= 0;
        ioctl_cheat <= 0;
        ioctl_lock  <= 0;
        ioctl_cart  <= 0;
    end else begin
        last_dwn     <=  hps_download;
        ioctl_cheat  <=  hps_download && hps_index[5:0]==IDX_CHEAT;
        ioctl_lock   <=  hps_download && hps_index[5:0]==IDX_LOCK;
        ioctl_cart   <=  hps_download && is_cart;
        ioctl_ram    <= (hps_download && is_nvram) || hps_upload;
        last_dwnbusy <= dwnld_busy;
        game_rom     <= is_rom || is_cart;
        game_cart    <= is_cart;
        if( hps_download && (is_rom  || is_cart) && !last_dwn && game_rom) begin
            ioctl_rom <= is_rom;
            wr_latch  <= 0;
        end else begin
            if( hps_wr && game_rom ) wr_latch <= 1;
        end
        if( !hps_download && last_dwn && ioctl_rom ) begin
            if( wr_latch )
                ioctl_rom <= 0;   // regular download
            else begin
                ddr_len  <= hps_addr; // the ROM length is notified here
                ddr_dwn  <= 1;
            end
        end
`ifdef CPS2_NATIVE128
        if(!native_preflight && !native_error &&
           ((!hps_download && last_dwnbusy && !dwnld_busy) ||
`ifdef CPS2_QSND32
            (ddr_dwn && dump_cnt >= (native_mode ? native_end :
`else
            (ddr_dwn && dump_cnt >= (native_mode ? NATIVE_END :
`endif
`ifdef CPSPLUS
                                     dump_end
`else
                                     ddr_len
`endif
             )))) begin
`elsif CPSPLUS
        if( !hps_download && last_dwnbusy && !dwnld_busy || (ddr_dwn && dump_cnt >= dump_end)) begin
`else
        if( !hps_download && last_dwnbusy && !dwnld_busy || (ddr_dwn && dump_cnt >= ddr_len)) begin
`endif
            ioctl_rom  <= 0;
            ddr_dwn    <= 0;
        end
`ifdef CPS2_NATIVE128
        if(native_error && !hps_download) begin
            ioctl_rom<=1; // keep the game in reset; do not hold the HPS interface
            ddr_dwn<=0;
        end
`endif
    end
end

////////// Read DDR
// address="0x3000'0000"

localparam PW = 29-4-BW;

reg [PW-1:0] ddram_page;

assign ddram_burstcnt = 8'h1 << BW; // 128*8=1024
assign ddram_addr = { 4'd3, ddram_page, {BW{1'b0}} };
assign buffer_we  = ddram_wait;

wire cnt_over = &ddram_cnt;
reg ddram_wait;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        ddram_cnt  <= 0;
        ddram_page <= 0;
        ddram_wait <= 0;
        tx_start   <= 0;
`ifdef CPSPLUS
        pack_ptr   <= 16'hffff;
        pad_len    <= 16'hffff;
`endif
`ifdef CPS2_NATIVE128
    end else if(new_rom_download) begin
        // Rearm synchronously. Only rst belongs to the asynchronous reset
        // edge in this process (required by FPGA synthesis).
        ddram_cnt  <= 0;
        ddram_page <= 0;
        ddram_wait <= 0;
        ddram_rd   <= 0;
        tx_start   <= 0;
`ifdef CPSPLUS
        pack_ptr   <= 16'hffff;
        pad_len    <= 16'hffff;
`endif
`endif
    end else if(!ddram_busy ) begin
        if( ddr_dwn  ) begin
            if( !ddram_wait ) begin
                ddram_cnt  <= 0;
                tx_start   <= 0;
                if( tx_done && !tx_start ) begin
                    ddram_rd   <= 1;
                    ddram_wait <= 1;
                end
            end else begin
                ddram_rd <= 0;
                if( ddram_dout_ready ) begin
`ifdef CPSPLUS
                    // image bytes 8-15 = second 64-bit word of page 0
                    if( ddram_page == 0 && ddram_cnt == 7'd1 ) begin
                        pack_ptr <= ddram_dout[15:0];   // bytes  8-9  : pack ptr
                        pad_len  <= ddram_dout[31:16];  // bytes 10-11 : pad len
                    end
`endif
                    ddram_cnt <= ddram_cnt + 1'b1;
                    if( cnt_over ) begin
                        ddram_wait <= 0;
                        tx_start   <= 1;
                        ddram_page <= ddram_page + 1'd1;
                    end
                end
            end
        end else begin
            ddram_rd   <= 0;
            tx_start   <= 0;
            ddram_wait <= 0;
`ifdef CPSPLUS
            pack_ptr   <= 16'hffff;   // re-armed while no DDR dump is active
            pad_len    <= 16'hffff;
`endif
        end
    end
end

reg [ 1:0] st;
reg        next_wr;
reg [ 5:0] timeout;

// Send to core
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        tx_done  <= 1;
        dump_cnt <= 27'd0;
        dump_we  <= 0;
        dump_ser <= 64'd0;
        st       <= 2'd0;
        timeout  <= 5'd0;
`ifdef CPS2_NATIVE128
    end else if(new_rom_download) begin
        tx_done  <= 1;
        dump_cnt <= 27'd0;
        dump_we  <= 0;
        dump_ser <= 64'd0;
        st       <= 2'd0;
        timeout  <= 5'd0;
`endif
    end else begin
        if( tx_start ) begin
            tx_done <= 0;
            st      <= 2'd0;
            timeout <= 5'd0;
        end else
        if( !tx_done ) begin
            if( st==1 && dump_cnt[2:0]==3'd0 ) begin
                dump_ser <= dump_data;
            end
            `ifdef CPS2_NATIVE128
            dump_we <= st==2'd2 && !native_error &&
`ifdef CPS2_QSND32
                       (!native_mode || dump_cnt<native_end);
`else
                       (!native_mode || dump_cnt<NATIVE_END);
`endif
`else
            dump_we <= st==2'd2;
`endif
            timeout <= st==2'd2 ? 5'd0 : (timeout+1'd1);
            case( st )
                default: st <= st+1'd1;
                `ifdef CPS2_NATIVE128
                // Allow the registered IOCTL/native-write pipeline to settle.
                // Enhanced payloads never advance on the legacy timeout escape.
                3: if(native_mode ? (timeout>=7 && (!prog_we || prog_rdy)) :
                                    (prog_rdy || (&timeout))) begin
`else
                3: if( prog_rdy || (&timeout) ) begin
`endif
                    dump_ser <= dump_ser>>8;
                    dump_cnt <= dump_cnt+1'd1;
                    st <= &dump_cnt[2:0] ? 2'd0 : 2'd1;
                    if( &dump_cnt[BW+2:0] ) tx_done<=1;
                end
            endcase
        end
    end
end

endmodule