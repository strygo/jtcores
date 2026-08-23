/* CPS+ — cpsplus_top: trigger + pack loader/DDR backend + player
    ===============================================================

    Thin wrapper wiring the three CPS+ modules together.  This is the
    single module a game top (jtcps2_game / jtcps15_game) instantiates;
    see modules/cpsplus/README.md for the exact hookup.

        68K bus tap ─▶ cpsplus_trigger ──evt_*──▶ cpsplus_ddr ◀─▶ DDRAM
                            │  ▲ cfg/table load        │ trk/fade/start
                          gate │                       ▼   ▲ mem port
                               └──────────────── cpsplus_player ─▶ audio

    Clocking: everything runs on `clk` (the 96 MHz SDRAM/master clock in
    jtcores; the same domain as jtcps15_sound and the DDRAM port).
    `cen_sample` must tick at the current track's sample rate (drive a
    jtframe_frac_cen from the `trk_rate` output: n = trk_rate, m =
    96,000,000 at WC=27 — exact for any rate).  `cen_frame` is the ~60 Hz
    fade tick (LVBL edge in the game top).

    With no pack loaded, `boot_go` never pulsed, or `osd_en` low, the
    trigger stays disabled (reset default) and `gate` is constant 0:
    the host core is stock.  See the module headers of cpsplus_trigger.v,
    cpsplus_player.v and cpsplus_ddr.v for the contracts.
*/

module cpsplus_top #(parameter
    TRIG_AW   = 13,
    TRIG_ROWS = 4608,
    TRK_AW    = 7
)(
    input             rst,
    input             clk,

    // 68K bus tap (jtcps2_game nets, see rtl/README.md)
    input      [23:1] main_addr,     // main2qs_addr
    input      [15:0] main_dout,
    input      [ 1:0] dsn,           // {UDSWn, LDSWn}
    input             main_rnw,
    input             main2qs_cs,
    output            gate,          // OR into the sound module's LDSWn

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
    // ... and the VERB it mapped to (1 play .. 6 master_fade) + control flag:
    // last_cmd is only the low command byte, so a control-region 0xff05 and
    // a play row 0x0005 look identical on the overlay without these.
    output reg [ 2:0] last_verb,
    output reg        last_ctrl,
    output     [ 2:0] dbg_fst,        // player feed FSM (cpsplus_player.v)
    output     [ 3:0] dbg_end,        // {eof, loop_off, auto_stop, stop} sticky
    output            dbg_fempty,     // player sample FIFO empty

    // MiSTer DDRAM master (single client presented upstream)
    input             ddram_busy,
    output     [ 7:0] ddram_burstcnt,
    output     [28:0] ddram_addr,
    input      [63:0] ddram_dout,
    input             ddram_dout_ready,
    output            ddram_rd
);

// trigger <-> ddr
wire        evt_stb, evt_ctrl, evt_sup;
wire [15:0] cmd_dbg;
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
// Same fix as cpsplus_cps1_top: jtframe launches game_rst on the INVERTED
// 96 MHz edge, so a path from it into this block is a HALF cycle (5.208 ns).
// Fed straight into the player/adx register banks it became the dominant net
// in the jtcps1 fit (58 of the top-100 violated setup paths, worst -0.194 ns
// on routing alone) and congested the base SDRAM controller besides.  jtcps2
// and jtcps15 close, but only barely (+0.084 / +0.013), so they carry the same
// latent problem and want the same margin.  Register the reset locally: the
// external net drives two flops instead of hundreds and the internal reset
// fans out from a placed register on a FULL cycle.  Power-up value 1 keeps
// simulation deterministic (starts held in reset).
reg rst_p = 1'b1, rst_i = 1'b1;
always @(posedge clk) begin
    rst_p <= rst;
    rst_i <= rst_p;
end

cpsplus_trigger #(
    .TRIG_ROWS ( TRIG_ROWS ),
    .TRIG_AW   ( TRIG_AW   )
) u_trigger (
    .rst        ( rst_i        ),
    .clk        ( clk        ),
    .cen        ( 1'b1       ),
    .addr       ( main_addr  ),
    .dout       ( main_dout  ),
    .dsn        ( dsn        ),
    .rnw        ( main_rnw   ),
    .cs         ( main2qs_cs ),
    .gate       ( gate       ),
    .evt_stb    ( evt_stb    ),
    .evt_verb   ( evt_verb   ),
    .evt_track  ( evt_track  ),
    .evt_gain   ( evt_gain   ),
    .evt_argw   ( evt_argw   ),
    .evt_argb   ( evt_argb   ),
    .evt_ctrl   ( evt_ctrl   ),
    .evt_sup    ( evt_sup    ),
    .cmd_dbg    ( cmd_dbg    ),
    .err_unsettled (         ),
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
    .TRK_AW    ( TRK_AW    )
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
    .track_done     (               ),
    .dbg_fst        ( dbg_fst       ),
    .dbg_end        ( dbg_end       ),
    .dbg_fempty     ( dbg_fempty    )
);

// ----------------------------------------------------- audible diagnostic --
// The audible pack-load diagnostic (a 1..6 beep count encoding the loader
// state) has been REMOVED.  cpsplus_dbg_overlay shows the same state as a
// colour, which needs no counting -- and the beeps had a worse problem than
// ambiguity: they fired whenever `playing` was low, which is most of the time.
// Every gap between arranged tracks beeped over the native chip, so a CPSPLUS_DBG
// build could not be used for the listening tests it was meant to support.
assign audio_l = pl_audio_l;
assign audio_r = pl_audio_r;

// last decoded command + whether it mapped (CPSPLUS_DBG read-out)
always @(posedge clk) begin
    if( rst ) begin
        last_cmd    <= 8'd0;
        last_mapped <= 1'b0;
        last_verb   <= 3'd0;
        last_ctrl   <= 1'b0;
    end else if( evt_stb ) begin
        last_cmd    <= cmd_dbg[7:0];
        last_mapped <= evt_verb != 3'd0;
        last_verb   <= evt_verb;
        last_ctrl   <= evt_ctrl;
    end
end

endmodule
