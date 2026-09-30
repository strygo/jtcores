/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 30-1-2020 */

module jtcps1_prom_we #(
parameter        CPS=1, // 1, 15, or 2
                 REGSIZE=24, // This is defined at _game level
parameter [22:0] CPU_OFFSET =23'h0,
                 SND_OFFSET =23'h0,
                 PCM_OFFSET =23'h0,
                 GFX_OFFSET =23'h0,
parameter [ 5:0] CFG_BYTE   =6'd39  // location of the byte with encoder information
)(
    input                clk,
    input                ioctl_rom,
`ifdef CPS2_QSND24
    input      [26:0]    ioctl_addr,    // max 128 MB (JTFRAME_SDRAM_XL): the flat QSound image is 64.25 MiB
`else
    input      [25:0]    ioctl_addr,    // max 64 MB
`endif
    input      [ 7:0]    ioctl_dout,
    input                ioctl_wr,
    input                ioctl_ram,
`ifdef CPS2_OBJEXT
    output reg [23:0]    prog_addr, // 128 MiB module: bank 2 holds the object slice above 16 MiB
`else
    output reg [22:0]    prog_addr,
`endif
    output     [15:0]    prog_data,
    output reg [ 1:0]    prog_mask, // active low
    output reg [ 1:0]    prog_ba,
    output reg           prog_we,
    output reg           prom_we,   // for Q-Sound internal ROM
    input                prog_rdy,
    output reg           cfg_we,
    output               dwnld_busy,
    // Kabuki decoder (CPS 1.5)
    output               kabuki_we,
    // CPS2 keys
    output reg           cps2_key_we,
    output reg [ 1:0]    joymode
`ifdef CPS2_PRG8
    ,output reg         cps2_prog_ext = 1'b0
`endif
`ifdef CPS2_OBJEXT
    ,output reg         cps2_obj_ext = 1'b0
`endif
`ifdef CPS2_QSND24
    ,output reg         cps2_qsnd_ext = 1'b0
`endif
);

assign dwnld_busy = ioctl_rom;

// The start position header has 16 bytes, from which 6 are actually used and
// 10 are reserved
localparam [25:0] START_BYTES   = 8,
                  START_HEADER  = 16,
                  STARTW        = START_BYTES<<3;

localparam [25:0] FULL_HEADER   = 26'd64,
                  KABUKI_HEADER = 26'd48,
                  KABUKI_END    = KABUKI_HEADER + 26'd11,
                  CPS2_KEYS     = 26'd44,
                  CPS2_END      = 26'd64;

localparam [ 5:0] JOY_BYTE      = 6'h28;

reg  [STARTW-1:0] starts;
wire       [15:0] snd_start, pcm_start, gfx_start, qsnd_start;
reg        [ 7:0] pre_data;
reg        [ 1:0] kabuki_sr; // For 96MHz the write pulse must last two cycles

assign snd_start  = starts[15: 0];
assign pcm_start  = starts[31:16];
assign gfx_start  = starts[47:32];
assign qsnd_start = starts[63:48];
assign prog_data  = {2{pre_data}};
`ifdef CPS15
assign kabuki_we  = kabuki_sr[0];
`else
assign kabuki_we  = 0;
`endif

`ifdef CPS2_QSND24
// Flat QSound (marker bit 04) orders the image CPU, Z80, samples, DSP
// firmware, graphics: the four 16-bit KiB start fields keep their meaning and
// stay below 64 MiB, and graphics become the open-ended top region. The
// download address is therefore 27 bits wide and every region compare uses
// all of it, so an address above 64 MiB never aliases a low region. Without
// the capability the regions are the stock ones (firmware open-ended on top).
wire [26:0] bulk_addr = ioctl_addr - FULL_HEADER; // the header is excluded
wire [26:0] cpu_addr  = bulk_addr ; // the header is excluded
wire [26:0] snd_addr  = bulk_addr - { snd_start[15:0], 10'd0 };
wire [26:0] pcm_addr  = bulk_addr - { pcm_start[15:0], 10'd0 };
wire [26:0] gfx_off   = bulk_addr - { gfx_start, 10'd0 };
wire [16:0] bulk_kib  = bulk_addr[26:10];
reg  [25:0] gfx_addr;
reg  [ 1:0] gfx_bank;

wire is_cps    = ioctl_addr > 7 && ioctl_addr < (REGSIZE+START_HEADER);
wire is_kabuki = ioctl_addr >= KABUKI_HEADER && ioctl_addr < KABUKI_END;
wire is_cps2   = ioctl_addr >= CPS2_KEYS && ioctl_addr < CPS2_END;
wire is_cpu    = bulk_kib < {1'b0, snd_start};
wire is_snd    = bulk_kib < {1'b0, pcm_start}  && bulk_kib >= {1'b0, snd_start};
wire is_oki    = bulk_kib < {1'b0, cps2_qsnd_ext ? qsnd_start : gfx_start} && bulk_kib >= {1'b0, pcm_start};
wire is_gfx    = bulk_kib >= {1'b0, gfx_start} && (cps2_qsnd_ext || bulk_kib < {1'b0, qsnd_start});
wire is_qsnd   = ioctl_addr >= FULL_HEADER && bulk_kib >= {1'b0, qsnd_start} && // Q-Sound ROM
                 (!cps2_qsnd_ext || bulk_kib < {1'b0, gfx_start});
// The flat order: exactly 16 MiB of samples, then exactly 8 KiB of DSP
// firmware on an 8 KiB boundary (its bytes address the DSP ROM with
// bulk_addr[12:0]), then graphics.
wire qsnd_flat_ok = (qsnd_start - pcm_start) == 16'h4000 && (gfx_start - qsnd_start) == 16'd8 &&
                    qsnd_start[2:0] == 3'd0;
`else
wire [25:0] bulk_addr = ioctl_addr - FULL_HEADER; // the header is excluded
wire [25:0] cpu_addr  = bulk_addr ; // the header is excluded
wire [25:0] snd_addr  = bulk_addr - { snd_start[15:0], 10'd0 };
wire [25:0] pcm_addr  = bulk_addr - { pcm_start[15:0], 10'd0 };
reg  [25:0] gfx_addr;
reg  [ 1:0] gfx_bank;

wire is_cps    = ioctl_addr > 7 && ioctl_addr < (REGSIZE+START_HEADER);
wire is_kabuki = ioctl_addr >= KABUKI_HEADER && ioctl_addr < KABUKI_END;
wire is_cps2   = ioctl_addr >= CPS2_KEYS && ioctl_addr < CPS2_END;
wire is_cpu    = bulk_addr[25:10] < snd_start;
wire is_snd    = bulk_addr[25:10] < pcm_start  && bulk_addr[25:10] >=snd_start;
wire is_oki    = bulk_addr[25:10] < gfx_start  && bulk_addr[25:10] >=pcm_start;
wire is_gfx    = bulk_addr[25:10] < qsnd_start && bulk_addr[25:10] >=gfx_start;
wire is_qsnd   = ioctl_addr >= FULL_HEADER && bulk_addr[25:10] >=qsnd_start; // Q-Sound ROM
`endif

`ifdef CPS2_PRG8
// Prototype header bytes 12..15: "C2", version 1, program capability 1.
// A fresh download clears authorization at byte 0; a user reset retains it.
// Only a complete, ordered marker with an exact 8 MiB CPU region enables it.
reg [2:0] ext_header_step = 0;
`ifdef CPS2_QSND24
wire cap_ok = ext_header_step==3 && snd_start==16'h2000 && (
                ioctl_dout==8'h01 ||
               (ioctl_dout==8'h03 && gfx_slice_ok) ||
              ((ioctl_dout==8'h05 || ioctl_dout==8'h07) && qsnd_flat_ok));
`endif
always @(posedge clk) begin
    if (ioctl_wr && ioctl_rom && !ioctl_ram) begin
        if (ioctl_addr==0) begin
            cps2_prog_ext <= 0;
`ifdef CPS2_OBJEXT
            cps2_obj_ext  <= 0;
`endif
`ifdef CPS2_QSND24
            cps2_qsnd_ext <= 0;
`endif
            ext_header_step <= 0;
        end else if (ioctl_addr==12) begin
            cps2_prog_ext <= 0;
`ifdef CPS2_OBJEXT
            cps2_obj_ext  <= 0;
`endif
`ifdef CPS2_QSND24
            cps2_qsnd_ext <= 0;
`endif
            ext_header_step <= ioctl_dout==8'h43 ? 1 : 0;
        end else if (ioctl_addr==13) begin
            ext_header_step <= ext_header_step==1 && ioctl_dout==8'h32 ? 2 : 0;
        end else if (ioctl_addr==14) begin
            ext_header_step <= ext_header_step==2 && ioctl_dout==8'h01 ? 3 : 0;
        end else if (ioctl_addr==15) begin
`ifdef CPS2_QSND24
            // Byte 15 is a capability mask: 01 program window, 02 object slice,
            // 04 flat QSound. Accepted: 01, 03, 05 and 07. 03 needs the 40 MiB
            // graphics region of the stock order; 05 and 07 need the flat
            // order (qsnd_flat_ok), where graphics are open-ended and the 07
            // slice size is bounded at download instead (gfx_allowed). Any
            // other value or a failed condition leaves every capability off.
            cps2_prog_ext <= cap_ok;
            cps2_obj_ext  <= cap_ok && ioctl_dout[1];
            cps2_qsnd_ext <= cap_ok && ioctl_dout[2];
`elsif CPS2_OBJEXT
            // Byte 15 is a capability mask: 01 = program window, 03 = program
            // window plus the 8 MiB object extension slice. 03 additionally
            // requires a graphics region of exactly 40 MiB (32 MiB library +
            // slice). Any other value or an incomplete marker fails closed.
            cps2_prog_ext <= ext_header_step==3 && snd_start==16'h2000 &&
                             (ioctl_dout==8'h01 || (ioctl_dout==8'h03 && gfx_slice_ok));
            cps2_obj_ext  <= ext_header_step==3 && snd_start==16'h2000 &&
                             ioctl_dout==8'h03 && gfx_slice_ok;
`else
            cps2_prog_ext <= ext_header_step==3 && ioctl_dout==8'h01 && snd_start==16'h2000;
`endif
            ext_header_step <= 0;
        end
    end
end
wire [22:0] cpu_phys = cps2_prog_ext ? {cpu_addr[22], 1'b0, cpu_addr[21:1]} : cpu_addr[23:1];
wire cpu_allowed = !is_cpu || (cps2_prog_ext ? bulk_addr<26'h0800000 : bulk_addr<26'h0400000);
`else
wire [22:0] cpu_phys = cpu_addr[23:1];
wire cpu_allowed = 1'b1;
`endif

`ifdef CPS2_OBJEXT
// Object extension slice: graphics region byte offsets 32..40 MiB keep the
// bank-2/bit-22 rule of the 32 MiB library and set SDRAM word address bit 23,
// so they land in bank 2 bytes 16..24 MiB, where the OBJ slot reads tile code
// bit 18 (ext=1, bank bits 00). Region starts are 16-bit KiB counts, so the
// 40 MiB region still fits the stock header; without the capability the
// bytes above 32 MiB are dropped instead of overwriting the library.
wire        gfx_slice_ok  = (qsnd_start - gfx_start) == 16'ha000;
wire        gfx_slice     = cps2_obj_ext && gfx_addr[25];
wire [23:0] gfx_phys      = {gfx_slice, gfx_addr[24], gfx_addr[22:1]};
`ifdef CPS2_QSND24
// In the flat order graphics are the open-ended top region: bytes past the
// library (32 MiB, 40 MiB with the slice) are dropped, never wrapped.
wire        gfx_allowed   = !is_gfx || (cps2_qsnd_ext ?
                                gfx_off < (cps2_obj_ext ? 27'h2800000 : 27'h2000000) :
                                !gfx_addr[25] || cps2_obj_ext);
`else
wire        gfx_allowed   = !is_gfx || !gfx_addr[25] || cps2_obj_ext;
`endif
`else
wire [22:0] gfx_phys      = {gfx_addr[24], gfx_addr[22:1]};
wire        gfx_allowed   = 1'b1;
`endif

reg       decrypt, pang3, pang3_bit;
reg [7:0] pang3_decrypt;

always @(*) begin
`ifdef CPS2_QSND24
    gfx_addr  = gfx_off[25:0];
`else
    gfx_addr  = bulk_addr - { gfx_start, 10'd0 };
`endif
`ifdef CPS2
    // CPS2 address lines are scrambled
    gfx_addr = { gfx_addr[25:21], gfx_addr[3], gfx_addr[20:4], gfx_addr[2:0] };
    gfx_bank = { 1'b1, gfx_addr[23]};
`else
    gfx_bank  = 2'b11;
`endif
end


// The decryption is literally copied from MAME, it is up to
// the synthesizer to optimize the code. And it will.
always @(*) begin
    if( CPS==1 ) begin
        pang3 = is_cpu && cpu_addr[19] && decrypt  && (cpu_addr[0]^pang3_bit);
        pang3_decrypt =
            (((((((ioctl_dout[0] ? 8'h04 : 8'h00)  ^
                  (ioctl_dout[1] ? 8'h21 : 8'h00)) ^
                  (ioctl_dout[2] ? 8'h01 : 8'h00)) ^
                  (ioctl_dout[3] ? 8'h00 : 8'h50)) ^
                  (ioctl_dout[4] ? 8'h40 : 8'h00)) ^
                  (ioctl_dout[5] ? 8'h06 : 8'h00)) ^
                  (ioctl_dout[6] ? 8'h08 : 8'h00)) ^
                  (ioctl_dout[7] ? 8'h00 : 8'h88);
    end else begin
        pang3 = 0;
        pang3_decrypt = 8'd0;
    end
end

always @(posedge clk) begin
    if ( ioctl_wr && !ioctl_ram ) begin
        pre_data  <= pang3 ?
            pang3_decrypt : ioctl_dout;
        prog_mask <= !ioctl_addr[0] ? 2'b10 : 2'b01;
        prog_addr <= is_cpu ? cpu_phys + CPU_OFFSET : (
                     is_snd ?  snd_addr[23:1] + SND_OFFSET : (
                     is_oki ?  pcm_addr[23:1] + PCM_OFFSET :
                     is_gfx ?  gfx_phys + GFX_OFFSET : {10'd0, bulk_addr[12:0]}));
        prog_ba   <= (is_cpu||is_snd) ? 2'd0 : ( is_gfx ? gfx_bank : 2'd1 );
        if( is_kabuki )
            kabuki_sr <= 2'b11;
        if( is_cps2 ) begin
            cps2_key_we <= 1;
        end
        if( ioctl_addr < START_BYTES ) begin
            starts  <= { ioctl_dout, starts[STARTW-1:8] };
            cfg_we  <= 1'b0;
            prog_we <= 1'b0;
            prom_we <= 1'b0;
        end else begin
            if( is_cps ) begin
                cfg_we    <= 1'b1;
                prog_we   <= 1'b0;
                prom_we   <= 1'b0;
                if( ioctl_addr[5:0] == CFG_BYTE )
                    {decrypt, pang3_bit} <= ioctl_dout[7:6];
            end else if(ioctl_addr>=FULL_HEADER) begin
                cfg_we    <= 1'b0;
                prog_we   <= ~is_qsnd && cpu_allowed && gfx_allowed;
                prom_we   <=  is_qsnd;
            end else if( ioctl_addr[5:0] == JOY_BYTE ) begin
                joymode <= ioctl_dout[1:0]; // only CPS2
            end
        end
    end
    else begin
        cps2_key_we <= 0;
        if(!ioctl_rom || prog_rdy) prog_we  <= 1'b0;
        if( !ioctl_rom ) begin
            decrypt    <= 0;
            prom_we    <= 0;
        end
        kabuki_sr <= kabuki_sr>>1;
        cfg_we    <= 0;
    end
end

endmodule
