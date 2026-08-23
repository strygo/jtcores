/*  CPS+ — cpsplus_cps1_tap: CPS1 sound-latch sniffer + idle-byte gate (v0)
    ========================================================================

    The CPS1 counterpart of cpsplus_trigger.v.  CPS1 has NO QSound shared
    RAM and NO handshake: the 68K drops a single command byte into a
    fire-and-forget register latch that the Z80 sound CPU polls.  For
    Street Fighter II (World Warrior, Z80 driver 4.25) the ground truth
    (manifests/protocol/sf2.json, research/cps1_sf2_hsf2_join.md) is:

      * The 68K drain routine ($6284) writes the fade byte to $800189
        (jtcps1 `snd_latch1`) then the command byte to $800181
        (jtcps1 `snd_latch0`), once per frame.  The Z80 reads the command
        at 0xf008 and the fade at 0xf00a (jtcps1_sound latch0/1_cs).
      * Every payload command is followed one frame later by 0xff
        (idle / terminator); 0xf7 stops a section, boot sends 0xf0.  So
        the command latch carries a stream that is 0xff most of the time
        with the occasional momentary command value.
      * 0x800180..0x80018f is write-only on the 68K side (PAL LWIO) — there
        is no readback to preserve, so suppression is NOT a bus-write gate
        (as on CPS2) but a value substitution on what the Z80 reads.

    This module snoops `snd_latch0` (the command latch, tapped in the game
    top before jtcps1_sound consumes it), classifies the 8-bit command
    through the pack trigger table (direct-mapped, same 4-byte row format
    as cpsplus_trigger / PACK_FORMAT.md), and:

      * for a PLAY / STOP row flagged `suppress`, raises `sub` for as long
        as that command sits in the latch, so the game top substitutes the
        configured idle byte (0xff) into what jtcps1_sound sees — the Z80
        driver never starts the native YM2151 / OKI music channels; and
      * emits a verb event (evt_*) for the reused cpsplus_ddr / player on
        the rising edge of a new music command.

    Everything else — SFX (0x21..0x32), announcer voices (0x56..0x87), and
    the whole 0xf0..0xff control family (0xf0 boot, 0xf7 section stop, 0xff
    idle) — is NEVER suppressed and passes through to the Z80 unchanged, so
    real hardware SFX/voice fidelity is untouched (join doc gating note).

    Reuse contract: the evt_*, cfg_* and trig_* ports are identical in
    meaning to cpsplus_trigger, so cpsplus_ddr drives this module's config
    / table-load ports and consumes its events with no change.  The pack's
    protocol descriptor (pack/protocols.py "sf2") sets the idle byte
    (handshake_ready -> hs_ready), the control-region threshold
    (control_region_start = 0x00f0) and the control-verb map through the
    same header -> cfg path cpsplus_ddr already implements.

    Clocking / CDC: this module runs on `clk` (96 MHz SDRAM/DDRAM domain,
    same as cpsplus_ddr / cpsplus_player).  `snd_latch0` is a 48 MHz
    (clk48) register; it is brought in through a 2-FF synchroniser plus a
    3-clk stability filter (a real command sits in the latch for a whole
    ~60 Hz frame, so requiring 3 stable clks fully rejects any multi-bit
    sampling skew).  The `sub` level and `idle_byte` are the only outputs
    the game top crosses back to clk48 (a stable level + a load-time
    constant — see the integration patch).

    Timing margin: classification settles 3 clk after a new command is
    accepted (`lut_valid`), exactly as in cpsplus_trigger.  `sub` and the
    event therefore assert ~5 clk (~52 ns) after the 68K posts the command.
    The Z80's poll of the latch happens on its own much slower loop and is
    always far later than the 68K write that produced the value (the CPS1
    analogue of cpsplus_trigger's "handshake write is a later bus cycle"
    invariant), so the decision is always in place before the Z80 acts.

    Config MODE register (0x07), shared layout with cpsplus_trigger:
      bit 0  enable   0 = passive (stock core); reset default
      bit 1  dialect  ignored here (this IS the CPS1 dialect module)
      bit 2  nogate   1 = observe-only (events emitted, `sub` masked)
      bits 6:4        control-region default verb

    Verbs (PACK_FORMAT.md): 0 none, 1 play, 2 stop, 3 fade_out,
    4 fade_keep, 5 restore, 6 master_fade.  Control commands are never
    suppressed.

    Verilog-2005, no vendor primitives.
*/

module cpsplus_cps1_tap #(parameter
    TRIG_ROWS = 256,        // CPS1 command is a single byte -> 256 rows
    TRIG_AW   = 8           // address bits for the table load port
)(
    input               rst,
    input               clk,        // 96 MHz, cpsplus_ddr/player domain
    input               cen,        // sample enable (tie 1)

    // CPS1 command latch, tapped in the game top (jtcps1 snd_latch0).
    // 48 MHz register value; synchronised + stability-filtered internally.
    input        [ 7:0] latch,

    // idle-byte substitution: game top does snd_latch0_snd =
    // sub ? idle_byte : snd_latch0 (see integration patch).  `sub` is a
    // level held for the whole duration a suppressed command sits latched.
    output              sub,
    output       [ 7:0] idle_byte,

    // verb event, 1-clk strobe (player interface — same as cpsplus_trigger)
    output reg          evt_stb,
    output reg   [ 2:0] evt_verb,   // 1 play .. 6 master_fade
    output reg   [11:0] evt_track,  // play/stop: pack track index
    output reg   [ 6:0] evt_gain,   // play/stop: linear gain, 0x7f = unity
    output reg   [15:0] evt_argw,   // CPS1 has no record args -> 0
    output reg   [ 7:0] evt_argb,   // CPS1 has no record args -> 0
    output reg          evt_ctrl,   // 1 = control-region command
    output reg          evt_sup,    // 1 = this command was suppressed

    // config register port — filled from the pack header at boot by
    // cpsplus_ddr (identical stream as for cpsplus_trigger)
    input               cfg_we,
    input        [ 7:0] cfg_addr,
    input        [15:0] cfg_data,

    // trigger-table load port — pack rows as little-endian 32-bit words
    input               trig_we,
    input [TRIG_AW-1:0] trig_addr,
    input        [31:0] trig_data
);

// ---------------------------------------------------------------- config ---
// Only the fields the byte-latch dialect needs are used (cfg 0x05 high byte
// = idle/substitute byte, 0x06 = control threshold, 0x07 = MODE, control
// map at 0x40+).  cfg 0x00..0x04 (QSound page / record offsets) are loaded
// by cpsplus_ddr but carry no meaning here and are simply not decoded.
reg  [ 7:0] hs_ready;              // idle byte substituted for the Z80 (0xff)
reg  [15:0] ctrl_start;           // control-region threshold (0x00f0)
reg  [ 2:0] ctrl_dflt;
reg         mode_en, mode_nogate;

reg  [15:0] ctrl_cmd [0:31];
reg  [ 2:0] ctrl_vb  [0:31];

always @(posedge clk) begin
    if( rst ) begin
        hs_ready   <= 8'hff;
        ctrl_start <= 16'h00f0;
        ctrl_dflt  <= 3'd0;
        mode_en    <= 1'b0;        // no pack loaded = stock behavior
        mode_nogate<= 1'b0;
    end else if( cfg_we ) begin
        if( !cfg_addr[6] ) case( cfg_addr[2:0] )
            3'd5: hs_ready   <= cfg_data[15:8];   // {hs_ready, hs_pending}
            3'd6: ctrl_start <= cfg_data;
            3'd7: begin
                mode_en     <= cfg_data[0];
                mode_nogate <= cfg_data[2];
                ctrl_dflt   <= cfg_data[6:4];
            end
            default: ;             // 0..4 unused by the byte-latch dialect
        endcase
        else if( !cfg_addr[0] ) ctrl_cmd[ cfg_addr[5:1] ] <= cfg_data;
        else                    ctrl_vb [ cfg_addr[5:1] ] <= cfg_data[2:0];
    end
end

assign idle_byte = hs_ready;

// ------------------------------------------- latch sync + new-command edge --
// 2-FF synchroniser (clk48 -> clk) then a 3-clk stability filter before a
// distinct value is accepted as the current command.  `cmd_new` is the
// CPS1 analogue of cpsplus_trigger's handshake-write strobe.
reg  [7:0] s0, s1, s2;
reg  [1:0] stab;
reg  [7:0] cmd_cur;
reg        cmd_new;

always @(posedge clk) begin
    if( rst ) begin
        s0 <= 8'hff; s1 <= 8'hff; s2 <= 8'hff;
        stab <= 2'd0; cmd_cur <= 8'hff; cmd_new <= 1'b0;
    end else if( cen ) begin
        s0 <= latch;
        s1 <= s0;
        cmd_new <= 1'b0;
        if( s1 != s2 ) begin
            s2   <= s1;
            stab <= 2'd3;                  // restart stability window
        end else if( stab != 2'd0 ) begin
            stab <= stab - 2'd1;
            if( stab == 2'd1 && s1 != cmd_cur ) begin
                cmd_cur <= s1;             // accept a stable, distinct value
                cmd_new <= 1'b1;
            end
        end
    end
end

// -------------------------------------------------- classification lookup ---
// Trigger table BRAM — same little-endian pack row as cpsplus_trigger:
//   [7:0] verb, [15:8] track low, [23:16] gain, [24] suppress,
//   [31:28] track high nibble.
reg  [31:0] trig_mem [0:TRIG_ROWS-1];
reg  [31:0] row_q;

localparam [15:0] ROWS16 = TRIG_ROWS;

wire [15:0] cmd16   = { 8'd0, cmd_cur };
wire        in_range= cmd16 < ROWS16;
wire [TRIG_AW-1:0] rd_addr = in_range ? cmd_cur[TRIG_AW-1:0] : {TRIG_AW{1'b0}};

always @(posedge clk) begin
    if( trig_we ) trig_mem[trig_addr] <= trig_data;
    row_q <= trig_mem[rd_addr];
end

// Control-verb map: parallel compare (<= 32 entries; loader zero-fills the
// rest — entry cmd 0 can never match because it is below ctrl_start).
reg        ctrl_hit;
reg  [2:0] ctrl_verb_mux;
integer ci;
always @(*) begin
    ctrl_hit      = 1'b0;
    ctrl_verb_mux = 3'd0;
    for( ci = 0; ci < 32; ci = ci+1 )
        if( ctrl_cmd[ci] == cmd16 ) begin
            ctrl_hit      = 1'b1;
            ctrl_verb_mux = ctrl_vb[ci];
        end
end

// Two-stage registered classification; settles 3 clk after a new command
// is accepted (identical structure to cpsplus_trigger).
reg        st_ctrl, st_hit, st_range;
reg  [2:0] st_cverb;
reg  [2:0]  cls_verb;
reg  [11:0] cls_track;
reg  [ 6:0] cls_gain;
reg         cls_sup, cls_ctrl;
reg  [ 1:0] settle;
wire        lut_valid = settle == 2'd0;

always @(posedge clk) begin
    if( rst ) begin
        st_ctrl  <= 1'b0; st_hit <= 1'b0; st_range <= 1'b0; st_cverb <= 3'd0;
        cls_verb <= 3'd0; cls_track <= 12'd0; cls_gain <= 7'd0;
        cls_sup  <= 1'b0; cls_ctrl <= 1'b0;
        settle   <= 2'd3;
    end else begin
        // stage 1: aligned with the BRAM read of cmd_cur
        st_ctrl  <= cmd16 >= ctrl_start;
        st_hit   <= ctrl_hit;
        st_cverb <= ctrl_verb_mux;
        st_range <= in_range;
        // stage 2: classification from row_q + stage-1 flags
        if( st_ctrl ) begin
            cls_verb  <= st_hit ? st_cverb : ctrl_dflt;
            cls_track <= 12'd0;
            cls_gain  <= 7'd0;
            cls_sup   <= 1'b0;      // control commands are never suppressed
            cls_ctrl  <= 1'b1;
        end else if( st_range ) begin
            cls_verb  <= row_q[2:0];
            cls_track <= { row_q[31:28], row_q[15:8] };
            cls_gain  <= row_q[22:16];
            cls_sup   <= row_q[24];
            cls_ctrl  <= 1'b0;
        end else begin              // beyond the table: unmatched (SFX)
            cls_verb  <= 3'd0;
            cls_track <= 12'd0;
            cls_gain  <= 7'd0;
            cls_sup   <= 1'b0;
            cls_ctrl  <= 1'b0;
        end
        // settle guard: new command / tables rewritten
        if( cmd_new || cfg_we || trig_we ) settle <= 2'd3;
        else if( settle != 2'd0 )          settle <= settle - 2'd1;
    end
end

// ---------------------------------------------------------------- outputs ---
// `sub` is a level: the current latched command is a suppress-flagged row,
// classification is settled, the module is enabled and not in observe-only.
// The game top synchronises it to clk48 and muxes idle_byte in for the Z80.
assign sub = mode_en && !mode_nogate && lut_valid && cls_sup;

// Event: fire once per newly accepted command, after its lookup settles.
reg pend;
always @(posedge clk) begin
    if( rst ) begin
        evt_stb  <= 1'b0;
        evt_verb <= 3'd0;  evt_track <= 12'd0; evt_gain <= 7'd0;
        evt_argw <= 16'd0; evt_argb  <= 8'd0;
        evt_ctrl <= 1'b0;  evt_sup   <= 1'b0;
        pend     <= 1'b0;
    end else if( cen ) begin
        evt_stb <= 1'b0;
        if( cmd_new ) pend <= 1'b1;
        else if( pend && lut_valid ) begin
            pend <= 1'b0;
            if( mode_en && cls_verb != 3'd0 ) begin
                evt_stb   <= 1'b1;
                evt_verb  <= cls_verb;
                evt_track <= cls_track;
                evt_gain  <= cls_gain;
                evt_argw  <= 16'd0;               // no record args on CPS1
                evt_argb  <= 8'd0;
                evt_ctrl  <= cls_ctrl;
                evt_sup   <= cls_sup && !mode_nogate;
            end
        end
    end
end

endmodule
