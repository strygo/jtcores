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
    Date: 28-1-2020 */

module jtcps1_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

wire        clk_gfx, rst_gfx, hold_rst;
wire        snd_cs, adpcm_cs, main_ram_cs, main_vram_cs, main_rom_cs,
            rom0_cs, rom1_cs,
            vram_dma_cs;
wire [ 1:0] joymode;
wire [15:0] snd_addr;
wire [17:0] adpcm_addr;
wire [ 7:0] snd_data, adpcm_data;
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
wire        vram_dma_ok, rom0_ok, rom1_ok, snd_ok, adpcm_ok;
wire [15:0] cpu_dout;
wire        cpu_speed;
wire        star_bank, dump_flag;

wire        main_rnw, busreq, busack;
wire [ 7:0] snd_latch0, snd_latch1;
wire [ 7:0] dipsw_a, dipsw_b, dipsw_c;

wire [12:0] star0_addr, star1_addr;
wire [31:0] star0_data, star1_data;
wire        star0_ok,   star1_ok,
            star0_cs,   star1_cs;

wire        vram_clr, vram_rfsh_en;
wire [ 8:0] hdump;
wire [ 8:0] vdump, vrender;

wire        rom0_half, rom1_half;
wire        cfg_we;

// EEPROM
wire        sclk, sdi, sdo, scs;

assign { dipsw_c, dipsw_b, dipsw_a } = dipsw[23:0];

wire [15:0] fave;
wire [ 1:0] dsn;
wire        cen10b;
wire        cpu_cen, cpu_cenb;
wire        charger;
wire        turbo, video_flip, filter_old;
reg         rst_game;

`include "turbo.vh"
assign snd_vu       = 0;
assign filter_old   = dipsw[24];
assign debug_view   = debug_bus[0] ? fave[7:0] : fave[15:8];
    //{ 6'd0, dump_flag, filter_old };
assign ba1_din=0, ba2_din=0, ba3_din=0,
       ba1_dsn=3, ba2_dsn=3, ba3_dsn=3;

assign clk_gfx  = clk;
assign rst_gfx  = rst;

always @(posedge clk) rst_game <= hold_rst | rst48;

localparam REGSIZE=24;

// Turbo speed disables DMA
wire busreq_cpu = busreq & ~turbo;
wire busack_cpu;
assign busack = busack_cpu | turbo;
/* verilator tracing_on */
jtcps1_main u_main(
    .rst        ( rst_game          ),
    .clk        ( clk48             ),
    .cen10      ( cpu_cen           ),
    .cen10b     ( cpu_cenb          ),
    .cpu_cen    (                   ),
    .turbo      ( turbo             ),
    .joymode    ( joymode           ),
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
    .snd_latch0 ( snd_latch0        ),
    .snd_latch1 ( snd_latch1        ),
    .UDSWn      ( dsn[1]            ),
    .LDSWn      ( dsn[0]            ),
    // cabinet I/O
    // Cabinet input
    .charger     ( charger          ),
    .cab_1p      ( cab_1p[1:0]      ),
    .coin        ( coin[1:0]        ),
    .joystick1   ( joystick1        ),
    .joystick2   ( joystick2        ),
    .dial_x      ( dial_x           ),
    .dial_y      ( dial_y           ),
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
    .fave        ( fave             )
);

reg rst_video;

always @(posedge clk_gfx) begin
    rst_video <= rst_gfx;
end

assign dip_flip = video_flip;
/* verilator tracing_off */
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
    .kabuki_en      (               ),
    .raster         (               ),
    .watch          (               ),
    .watch_vram_cs  (               ),
    .star_bank      ( star_bank     ),

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

    // EEPROM
    .sclk           ( sclk          ),
    .sdi            ( sdi           ),
    .sdo            ( sdo           ),
    .scs            ( scs           ),

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

    .star0_addr     ( star0_addr    ),
    .star0_data     ( star0_data    ),
    .star0_ok       ( star0_ok      ),
    .star0_cs       ( star0_cs      ),

    .star1_addr     ( star1_addr    ),
    .star1_data     ( star1_data    ),
    .star1_ok       ( star1_ok      ),
    .star1_cs       ( star1_cs      ),
    .debug_bus      ( debug_bus     )
);

`ifdef FAKE_LATCH
integer snd_frame_cnt=0;
reg [7:0] fake_latch0 = 8'h0, fake_latch1 = 8'h0;
assign snd_latch1 = fake_latch1;
assign snd_latch0 = fake_latch0;
localparam FAKE0=20;
localparam FAKE1=1000;
always @(negedge LVBL) begin
    snd_frame_cnt <= snd_frame_cnt+1;
    case( snd_frame_cnt )
        /* ffight
        FAKE0: fake_latch <= 8'hf0;
        FAKE0+5+2: fake_latch <= 8'hf7;
        FAKE0+5+4: fake_latch <= 8'hf2;
        FAKE0+5+6: fake_latch <= 8'h55;
        default: fake_latch <= 8'hff;
        */
        // Nemo
        //FAKE0: fake_latch <= 8'h2;
        //FAKE0+1: fake_latch <= 8'h2;
        //FAKE0+2: fake_latch <= 8'h0;
        // KOD
        FAKE0: fake_latch0 <= 8'h6;
        // Magic Sword
        //FAKE0: fake_latch <= 8'h1e;
        //FAKE1: fake_latch <= 8'h0;
        //FAKE1+1: fake_latch <= 8'h4;
        //FAKE1+2: fake_latch <= 8'h0;
        // SF2, Chun Li
        // FAKE0: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hf0;
        // end

        // FAKE0+10: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end
        // FAKE0+11: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hf7;
        // end
        // FAKE0+12: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end
        // FAKE0+13: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'h06;
        // end
        // FAKE0+14: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end

        //default: fake_latch <= 8'hff;
    endcase
end
`endif

reg [3:0] rst_snd;
always @(posedge clk) begin
    rst_snd <= { rst_snd[2:0], rst_game };
end
/* verilator tracing_off */
jtcps1_sound u_sound(
    .rst            ( rst_snd[3]    ),
    .clk            ( clk48         ),

    .filter_old     ( filter_old    ),
    .dip_fxlevel    ( dip_fxlevel   ),
    // Interface with main CPU
`ifdef CPSPLUS
    // CPS+: the command latch the Z80 actually sees — a suppressed music
    // command is replaced by the idle byte (0xff) so the native YM2151/OKI
    // music never starts; every other command passes through unchanged
    .snd_latch0     ( snd_latch0_snd ),
`else
    .snd_latch0     ( snd_latch0    ),
`endif
    .snd_latch1     ( snd_latch1    ),

    // ROM
    .rom_addr       ( snd_addr      ),
    .rom_cs         ( snd_cs        ),
    .rom_data       ( snd_data      ),
    .rom_ok         ( snd_ok        ),

    // ADPCM ROM
    .adpcm_addr     ( adpcm_addr    ),
    .adpcm_cs       ( adpcm_cs      ),
    .adpcm_data     ( adpcm_data    ),
    .adpcm_ok       ( adpcm_ok      ),

    // Sound output
`ifdef CPSPLUS
    .left           ( native_left   ),
    .right          ( native_right  ),
`else
    .left           ( snd_left      ),
    .right          ( snd_right     ),
`endif
    .sample         ( sample        ),
    .peak           ( snd_peak      ),
    .debug_bus      ( debug_bus     )
);

`ifdef CPSPLUS
// ----------------------------------------------------------------- CPS+ ---
// Arranged-audio stack (cpsplus_cps1_top = CPS1 sound-latch sniffer + pack
// loader/DDR backend + ADX/PCM player).  CPS1 sound is a fire-and-forget
// byte latch, so the only edit to the stock core is the snd_latch0
// substitution mux below (native music suppression); the fade latch
// snd_latch1 is untouched.  The pack rides the MRA ROM image into DDR at
// 0x30000000 (pack pointer at image bytes 8-9).  See
// modules/cpsplus/README.md.
wire signed [15:0] native_left, native_right, cpsp_l, cpsp_r;
wire        cpsp_sub;
wire [ 7:0] cpsp_idle;
wire [15:0] cpsp_rate;
wire [ 1:0] cpsp_cen_v;                     // jtframe_frac_cen needs W>=2
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
reg  [ 1:0] cpsp_sub_s;                     // sub resynced 96 MHz -> clk48

always @(posedge clk) begin
    cpsp_boot_arm <= rst ? 1'b1 : cpsp_boot_arm & ioctl_rom;
    cpsp_boot_go  <= ~rst & cpsp_boot_arm & ~ioctl_rom;  // fire once post-reset, ROM+pack in DDR
    lvbl_l       <= LVBL;
    cpsp_frame   <= lvbl_l & ~LVBL;             // ~60 Hz fade-law tick
end

// Idle-byte substitution feeding jtcps1_sound (clk48 domain).  cpsp_sub is
// a level held for the whole frame a suppressed command sits in the latch;
// a 2-FF resync into clk48 makes the mux glitch-free (cpsp_idle is a
// load-time constant = 0xff).
always @(posedge clk48) cpsp_sub_s <= { cpsp_sub_s[0], cpsp_sub };
wire [7:0] snd_latch0_snd = cpsp_sub_s[1] ? cpsp_idle : snd_latch0;

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

cpsplus_cps1_top u_cpsplus(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .latch          ( snd_latch0    ),  // raw 68K command latch (clk48)
    .sub            ( cpsp_sub      ),
    .idle_byte      ( cpsp_idle     ),
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

// 16-bit saturating sum of native CPS1 audio (SFX only after suppression)
// + the CPS+ player (jtframe_limsum clips and flags peaks; MiSTer sys
// resamples AUDIO_L/R, so the 48 kHz native and 32-48 kHz player mix as
// zero-order-held streams)
jtframe_limsum #(.WI(16), .K(2)) u_cpsp_mixl(
    .rst    ( rst                    ),
    .clk    ( clk                    ),
    .cen    ( 1'b1                   ),
    .parts  ( {cpsp_lv, native_left}  ),
    .en     ( 2'b11                  ),
    .sum    ( snd_left               ),
    .peak   (                        )
);
jtframe_limsum #(.WI(16), .K(2)) u_cpsp_mixr(
    .rst    ( rst                    ),
    .clk    ( clk                    ),
    .cen    ( 1'b1                   ),
    .parts  ( {cpsp_rv, native_right} ),
    .en     ( 2'b11                  ),
    .sum    ( snd_right              ),
    .peak   (                        )
);
`endif

reg rst_sdram;
always @(posedge clk) rst_sdram <= rst;

wire nc0, nc1, nc2, nc3;
/* verilator tracing_on */
jtcps1_sdram #(.REGSIZE(REGSIZE)) u_sdram (
    .rst         ( rst_sdram     ),
    .clk         ( clk           ),
    .clk_gfx     ( clk_gfx       ),
    .clk_cpu     ( clk48         ),
    .LVBL        ( LVBL          ),
    .star_bank   ( star_bank     ),
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
    /*verilator lint_off width*/
    .prog_addr   ( prog_addr     ),
    /*verilator lint_on width*/
    .prog_data   ( prog_data     ),
    .prog_mask   ( prog_mask     ),
    .prog_ba     ( prog_ba       ),
    .prog_we     ( prog_we       ),
    .prog_rd     ( prog_rd       ),
    .prog_rdy    ( prog_rdy      ),
    // Unused QSound ports
    .prog_qsnd   (               ),
    .kabuki_we   (               ),
    // Unused CPS2 ports
    .cps2_key_we (               ),
    .cps2_joymode( joymode       ),
    .rom0_bank   (               ),

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
    .pcm_cs      ( adpcm_cs      ),

    .snd_ok      ( snd_ok        ),
    .pcm_ok      ( adpcm_ok      ),

    .snd_addr    ( snd_addr      ),
    .pcm_addr    ( adpcm_addr    ),

    .snd_data    ( snd_data      ),
    .pcm_data    ( adpcm_data    ),

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

    .star0_addr  ( star0_addr    ),
    .star0_data  ( star0_data    ),
    .star0_ok    ( star0_ok      ),
    .star0_cs    ( star0_cs      ),

    .star1_addr  ( star1_addr    ),
    .star1_data  ( star1_data    ),
    .star1_ok    ( star1_ok      ),
    .star1_cs    ( star1_cs      ),

    // Bank 0: allows R/W
    /*verilator lint_off width*/
    .ba0_addr    ({nc0,ba0_addr} ),
    .ba1_addr    ({nc1,ba1_addr} ),
    .ba2_addr    ({nc2,ba2_addr} ),
    .ba3_addr    ({nc3,ba3_addr} ),
    /*verilator lint_on width*/
    .ba_rd       ( ba_rd         ),
    .ba_wr       ( ba_wr         ),
    .ba_ack      ( ba_ack        ),
    .ba_dst      ( ba_dst        ),
    .ba_dok      ( ba_dok        ),
    .ba_rdy      ( ba_rdy        ),
    .ba0_din     ( ba0_din       ),
    .ba0_dsn     ( ba0_dsn       ),

    .data_read   ( data_read     ),
    .dump_flag   ( dump_flag     )
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
