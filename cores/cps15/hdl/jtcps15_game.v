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
    Date: 26-9-2020 */

module jtcps15_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

wire        clk_gfx, rst_gfx, hold_rst;
wire        snd_cs, qsnd_cs, main_ram_cs, main_vram_cs, main_rom_cs,
            rom0_cs, rom1_cs,
            vram_dma_cs;
wire        HB, VB;
wire [18:0] snd_addr;
wire [22:0] qsnd_addr;
wire        prog_qsnd;
wire [ 7:0] snd_data, qsnd_data;
wire [17:1] ram_addr;
wire [21:1] main_rom_addr;
wire [15:0] main_ram_data, main_rom_data, main_dout, mmr_dout;
wire        main_rom_ok, main_ram_ok;
wire        ppu1_cs, ppu2_cs, ppu_rstn;
wire [19:0] rom1_addr, rom0_addr;
wire [31:0] rom0_data, rom1_data;
// Video RAM interface
wire [17:1] vram_dma_addr;
wire [15:0] vram_dma_data;
wire        vram_dma_ok, rom0_ok, rom1_ok, snd_ok, qsnd_ok;
wire [15:0] cpu_dout;
wire        cpu_speed;

wire        main_rnw, busreq, busack;
wire [ 7:0] dipsw_a, dipsw_b, dipsw_c;

wire        vram_clr, vram_rfsh_en;
wire [ 8:0] hdump;
wire [ 8:0] vdump, vrender;

wire        rom0_half, rom1_half;
wire        cfg_we;
wire        charger, video_flip;

// QSound - Decode keys
wire        kabuki_we, kabuki_en;

// M68k - Sound subsystem communication
wire [ 7:0] main2qs_din;
wire [23:1] main2qs_addr;
wire        main2qs_cs, main_busakn, main_waitn;

// EEPROM
wire        sclk, sdi, sdo, scs;

assign { dipsw_c, dipsw_b, dipsw_a } = ~24'd0;
assign snd_peak = 0;

wire [ 1:0] dsn;
wire        cen16, cen12, cen8, cen10b;
wire        cpu_cen, cpu_cenb;
wire        turbo;
reg         rst_game;

// CPS+ arranged audio (cpsplus_top): gate over the suppressed QSound
// handshake writes.  Constant 0 unless a pack is loaded and enabled.
wire        trig_gate;
`ifndef CPSPLUS
assign trig_gate = 1'b0;
`endif

`include "turbo.vh"

assign snd_vu     = 0;
assign debug_view = 0;
assign ba1_din=0, ba2_din=0, ba3_din=0,
       ba1_dsn=3, ba2_dsn=3, ba3_dsn=3;

// CPU clock enable signals come from 48MHz domain
/* verilator lint_off PINMISSING */
jtframe_cen48 u_cen48(
    .clk        ( clk48         ),
    .cen16      ( cen16         ),
    .cen12      ( cen12         ),
    .cen8       ( cen8          ),
    .cen6       (               ),
    .cen4       (               ),
    .cen4_12    (               ),
    .cen3       (               ),
    .cen3q      (               ),
    .cen1p5     (               ),
    // 180 shifted signals
    .cen12b     (               ),
    .cen6b      (               ),
    .cen3b      (               ),
    .cen3qb     (               ),
    .cen1p5b    (               )
);

assign clk_gfx = clk;
assign rst_gfx = rst;

always @(posedge clk) rst_game <= hold_rst | rst48;

localparam REGSIZE=24;

// Turbo speed disables DMA
wire busreq_cpu = busreq & ~turbo;
wire busack_cpu;
assign busack = busack_cpu | turbo;

jtcps1_main u_main(
    .rst        ( rst_game          ),
    .clk        ( clk48             ),
    .cen10      ( cpu_cen           ),
    .cen10b     ( cpu_cenb          ),
    .cpu_cen    (                   ),
    .turbo      ( 1'b1              ),  // 12MHz CPU
    // Timing
    .V          ( vdump             ),
    .LVBL       ( LVBL              ),
    .LHBL       ( LHBL              ),
    // PPU
    .ppu1_cs    ( ppu1_cs           ),
    .ppu2_cs    ( ppu2_cs           ),
    .ppu_rstn   ( ppu_rstn          ),
    .mmr_dout   ( mmr_dout          ),
    // Sound
    .main2qs_din ( main2qs_din      ),
    .main2qs_addr( main2qs_addr     ),
    .main2qs_cs  ( main2qs_cs       ),
    .main2qs_busakn( main_busakn    ),
    .main2qs_waitn( main_waitn      ),
    .UDSWn      ( dsn[1]            ),
    .LDSWn      ( dsn[0]            ),
    // cabinet I/O
    // Cabinet input
    .charger     ( charger          ),
    .cab_1p      ( cab_1p           ),
    .coin        ( coin             ),
    .joystick1   ( joystick1        ),
    .joystick2   ( joystick2        ),
    .joystick3   ( joystick3        ),
    .joystick4   ( joystick4        ),
    .dial_x      ( 2'd0             ),
    .dial_y      ( 2'd0             ),
    .service     ( service          ),
    .tilt        ( 1'b1             ),
    // BUS sharing
    .busreq      ( busreq_cpu       ),
    .busack      ( busack_cpu       ),
    .RnW         ( main_rnw         ),
    // RAM/VRAM access
    .addr        ( ram_addr         ),
    .cpu_dout    ( main_dout        ),
    .ram_cs      ( main_ram_cs      ),
    .vram_cs     ( main_vram_cs     ),
    .ram_data    ( main_ram_data    ),
    .ram_ok      ( main_ram_ok      ),
    // ROM access
    .rom_cs      ( main_rom_cs      ),
    .rom_addr    ( main_rom_addr    ),
    .rom_data    ( main_rom_data    ),
    .rom_ok      ( main_rom_ok      ),
    // DIP switches
    .dip_pause   ( dip_pause        ),
    .dip_test    ( dip_test         ),
    .dipsw_a     ( dipsw_a          ),
    .dipsw_b     ( dipsw_b          ),
    .dipsw_c     ( dipsw_c          ),
    // EEPROM
    .eeprom_sclk ( sclk             ),
    .eeprom_sdi  ( sdi              ),
    .eeprom_sdo  ( sdo              ),
    .eeprom_scs  ( scs              ),
    // Unused -stuff from CPS1
    .snd_latch0  (                  ),
    .snd_latch1  (                  ),
    .joymode     ( 2'd0             )
);

reg rst_video, rst_sdram;

always @(negedge clk_gfx) begin
    rst_video <= rst_gfx;
end

always @(negedge clk) begin
    rst_sdram <= rst;
end

assign dip_flip = ~video_flip;

jtcps1_video #(REGSIZE) u_video(
    .rst            ( rst_video     ),
    .clk            ( clk_gfx       ),
    .clk_cpu        ( clk48         ),
    .pxl2_cen       ( pxl2_cen      ),
    .pxl_cen        ( pxl_cen       ),

    .hdump          ( hdump         ),
    .vdump          ( vdump         ),
    .vrender        ( vrender       ),
    .gfx_en         ( gfx_en        ),
    .cpu_speed      ( cpu_speed     ),
    .charger        ( charger       ),
    .kabuki_en      ( kabuki_en     ),
    .raster         (               ),

    // CPU interface
    .ppu_rstn       ( ppu_rstn      ),
    .ppu1_cs        ( ppu1_cs       ),
    .ppu2_cs        ( ppu2_cs       ),
    .addr           ( ram_addr[12:1]),
    .dsn            ( dsn           ),      // data select, active low
    .cpu_dout       ( main_dout     ),
    .mmr_dout       ( mmr_dout      ),
    // BUS sharing
    .busreq         ( busreq        ),
    .busack         ( busack        ),

    // Video signal
    .HS             ( HS            ),
    .VS             ( VS            ),
    .LHBL           ( LHBL          ),
    .LVBL           ( LVBL          ),
`ifdef CPSPLUS_DBG
    .red            ( cpsp_red      ),   // routed through the CPS+ debug overlay
    .green          ( cpsp_green    ),
    .blue           ( cpsp_blue     ),
`else
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
`endif
    .flip           ( video_flip    ),

    // CPS-B Registers
    .cfg_we         ( cfg_we        ),
    .cfg_data       ( prog_data[7:0]),

    // Extra inputs read through the C-Board
    .cab_1p   ( cab_1p  ),
    .coin     ( coin    ),
    .joystick1      ( joystick1     ),
    .joystick2      ( joystick2     ),
    .joystick3      ( joystick3     ),
    .joystick4      ( joystick4     ),

    // Video RAM interface
    .vram_dma_addr  ( vram_dma_addr ),
    .vram_dma_data  ( vram_dma_data ),
    .vram_dma_ok    ( vram_dma_ok   ),
    .vram_dma_cs    ( vram_dma_cs   ),
    .vram_dma_clr   ( vram_clr      ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    // GFX ROM interface
    .rom1_addr      ( rom1_addr     ),
    .rom1_half      ( rom1_half     ),
    .rom1_data      ( rom1_data     ),
    .rom1_cs        ( rom1_cs       ),
    .rom1_ok        ( rom1_ok       ),
    .rom0_addr      ( rom0_addr     ),
    .rom0_bank      (               ),
    .rom0_half      ( rom0_half     ),
    .rom0_data      ( rom0_data     ),
    .rom0_cs        ( rom0_cs       ),
    .rom0_ok        ( rom0_ok       ),

    .debug_bus      ( debug_bus     ),
    // unused
    .star_bank      (               ),
    .star0_addr     (               ),
    .star0_data     ( 32'd0         ),
    .star0_cs       (               ),
    .star0_ok       ( 1'd0          ),
    .star1_addr     (               ),
    .star1_data     ( 32'd0         ),
    .star1_cs       (               ),
    .star1_ok       ( 1'd0          ),
    .watch_vram_cs  ( 1'd0          ),
    .watch          (               )
);

jtcps15_sound u_sound(
    .rst        ( rst               ),
    .clk48      ( clk48             ),
    .clk96      ( clk               ),
    .cen8       ( cen8              ),
    .vol_up     ( 1'b0              ),
    .vol_down   ( 1'b0              ),
    // Decode keys
    .kabuki_we  ( kabuki_we         ),
    .kabuki_en  ( kabuki_en         ),

    // Interface with main CPU
    .main_addr  ( main2qs_addr      ),
    .main_dout  ( main_dout[7:0]    ),
    .main_din   ( main2qs_din       ),
    // CPS+: the gate blocks exactly the suppressed handshake byte writes
    .main_ldswn ( dsn[0] | trig_gate ),
    .main_buse_n( ~main2qs_cs       ),
    .main_busakn( main_busakn       ),
    .main_waitn ( main_waitn        ),

    // ROM
    .rom_addr   ( snd_addr          ),
    .rom_cs     ( snd_cs            ),
    .rom_data   ( snd_data          ),
    .rom_ok     ( snd_ok            ),

    // QSound sample ROM
    .qsnd_addr  ( qsnd_addr         ), // max 8 MB.
    .qsnd_cs    ( qsnd_cs           ),
    .qsnd_data  ( qsnd_data         ),
    .qsnd_ok    ( qsnd_ok           ),

    // ROM programming interface
    .prog_addr  ( prog_addr[12:0]   ),
    .prog_data  ( prog_data[7:0]    ),
    .prog_we    ( prog_qsnd         ),

    // Sound output
`ifdef CPSPLUS
    .left       ( qsnd_left         ),
    .right      ( qsnd_right        ),
`else
    .left       ( snd_left          ),
    .right      ( snd_right         ),
`endif
    .sample     ( sample            ),
    .volume     (                   )
);

`ifdef CPSPLUS
// ----------------------------------------------------------------- CPS+ ---
// Arranged-audio stack (cpsplus_top = trigger sniffer + pack loader/DDR
// backend + ADX/PCM player).  CPS1.5 shares jtcps15_sound (the QSound board)
// with CPS2, so the tap is the CPS2 tap verbatim; the pack descriptor moves
// the latch page (0x618000 -> 0xf18000).  Passive tap on the 68K->QSound bus
// nets; the only edit to the stock core is the main_ldswn gate above.  The
// pack rides the MRA ROM image into DDR at 0x30000000 (pack pointer at image
// bytes 8-9).  See modules/cpsplus/README.md.
wire signed [15:0] qsnd_left, qsnd_right, cpsp_l, cpsp_r;
wire [15:0] cpsp_rate;
wire [1:0]  cpsp_cen_v;               // jtframe_frac_cen needs W>=2
wire        cpsp_cen = cpsp_cen_v[0];
// The On/Off toggle was removed: suppression means the sound CPU never got
// the music command, so switching off left SILENCE until the next cue (and
// on CPS2 the gated write cannot be re-synthesised at all).  A/B against the
// stock core by launching the stock MRA instead.  status[15:14] now sets the
// arranged VOLUME so the music can be balanced against the native SFX.
wire        cpsp_osd_en = 1'b1;             // tap always enabled
wire [ 1:0] cpsp_vol    = status[15:14];    // 0=100% 1=125% 2=150% 3=75%
reg         cpsp_boot_go, cpsp_boot_arm;
reg         cpsp_frame,   lvbl_l;

always @(posedge clk) begin
    cpsp_boot_arm <= rst ? 1'b1 : cpsp_boot_arm & ioctl_rom;
    cpsp_boot_go  <= ~rst & cpsp_boot_arm & ~ioctl_rom;  // fire once post-reset, ROM+pack in DDR
    lvbl_l       <= LVBL;
    cpsp_frame   <= lvbl_l & ~LVBL;             // ~60 Hz fade-law tick
end

// exact per-track sample cen: cen = clk * n / m (any rate, 96 MHz master)
jtframe_frac_cen #(.W(2), .WC(27)) u_cpsp_cen(
    .clk    ( clk                ),
    .n      ( {11'd0, cpsp_rate} ),
    .m      ( 27'd96_000_000     ),
    .cen    ( cpsp_cen_v         ),
    .cenb   (                    )
);

// Shift-only attenuation, REGISTERED: feeding a 4-way mux straight into the
// mixer cost ~0.44 ns of setup slack on jtcps15 (stock +0.152 -> cpsplus
// -0.441).  One clock of latency (~10 ns) is inaudible at a 48 kHz sample
// rate and keeps the audio path out of the critical path.
// Steps are 100/125/150/75 %.  The boost steps can push a near-full-scale
// sample past 16 bits, so the sum is formed 18 bits wide and SATURATED.
// Letting it wrap would turn a loud passage into a click at the wrap point,
// which is a far worse artefact than the clipping it replaces.
wire signed [17:0] cpsp_lx = {{2{cpsp_l[15]}}, cpsp_l};
wire signed [17:0] cpsp_rx = {{2{cpsp_r[15]}}, cpsp_r};

function signed [15:0] sat( input signed [17:0] v );
    // 16'sh8000 rather than -16'sd32768: the decimal form asks for 32768 in a
    // SIGNED 16-bit literal, which overflows and only lands on -32768 by way of
    // two's-complement wrap.  Quartus reports that as "constant value overflow".
    sat = ( v >  18'sd32767 ) ? 16'sh7fff :
          ( v < -18'sd32768 ) ? 16'sh8000 : v[15:0];
endfunction

reg signed [15:0] cpsp_lv, cpsp_rv;
always @(posedge clk) begin
    case( cpsp_vol )
        2'd0: begin cpsp_lv <= cpsp_l;                          cpsp_rv <= cpsp_r;                         end
        2'd1: begin cpsp_lv <= sat(cpsp_lx + (cpsp_lx>>>2));    cpsp_rv <= sat(cpsp_rx + (cpsp_rx>>>2));   end
        2'd2: begin cpsp_lv <= sat(cpsp_lx + (cpsp_lx>>>1));    cpsp_rv <= sat(cpsp_rx + (cpsp_rx>>>1));   end
        default: begin cpsp_lv <= cpsp_l - (cpsp_l>>>2);        cpsp_rv <= cpsp_r - (cpsp_r>>>2);          end
    endcase
end
// CPS+ debug read-out taps.  Declared unconditionally so the tap instance
// below has something to drive in every build; without CPSPLUS_DBG they are
// simply unused and optimise away.
wire [3:0] cpsp_status;
wire [7:0] cpsp_last_cmd;
wire       cpsp_last_mapped, cpsp_playing;

cpsplus_top u_cpsplus(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .main_addr      ( main2qs_addr  ),
    .main_dout      ( main_dout     ),
    .dsn            ( dsn           ),
    .main_rnw       ( main_rnw      ),
    .main2qs_cs     ( main2qs_cs    ),
    .gate           ( trig_gate     ),
    .cen_sample     ( cpsp_cen      ),
    .cen_frame      ( cpsp_frame    ),
    .osd_pause      ( ~dip_pause    ),
    .audio_l        ( cpsp_l        ),
    .audio_r        ( cpsp_r        ),
    .sample_vld     (               ),
    .playing        ( cpsp_playing  ),
    .trk_rate       ( cpsp_rate     ),
    .base_addr      ( 32'h3000_0000 ),  // MRA ROM image base in DDR
    .base_indirect  ( 1'b1          ),  // pack pointer at image bytes 8-9
    .osd_en         ( cpsp_osd_en   ),
    .boot_go        ( cpsp_boot_go  ),
    .ready          (               ),
    .magic_ok       (               ),
    .status         ( cpsp_status   ),
    .last_cmd       ( cpsp_last_cmd ),
    .last_mapped    ( cpsp_last_mapped ),
    .ddram_busy     ( cpsp_busy     ),
    .ddram_burstcnt ( cpsp_burstcnt ),
    .ddram_addr     ( cpsp_addr     ),
    .ddram_dout     ( cpsp_dout     ),
    .ddram_dout_ready( cpsp_dout_ready ),
    .ddram_rd       ( cpsp_rd       )
);

// 16-bit saturating sum of QSound + CPS+ player (jtframe_limsum clips and
// flags peaks; MiSTer sys resamples AUDIO_L/R, so the 24 kHz QSound and
// the 32-48 kHz player mix as zero-order-held streams)
jtframe_limsum #(.WI(16), .K(2)) u_cpsp_mixl(
    .rst    ( rst                 ),
    .clk    ( clk                 ),
    .cen    ( 1'b1                ),
    .parts  ( {cpsp_lv, qsnd_left} ),
    .en     ( 2'b11               ),
    .sum    ( snd_left            ),
    .peak   (                     )
);
jtframe_limsum #(.WI(16), .K(2)) u_cpsp_mixr(
    .rst    ( rst                  ),
    .clk    ( clk                  ),
    .cen    ( 1'b1                 ),
    .parts  ( {cpsp_rv, qsnd_right} ),
    .en     ( 2'b11                ),
    .sum    ( snd_right            ),
    .peak   (                      )
);
`endif

wire nc0, nc1, nc2, nc3, nc4;

jtcps1_sdram #(.CPS(15), .REGSIZE(REGSIZE)) u_sdram (
    .rst         ( rst_sdram     ),
    .clk         ( clk           ),
    .clk_gfx     ( clk_gfx       ),
    .clk_cpu     ( clk48         ),
    .LVBL        ( LVBL          ),
    .hold_rst    ( hold_rst      ),

    .ioctl_rom   ( ioctl_rom     ),
    .dwnld_busy  ( dwnld_busy    ),
    .cfg_we      ( cfg_we        ),

    // ROM LOAD
    .ioctl_addr  ( ioctl_addr    ),
    .ioctl_dout  ( ioctl_dout    ),
    .ioctl_din   ( ioctl_din     ),
    .ioctl_wr    ( ioctl_wr      ),
    .ioctl_ram   ( ioctl_ram     ),
    .prog_addr   ({nc4,prog_addr}),
    .prog_data   ( prog_data     ),
    .prog_mask   ( prog_mask     ),
    .prog_ba     ( prog_ba       ),
    .prog_we     ( prog_we       ),
    .prog_rd     ( prog_rd       ),
    .prog_rdy    ( prog_rdy      ),
    .prog_qsnd   ( prog_qsnd     ),
    // Kabuki decoder (CPS 1.5)
    .kabuki_we   ( kabuki_we     ),

    // EEPROM
    .sclk           ( sclk          ),
    .sdi            ( sdi           ),
    .sdo            ( sdo           ),
    .scs            ( scs           ),

    // Main CPU
    .main_rom_cs    ( main_rom_cs   ),
    .main_rom_ok    ( main_rom_ok   ),
    .main_rom_addr  ( main_rom_addr ),
    .main_rom_data  ( main_rom_data ),

    // VRAM
    .vram_clr       ( vram_clr      ),
    .vram_dma_cs    ( vram_dma_cs   ),
    .main_ram_cs    ( main_ram_cs   ),
    .main_vram_cs   ( main_vram_cs  ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    // Object RAM (CPS2)
    .main_oram_cs   ( 1'b0          ),

    .dsn            ( dsn           ),
    .main_dout      ( main_dout     ),
    .main_rnw       ( main_rnw      ),

    .main_ram_ok    ( main_ram_ok   ),
    .vram_dma_ok    ( vram_dma_ok   ),

    .main_ram_addr  ( ram_addr      ),
    .vram_dma_addr  ( vram_dma_addr ),

    .main_ram_data  ( main_ram_data ),
    .vram_dma_data  ( vram_dma_data ),

    // Sound CPU and PCM
    .snd_cs      ( snd_cs        ),
    .pcm_cs      ( qsnd_cs       ),

    .snd_ok      ( snd_ok        ),
    .pcm_ok      ( qsnd_ok       ),

    .snd_addr    ( snd_addr      ),
    .pcm_addr    ( qsnd_addr     ),

    .snd_data    ( snd_data      ),
    .pcm_data    ( qsnd_data     ),

    // Graphics
    .rom0_cs     ( rom0_cs       ),
    .rom1_cs     ( rom1_cs       ),

    .rom0_ok     ( rom0_ok       ),
    .rom1_ok     ( rom1_ok       ),

    .rom0_addr   ( rom0_addr     ),
    .rom1_addr   ( rom1_addr     ),

    .rom0_half   ( rom0_half     ),
    .rom1_half   ( rom1_half     ),

    .rom0_data   ( rom0_data     ),
    .rom1_data   ( rom1_data     ),

    .star0_addr  ( 13'd0         ),
    .star0_data  (               ),
    .star0_ok    (               ),
    .star0_cs    ( 1'b0          ),

    .star1_addr  ( 13'd0         ),
    .star1_data  (               ),
    .star1_ok    (               ),
    .star1_cs    ( 1'b0          ),

    // Bank 0: allows R/W
    .ba0_addr    ( {nc0,ba0_addr}),
    .ba1_addr    ( {nc1,ba1_addr}),
    .ba2_addr    ( {nc2,ba2_addr}),
    .ba3_addr    ( {nc3,ba3_addr}),
    .ba_rd       ( ba_rd         ),
    .ba_wr       ( ba_wr         ),
    .ba_ack      ( ba_ack        ),
    .ba_dst      ( ba_dst        ),
    .ba_dok      ( ba_dok        ),
    .ba_rdy      ( ba_rdy        ),
    .ba0_din     ( ba0_din       ),
    .ba0_dsn     ( ba0_dsn       ),

    .data_read   ( data_read     ),
    // Unused - CPS2
    .rom0_bank    ( 2'd0         ),
    .star_bank    ( 1'd0         ),
    .cps2_key_we  (              ),
    .cps2_joymode (              ),
    .dump_flag    (              )
);

`ifdef CPSPLUS_DBG
// Debug build only: the video output detours through the overlay so a glance at
// the screen says whether the pack loaded and whether the last sound command
// was one the pack maps.  Runs in the video clock domain (clk_gfx/pxl_cen);
// the overlay resyncs the CPS+ status signals internally.
wire [`JTFRAME_COLORW-1:0] cpsp_red, cpsp_green, cpsp_blue;

cpsplus_dbg_overlay #(.CW(`JTFRAME_COLORW)) u_cpsp_dbg(
    .clk        ( clk_gfx           ),
    .pxl_cen    ( pxl_cen           ),
    .LHBL       ( LHBL              ),
    .LVBL       ( LVBL              ),
    .status     ( cpsp_status       ),
    .playing    ( cpsp_playing      ),
    .last_cmd   ( cpsp_last_cmd     ),
    .last_mapped( cpsp_last_mapped  ),
    // silence-diagnosis rows: wired on jtcps2 only; tied off here
    .last_verb  ( 3'd0              ),
    .last_ctrl  ( 1'b0              ),
    .fst        ( 3'd0              ),
    .end_cause  ( 4'd0              ),
    .fifo_empty ( 1'b0              ),
    .red_in     ( cpsp_red          ),
    .green_in   ( cpsp_green        ),
    .blue_in    ( cpsp_blue         ),
    .red_out    ( red               ),
    .green_out  ( green             ),
    .blue_out   ( blue              )
);
`endif

endmodule
