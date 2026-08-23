/*  CPS+ — cpsplus_trigger: QSound-latch sniffer + handshake gate (v0)
    ====================================================================

    Passive tap on the 68K side of the QSound shared-RAM latch page
    (CPS2: 0x618000..0x61801F, CPS1.5: 0xF18000..0xF1801F).  Latches the
    record bytes as the 68K writes them, classifies the 16-bit command on
    the handshake write through the pack trigger table, and:

      * emits a verb event (play/stop/control) for the CPS+ player, and
      * for suppress-flagged commands, asserts `gate` combinationally for
        the whole duration of that handshake write so the integration mux
        can block the shared-RAM write enable for that byte lane only
        (the write itself is gated — nothing is ever re-poked; the Z80
        keeps seeing the last "ready" value at the handshake offset).

    Behavioral reference: cpsplus/lua/cpsplus_prototype.lua (Phase-2 MAME
    prototype, validated 2026-07-15).  Design: ASSESSMENT.md sections 6.1
    and 6.4.  Table/config layout: PACK_FORMAT.md (Binary layout v0).
    Integration contract: rtl/README.md.

    Protocol qualification (validated across 23 sets / 6 driver revisions
    in Phase 0 — record bytes always precede the handshake write):

      * Record fields and the handshake byte live on ODD byte addresses,
        i.e. the LOW byte lane (LDSWn / dsn[0]) of the big-endian 68K bus.
      * A handshake write is accepted only as a pure low-lane BYTE write
        (dsn == 2'b10) of the configured "pending" value to the configured
        handshake offset.  Full-word writes (dsn == 2'b00) never qualify:
        the boot memtest sweeps the page with word writes (0x0000 / 0x5555
        / 0xFFFF fills) and those must pass untouched.
      * Record-byte latching accepts the low lane of BOTH byte and word
        writes (the memtest zeros land in the field latches, exactly as in
        the software prototype — command 0x0000 classifies as "no row").
      * Absent record fields are configured as offset 0.  Since offset 0
        is even and all latched offsets are odd, an absent field can never
        match — it is skipped with no special casing (HSF2 1.06b omits the
        +0x05 arg byte this way).

    Classification is PRE-computed: every time a command byte latches, the
    trigger-table BRAM row and the control-verb map are re-evaluated into
    registered class_* values (3 clk settle, guarded by `lut_valid`).  By
    the time the handshake write appears on the bus — always a separate,
    later 68K bus cycle — the suppress decision is already registered, so
    `gate` is a shallow combinational term of the live bus qualifiers and
    can cover the write from its very first clk.

    Timing assumptions (see README):
      * Bus inputs are stable for the full 68K bus cycle (many clk at the
        core's 96 MHz master clock) — true for jtcps2_game.v nets.
      * The 68K deasserts its data strobes between consecutive bus cycles
        (edge detection relies on at least one idle clk between writes).

    Config MODE register (0x07):
      bit 0  enable      0 = module fully passive (stock core behavior)
      bit 1  dialect     0 = QSound record+handshake (CPS2 / CPS1.5, v0)
                         1 = RESERVED: CPS1 single-byte latch (0x800180
                             byte latch, no shared RAM, no handshake) —
                             documented hook only, not implemented in v0
      bit 2  nogate      1 = observe-only (events emitted, gate masked)
      bits 6:4           control-region default verb

    Verbs (PACK_FORMAT.md): 0 none, 1 play, 2 stop, 3 fade_out,
    4 fade_keep, 5 restore, 6 master_fade.  Control commands are NEVER
    suppressed (Z80-side behavior on 0xFFxx is correct for SFX).
*/

module cpsplus_trigger #(parameter
    TRIG_ROWS = 4608,       // pack trigger-table rows (v0: 0x1200)
    TRIG_AW   = 13          // address bits for the table load port
)(
    input               rst,
    input               clk,
    input               cen,        // bus-domain sample enable (tie 1)

    // 68K bus tap — jtcps2_game.v nets (see README for the exact wiring)
    input        [23:1] addr,       // main2qs_addr
    input        [15:0] dout,       // main_dout
    input        [ 1:0] dsn,        // {UDSWn, LDSWn}, active low
    input               rnw,        // main_rnw (1 = read)
    input               cs,         // main2qs_cs (region select)

    // handshake gate — OR into the LDSWn seen by the sound module
    output              gate,

    // verb event, 1-clk strobe (player interface)
    output reg          evt_stb,
    output reg   [ 2:0] evt_verb,   // 1 play .. 6 master_fade
    output reg   [11:0] evt_track,  // play/stop: pack track index
    output reg   [ 6:0] evt_gain,   // play/stop: linear gain, 0x7f = unity
    output reg   [15:0] evt_argw,   // record arg word {+arg_hi, +arg_lo}
    output reg   [ 7:0] evt_argb,   // record arg byte (+0x05); 0 if absent
    output reg          evt_ctrl,   // 1 = control-region command
    output reg          evt_sup,    // 1 = this command's handshake was gated

    output       [15:0] cmd_dbg,       // decoded command, for the CPSPLUS_DBG
                                       // on-screen read-out only
    output reg          err_unsettled, // sticky: handshake hit before lookup
                                       // settled (never in practice)

    // config register port — filled from the pack header at boot
    input               cfg_we,
    input        [ 7:0] cfg_addr,
    input        [15:0] cfg_data,

    // trigger-table load port — pack rows as little-endian 32-bit words
    input               trig_we,
    input [TRIG_AW-1:0] trig_addr,
    input        [31:0] trig_data
);

// ---------------------------------------------------------------- config ---
// Register map (cfg_addr):
//   0x00 latch_page[15:0]        0x01 {8'h0, latch_page[23:16]}
//   0x02 {3'h0, off_cmd_lo,  3'h0, off_cmd_hi }
//   0x03 {3'h0, off_arg_lo,  3'h0, off_arg_hi }
//   0x04 {3'h0, off_hs,      3'h0, off_arg_byte}   (arg_byte 0 = absent)
//   0x05 {hs_ready, hs_pending}                    (ready unused by v0)
//   0x06 control_region_start[15:0]
//   0x07 MODE (see header comment)
//   0x40+2i control map cmd[i]   0x41+2i {13'h0, verb[i]}   i = 0..31
reg [23:5] cfg_page;
reg [ 4:0] off_cmd_hi, off_cmd_lo, off_arg_hi, off_arg_lo, off_argb, off_hs;
reg [ 7:0] hs_pending, hs_ready;
reg [15:0] ctrl_start;
reg [ 2:0] ctrl_dflt;
reg        mode_en, mode_dialect, mode_nogate;

reg [15:0] ctrl_cmd [0:31];
reg [ 2:0] ctrl_vb  [0:31];

always @(posedge clk) begin
    if( rst ) begin
        cfg_page   <= 19'd0;
        off_cmd_hi <= 5'd0;  off_cmd_lo <= 5'd0;
        off_arg_hi <= 5'd0;  off_arg_lo <= 5'd0;
        off_argb   <= 5'd0;  off_hs     <= 5'd0;
        hs_pending <= 8'd0;  hs_ready   <= 8'd0;
        ctrl_start <= 16'hff00;
        ctrl_dflt  <= 3'd0;
        mode_en    <= 1'b0;  // no pack loaded = stock behavior
        mode_dialect <= 1'b0;
        mode_nogate  <= 1'b0;
    end else if( cfg_we ) begin
        if( !cfg_addr[6] ) case( cfg_addr[2:0] )
            3'd0: cfg_page[15:5] <= cfg_data[15:5];
            3'd1: cfg_page[23:16] <= cfg_data[7:0];
            3'd2: { off_cmd_lo, off_cmd_hi } <= { cfg_data[12:8], cfg_data[4:0] };
            3'd3: { off_arg_lo, off_arg_hi } <= { cfg_data[12:8], cfg_data[4:0] };
            3'd4: { off_hs, off_argb }       <= { cfg_data[12:8], cfg_data[4:0] };
            3'd5: { hs_ready, hs_pending }   <= cfg_data;
            3'd6: ctrl_start <= cfg_data;
            3'd7: begin
                mode_en      <= cfg_data[0];
                mode_dialect <= cfg_data[1];
                mode_nogate  <= cfg_data[2];
                ctrl_dflt    <= cfg_data[6:4];
            end
        endcase
        else if( !cfg_addr[0] ) ctrl_cmd[ cfg_addr[5:1] ] <= cfg_data;
        else                    ctrl_vb [ cfg_addr[5:1] ] <= cfg_data[2:0];
    end
end

// --------------------------------------------------------- record latches ---
// Low byte lane of the big-endian 68K bus = odd byte address {addr[4:1],1}.
wire        page_hit = cs && ( addr[23:5] == cfg_page );
wire        wr_lo    = mode_en && !mode_dialect && page_hit && !rnw && !dsn[0];
wire [ 4:0] off_lo   = { addr[4:1], 1'b1 };

// Pure low-lane byte write of the pending value to the handshake offset.
// dsn[1] high excludes full-word writes (boot memtest — requirement:
// byte-lane + value qualification).
wire hs_sel = wr_lo && dsn[1] && off_lo == off_hs && dout[7:0] == hs_pending;

reg  wr_lo_l;
wire bus_stb = wr_lo && !wr_lo_l;   // first clk of each qualified write

reg [7:0] cmd_hi_r, cmd_lo_r, arg_hi_r, arg_lo_r, argb_r;
wire [7:0] argb_eff = off_argb == 5'd0 ? 8'd0 : argb_r;

wire cmd_wr = bus_stb && !hs_sel &&
              ( off_lo == off_cmd_hi || off_lo == off_cmd_lo );

always @(posedge clk) begin
    if( rst ) begin
        wr_lo_l  <= 1'b0;
        cmd_hi_r <= 8'd0;  cmd_lo_r <= 8'd0;
        arg_hi_r <= 8'd0;  arg_lo_r <= 8'd0;  argb_r <= 8'd0;
    end else if( cen ) begin
        wr_lo_l <= wr_lo;
        if( bus_stb && !hs_sel ) begin
            if( off_lo == off_cmd_hi ) cmd_hi_r <= dout[7:0];
            if( off_lo == off_cmd_lo ) cmd_lo_r <= dout[7:0];
            if( off_lo == off_arg_hi ) arg_hi_r <= dout[7:0];
            if( off_lo == off_arg_lo ) arg_lo_r <= dout[7:0];
            if( off_lo == off_argb   ) argb_r   <= dout[7:0];
        end
    end
end

// -------------------------------------------------- classification lookup ---
// Trigger table BRAM: one 32-bit row per command (little-endian pack row:
// [7:0] verb, [15:8] track low, [23:16] gain, [24] suppress,
// [31:28] track high nibble).  Simple dual port: load port + lookup port.
reg  [31:0] trig_mem [0:TRIG_ROWS-1];
reg  [31:0] row_q;

localparam [15:0] ROWS16 = TRIG_ROWS;

wire [15:0] cmd_cur   = { cmd_hi_r, cmd_lo_r };
assign cmd_dbg = cmd_cur;
wire        in_range  = cmd_cur < ROWS16;
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
        if( ctrl_cmd[ci] == cmd_cur ) begin
            ctrl_hit      = 1'b1;
            ctrl_verb_mux = ctrl_vb[ci];
        end
end

// Two-stage registered classification; settles 3 clk after a command byte
// latches (the handshake write is always a later bus cycle — Phase 0:
// record-then-handshake holds on every driver revision observed).
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
        st_ctrl  <= cmd_cur >= ctrl_start;
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
        // settle guard: command changed / tables rewritten
        if( cmd_wr || cfg_we || trig_we ) settle <= 2'd3;
        else if( settle != 2'd0 )         settle <= settle - 2'd1;
    end
end

// ---------------------------------------------------------------- outputs ---
// Combinational gate: all slow terms (cls_sup, lut_valid) are registered
// well before the handshake write; the live terms are the bus qualifiers
// themselves, so the gate covers every clk of the suppressed write cycle.
assign gate = hs_sel && lut_valid && cls_sup && !mode_nogate;

always @(posedge clk) begin
    if( rst ) begin
        evt_stb  <= 1'b0;
        evt_verb <= 3'd0;  evt_track <= 12'd0; evt_gain <= 7'd0;
        evt_argw <= 16'd0; evt_argb  <= 8'd0;
        evt_ctrl <= 1'b0;  evt_sup   <= 1'b0;
        err_unsettled <= 1'b0;
    end else if( cen ) begin
        evt_stb <= 1'b0;
        if( bus_stb && hs_sel ) begin
            if( !lut_valid )
                err_unsettled <= 1'b1;      // fail open: no gate, no event
            else if( cls_verb != 3'd0 ) begin
                evt_stb   <= 1'b1;
                evt_verb  <= cls_verb;
                evt_track <= cls_track;
                evt_gain  <= cls_gain;
                evt_argw  <= { arg_hi_r, arg_lo_r };
                evt_argb  <= argb_eff;
                evt_ctrl  <= cls_ctrl;
                evt_sup   <= cls_sup && !mode_nogate;
            end
        end
    end
end

endmodule
