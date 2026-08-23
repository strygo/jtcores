/* CPS+ — cpsplus_cps1_top: CPS1 tap + pack loader/DDR backend + player
    ====================================================================

    CPS1 sibling of cpsplus_top.v.  Same shared playback engine
    (cpsplus_ddr + cpsplus_player + cpsplus_adx, all reused unchanged);
    only the front-end sniffer differs, because CPS1 sound is a
    fire-and-forget single-byte register latch instead of the CPS2 QSound
    shared-RAM record + handshake (see cpsplus_cps1_tap.v).

        snd_latch0 tap ─▶ cpsplus_cps1_tap ──evt_*──▶ cpsplus_ddr ◀─▶ DDRAM
                              │  ▲ cfg/table load          │ trk/fade/start
                        sub / idle_byte                    ▼   ▲ mem port
                              │                     cpsplus_player ─▶ audio
                              ▼
                     game-top idle-byte mux -> jtcps1_sound

    The single edit to the stock CPS1 core is the idle-byte substitution
    mux on the command latch feeding jtcps1_sound: `sub` selects
    `idle_byte` (0xff) in place of a suppressed music command so the Z80
    never starts the native music; every other command passes through.

    Clocking: everything runs on `clk` (the 96 MHz SDRAM/DDRAM master, the
    same domain cpsplus_ddr and cpsplus_player use in jtcps2).  `latch` is
    the clk48 command register, resynchronised inside the tap.
    `cen_sample` is a jtframe_frac_cen at the current track's sample rate
    (n = trk_rate, m = 96,000,000); `cen_frame` is the ~60 Hz fade tick
    (LVBL edge in the game top).

    With no pack loaded, `boot_go` never pulsed, or `osd_en` low, the tap
    stays disabled (reset default) and `sub` is constant 0: the host core
    is stock.  See modules/cpsplus/README.md for the exact hookup.
*/

module cpsplus_cps1_top #(parameter
    TRIG_AW   = 8,          // CPS1 command is a single byte -> 256 rows
    TRIG_ROWS = 256,
    TRK_AW    = 7
)(
    input             rst,
    input             clk,

    // CPS1 command latch tap (jtcps1 snd_latch0, before jtcps1_sound)
    input      [ 7:0] latch,
    output            sub,           // 1 = substitute idle_byte for the Z80
    output     [ 7:0] idle_byte,     // configured idle/terminator (0xff)

    // audio
    input             cen_sample,    // frac cen at trk_rate (see header)
    input             cen_frame,     // ~60 Hz fade tick
    input             osd_pause,
    output signed [15:0] audio_l,
    output signed [15:0] audio_r,
    output            sample_vld,
    output            playing,
    output     [15:0] trk_rate,      // current track rate for the frac cen

    // control / status
    input      [31:0] base_addr,     // pack / MRA image DDR byte address
    input             base_indirect, // 1 = image base + header bytes 8-9
    input             osd_en,
    input             boot_go,       // pulse after ROM load / pack switch
    output            ready,
    output            magic_ok,
    output     [ 3:0] status,
    // Diagnostic read-out for CPSPLUS_DBG's on-screen indicator: the last
    // command the tap decoded, and whether the pack had a trigger row for
    // it.  Without the second bit a silent cue is ambiguous -- "loaded but
    // nothing playing" is also what normal silence looks like -- so the
    // overlay could not distinguish a MISSING MAP ROW from a player fault.
    output reg [ 7:0] last_cmd,
    output reg        last_mapped,

    // MiSTer DDRAM master (single client presented upstream)
    input             ddram_busy,
    output     [ 7:0] ddram_burstcnt,
    output     [28:0] ddram_addr,
    input      [63:0] ddram_dout,
    input             ddram_dout_ready,
    output            ddram_rd
);

// tap <-> ddr
wire        evt_stb, evt_ctrl, evt_sup;
wire [ 2:0] evt_verb;
wire [11:0] evt_track;
wire [ 6:0] evt_gain;
wire [15:0] evt_argw;
wire [ 7:0] evt_argb;
wire        cfg_we, trig_we;
wire [ 7:0] cfg_addr;
wire [15:0] cfg_data;
wire [TRIG_AW-1:0] trig_addr;
wire [31:0] trig_data;

// ddr <-> player
wire        pl_start, pl_stop;
wire [31:0] trk_addr, trk_len, trk_lstart, trk_lend;
wire [31:0] trk_lstart_smp, trk_lend_smp;
wire        trk_xfade_en;
wire [ 1:0] trk_loop_cnt;
wire        trk_stereo, trk_codec;
wire [ 6:0] trk_gain, trig_gain;
wire [15:0] trk_c1, trk_c2;
wire [ 1:0] fade_law;
wire [31:0] fade_const1, fade_const2;
wire        fade_trig, fade_loop_off, fade_stop_at0, restore_trig;
wire [ 6:0] fade_target;
wire [15:0] fade_arg;
wire        pmem_rd, pmem_ack;
wire [31:3] pmem_addr;
wire [63:0] pmem_data;

// ------------------------------------------------------------ local reset --
// jtframe launches game_rst on the INVERTED 96 MHz edge, so any path from it
// into this block is a HALF cycle (5.208 ns).  Feeding it straight into the
// player/adx register banks made it the dominant net in the jtcps1 fit: 58 of
// the top-100 violated setup paths were game_rst -> cpsplus (worst -0.194 ns
// with 4.957 ns of pure routing), and the resulting cross-die reset net also
// congested the base SDRAM controller -- its prechd/dqm_busy -> sdram_a[11]
// paths, which do not even appear in the stock leg's worst list, fell to
// -0.175.  So register the reset locally: the external net drives two flops
// instead of hundreds, and the internal reset fans out from a placed register
// on a FULL cycle.  Reset simply asserts/releases two clks later, which this
// block does not care about (the pack reloads a couple of cycles later).
// Power-up value 1 keeps simulation deterministic (starts held in reset).
reg rst_p = 1'b1, rst_i = 1'b1;
always @(posedge clk) begin
    rst_p <= rst;
    rst_i <= rst_p;
end


// last decoded command + whether it mapped (CPSPLUS_DBG read-out)
always @(posedge clk) begin
    if( rst ) begin
        last_cmd    <= 8'd0;
        last_mapped <= 1'b0;
    end else if( evt_stb ) begin
        last_cmd    <= latch;
        last_mapped <= evt_verb != 3'd0;
    end
end

cpsplus_cps1_tap #(
    .TRIG_ROWS ( TRIG_ROWS ),
    .TRIG_AW   ( TRIG_AW   )
) u_tap (
    .rst        ( rst_i        ),
    .clk        ( clk        ),
    .cen        ( 1'b1       ),
    .latch      ( latch      ),
    .sub        ( sub        ),
    .idle_byte  ( idle_byte  ),
    .evt_stb    ( evt_stb    ),
    .evt_verb   ( evt_verb   ),
    .evt_track  ( evt_track  ),
    .evt_gain   ( evt_gain   ),
    .evt_argw   ( evt_argw   ),
    .evt_argb   ( evt_argb   ),
    .evt_ctrl   ( evt_ctrl   ),
    .evt_sup    ( evt_sup    ),
    .cfg_we     ( cfg_we     ),
    .cfg_addr   ( cfg_addr   ),
    .cfg_data   ( cfg_data   ),
    .trig_we    ( trig_we    ),
    .trig_addr  ( trig_addr  ),
    .trig_data  ( trig_data  )
);

cpsplus_ddr #(
    .TRIG_AW   ( TRIG_AW   ),
    .TRIG_ROWS ( TRIG_ROWS ),
    .TRK_AW    ( TRK_AW    ),
    .SAME_SONG ( 1         )   // measured on ffight/sf2: a re-sent command is ignored
) u_ddr (
    .rst            ( rst_i            ),
    .clk            ( clk            ),
    .base_addr      ( base_addr      ),
    .base_indirect  ( base_indirect  ),
    .osd_en         ( osd_en         ),
    .boot_go        ( boot_go        ),
    .ready          ( ready          ),
    .magic_ok       ( magic_ok       ),
    .status         ( status         ),
    .evt_stb        ( evt_stb        ),
    .evt_verb       ( evt_verb       ),
    .evt_track      ( evt_track      ),
    .evt_gain       ( evt_gain       ),
    .evt_argw       ( evt_argw       ),
    .evt_argb       ( evt_argb       ),
    .cfg_we         ( cfg_we         ),
    .cfg_addr       ( cfg_addr       ),
    .cfg_data       ( cfg_data       ),
    .trig_we        ( trig_we        ),
    .trig_addr      ( trig_addr      ),
    .trig_data      ( trig_data      ),
    .pl_start       ( pl_start       ),
    .pl_stop        ( pl_stop        ),
    .trk_addr       ( trk_addr       ),
    .trk_len        ( trk_len        ),
    .trk_lstart     ( trk_lstart     ),
    .trk_lend       ( trk_lend       ),
    .trk_lstart_smp ( trk_lstart_smp ),
    .trk_lend_smp   ( trk_lend_smp   ),
    .trk_xfade_en   ( trk_xfade_en   ),
    .trk_loop_cnt   ( trk_loop_cnt   ),
    .trk_stereo     ( trk_stereo     ),
    .trk_codec      ( trk_codec      ),
    .trk_gain       ( trk_gain       ),
    .trk_c1         ( trk_c1         ),
    .trk_c2         ( trk_c2         ),
    .trk_rate       ( trk_rate       ),
    .trig_gain      ( trig_gain      ),
    .fade_law       ( fade_law       ),
    .fade_const1    ( fade_const1    ),
    .fade_const2    ( fade_const2    ),
    .fade_trig      ( fade_trig      ),
    .fade_loop_off  ( fade_loop_off  ),
    .fade_stop_at0  ( fade_stop_at0  ),
    .restore_trig   ( restore_trig   ),
    .fade_target    ( fade_target    ),
    .fade_arg       ( fade_arg       ),
    .pmem_rd        ( pmem_rd        ),
    .pmem_addr      ( pmem_addr      ),
    .pmem_data      ( pmem_data      ),
    .pmem_ack       ( pmem_ack       ),
    .ddram_busy     ( ddram_busy     ),
    .ddram_burstcnt ( ddram_burstcnt ),
    .ddram_addr     ( ddram_addr     ),
    .ddram_dout     ( ddram_dout     ),
    .ddram_dout_ready( ddram_dout_ready ),
    .ddram_rd       ( ddram_rd       )
);

wire signed [15:0] pl_audio_l, pl_audio_r;   // player audio (declared before use)
cpsplus_player u_player (
    .rst            ( rst_i           ),
    .clk            ( clk           ),
    .cen_sample     ( cen_sample    ),
    .cen_frame      ( cen_frame     ),
    .start          ( pl_start      ),
    .stop           ( pl_stop       ),
    .osd_pause      ( osd_pause     ),
    .trk_addr       ( trk_addr      ),
    .trk_len        ( trk_len       ),
    .trk_loop_start ( trk_lstart    ),
    .trk_loop_end   ( trk_lend      ),
    .trk_stereo     ( trk_stereo    ),
    .trk_codec      ( trk_codec     ),
    .trk_gain       ( trk_gain      ),
    .trk_c1         ( trk_c1        ),
    .trk_c2         ( trk_c2        ),
    .trig_gain      ( trig_gain     ),
    .trk_xfade_en       ( trk_xfade_en   ),
    .trk_loop_cnt       ( trk_loop_cnt   ),
    .trk_loop_start_smp ( trk_lstart_smp ),
    .trk_loop_end_smp   ( trk_lend_smp   ),
    .fade_law       ( fade_law      ),
    .fade_const1    ( fade_const1   ),
    .fade_const2    ( fade_const2   ),
    .fade_trig      ( fade_trig     ),
    .fade_target    ( fade_target   ),
    .fade_arg       ( fade_arg      ),
    .fade_loop_off  ( fade_loop_off ),
    .fade_stop_at0  ( fade_stop_at0 ),
    .restore_trig   ( restore_trig  ),
    .mem_rd         ( pmem_rd       ),
    .mem_addr       ( pmem_addr     ),
    .mem_data       ( pmem_data     ),
    .mem_ack        ( pmem_ack      ),
    .audio_l        ( pl_audio_l    ),
    .audio_r        ( pl_audio_r    ),
    .sample_vld     ( sample_vld    ),
    .playing        ( playing       ),
    .track_done     (               )
);

// The audible pack-load diagnostic (a 1..6 beep count encoding the loader
// state) has been REMOVED.  cpsplus_dbg_overlay shows the same state as a
// colour, which needs no counting -- and the beeps had a worse problem than
// ambiguity: they fired whenever `playing` was low, which is most of the time.
// Every gap between arranged tracks beeped over the native chip, so a CPSPLUS_DBG
// build could not be used for the listening tests it was meant to support.
assign audio_l = pl_audio_l;
assign audio_r = pl_audio_r;

endmodule
