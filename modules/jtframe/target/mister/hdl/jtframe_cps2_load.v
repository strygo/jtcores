// CPS-2 staged loader. GPL-3.0-or-later, like the surrounding JTFRAME code.
// Native transport remains in jtframe_mister_dwnld; this module owns music
// activation and the CPU startup fence, never ROM mapping or music decoding.
module jtframe_cps2_load #(
    parameter [33:0] SESSION_TIMEOUT = 34'd11520000000, // 120 s at 96 MHz
    parameter [26:0] PACK_TIMEOUT = 27'd96000000        // 1 s at 96 MHz
)(
    input clk, rst, game_rst,
    input hps_download, hps_wr,
    input [7:0] hps_index, hps_dout,
    input [26:0] hps_addr,
    input [31:0] hps_length,
    input native_loading, native_busy, copy_busy, native_image,
    input [3:0] native_error,
    input music_idle, music_ready,
    input [3:0] music_status,
    output hps_wait, game_hold, music_reset,
    output reg music_boot,
    output reg music_indirect,
    output reg [31:0] music_extent,
    output reg [3:0] load_status
);
localparam [3:0] IDLE=0, NATIVE=1, SESSION=2, BOOT_WAIT=3,
                 BOOT=4, CHECK=5, RUN_NATIVE=6, RUN_MUSIC=7, FAILED=8;
localparam [5:0] IDX_ROM=0, IDX_PACK=3, IDX_CONTROL=5;
reg [3:0] state;
reg last_download;
reg [7:0] transfer_index;
reg [63:0] control;
reg [3:0] control_count;
reg control_bad;
reg session_open, expected_pack, protocol_bad;
reg native_seen, native_available, pack_seen;
reg [31:0] rom_extent, pack_extent;
reg [33:0] session_ticks;
reg [26:0] pack_ticks;
reg [2:0] reset_settled;
reg [1:0] boot_delay;
wire transfer_start = hps_download && !last_download;
wire transfer_end = !hps_download && last_download;
wire new_rom = transfer_start && hps_index[5:0]==IDX_ROM;
wire new_pack = transfer_start && hps_index[5:0]==IDX_PACK;
wire overwrite = hps_download && (hps_index[5:0]==IDX_ROM || hps_index[5:0]==IDX_PACK);
wire native_ok = native_available ||
    (native_seen && !native_loading && !native_busy && !copy_busy && native_error==0);
wire control_end = transfer_end && transfer_index[5:0]==IDX_CONTROL;
wire control_valid = !control_bad && control_count==8 && hps_addr==8 &&
    control[31:0]==32'h4c325043 && control[39:32]==1 && control[63:56]==0 &&
    (control[47:40]==1 ? control[55:48]<=1 :
     control[47:40]==2 && control[55:48]==0);
wire pack_extent_ok = pack_seen && pack_extent>=4096 && pack_extent<=32'h10000000;

// Stop requests before the host reaches shmem_put. Accepted reads drain in
// the arbiter even while the player is reset; reset does not cancel DDR beats.
assign hps_wait = overwrite && (!(&reset_settled) || !music_idle || copy_busy);
assign game_hold = overwrite || !native_available ||
    (state!=RUN_NATIVE && state!=RUN_MUSIC);
assign music_reset = rst || game_rst || overwrite ||
    (state!=BOOT && state!=CHECK && state!=RUN_MUSIC);

always @(posedge clk) begin
    if(rst) begin
        state<=IDLE; last_download<=0; transfer_index<=0;
        control<=0; control_count<=0; control_bad<=0;
        session_open<=0; expected_pack<=0; protocol_bad<=0;
        native_seen<=0; native_available<=0; pack_seen<=0;
        rom_extent<=0; pack_extent<=0; music_extent<=0;
        music_indirect<=1; music_boot<=0; load_status<=0;
        session_ticks<=0; pack_ticks<=0; reset_settled<=0; boot_delay<=0;
    end else begin
        // cpsplus_top distributes reset through two registers. Wait three
        // clocks before trusting idle, including a possible last accepted read.
        reset_settled<=music_reset ? {reset_settled[1:0],1'b1} : 3'd0;
        last_download<=hps_download;
        music_boot<=0;
        if(native_loading) native_seen<=1;
        if(native_ok) native_available<=1;
        if(transfer_start) begin
            transfer_index<=hps_index;
            if(hps_index[5:0]==IDX_CONTROL) begin
                control<=0; control_count<=0; control_bad<=0;
            end
        end
        if(hps_wr && hps_download && transfer_index[5:0]==IDX_CONTROL) begin
            if(control_count>=8 || hps_addr!={23'd0,control_count}) control_bad<=1;
            else begin
                control[control_count*8+:8]<=hps_dout;
                control_count<=control_count+1'b1;
            end
        end
        if(transfer_end && transfer_index[5:0]==IDX_ROM) rom_extent<=hps_length;
        if(transfer_end && transfer_index[5:0]==IDX_PACK) begin
            pack_extent<=hps_length;
            pack_seen<=session_open && expected_pack && native_ok && !protocol_bad;
        end

        if(control_end) begin
            if(control_valid && control[47:40]==1) begin
                session_open<=1; expected_pack<=control[48];
                protocol_bad<=0; native_seen<=0; native_available<=0; pack_seen<=0;
                rom_extent<=0; pack_extent<=0; music_extent<=0;
                session_ticks<=0; load_status<=1; state<=SESSION;
            end else if(control_valid && control[47:40]==2 && session_open) begin
                session_open<=0;
                if(!native_ok || native_error!=0 || native_loading || copy_busy) begin
                    load_status<=8; state<=FAILED;
                end else if(expected_pack && pack_extent_ok && !protocol_bad) begin
                    music_extent<=pack_extent; music_indirect<=0;
                    load_status<=1; state<=BOOT_WAIT;
                end else begin
                    load_status<=protocol_bad ? 4'd8 :
                                 expected_pack ? (pack_seen ? 4'd6 : 4'd4) : 4'd0;
                    state<=RUN_NATIVE;
                end
            end else begin
                protocol_bad<=1; session_open<=0; load_status<=8;
                state<=native_ok ? RUN_NATIVE : FAILED;
            end
        end else if(new_rom) begin
            native_seen<=0; native_available<=0; pack_seen<=0;
            rom_extent<=0; pack_extent<=0; music_extent<=0;
            protocol_bad<=0;
            if(!session_open) expected_pack<=0;
            load_status<=1; state<=NATIVE;
        end else if(new_pack) begin
            pack_seen<=0; pack_extent<=0; session_ticks<=0;
            if(!session_open || !expected_pack || !native_ok) protocol_bad<=1;
            state<=SESSION;
        end else if(native_error!=0 && state!=IDLE) begin
            native_available<=0; load_status<=9; state<=FAILED;
        end else case(state)
            NATIVE: if(native_ok && !hps_download && !transfer_end) begin
                if(session_open) begin
                    session_ticks<=0; state<=SESSION;
                end else if(native_image || rom_extent==0) begin
                    load_status<=0; state<=RUN_NATIVE;
                end else begin
                    music_indirect<=1; music_extent<=rom_extent;
                    state<=BOOT_WAIT;
                end
            end
            SESSION: if(native_ok && !hps_download) begin
                if(!session_open) begin
                    load_status<=8; state<=RUN_NATIVE;
                end else if(session_ticks>=SESSION_TIMEOUT) begin
                    session_open<=0; load_status<=7; state<=RUN_NATIVE;
                end else session_ticks<=session_ticks+1'b1;
            end
            BOOT_WAIT: if(!game_rst && (&reset_settled) && music_idle && !native_busy && !copy_busy) begin
                pack_ticks<=0; boot_delay<=0; state<=BOOT;
            end
            BOOT: if(boot_delay==2) begin music_boot<=1; state<=CHECK; end
                  else boot_delay<=boot_delay+1'b1;
            CHECK: begin
                if(game_rst) state<=BOOT_WAIT;
                else if(music_ready) begin load_status<=2; state<=RUN_MUSIC; end
                else if(music_status>=4) begin load_status<=music_status; state<=RUN_NATIVE; end
                else if(pack_ticks>=PACK_TIMEOUT) begin load_status<=7; state<=RUN_NATIVE; end
                else pack_ticks<=pack_ticks+1'b1;
            end
            RUN_MUSIC: begin
                if(game_rst) state<=BOOT_WAIT;
                else if(!music_ready && music_status>=4) begin
                    load_status<=music_status; state<=RUN_NATIVE;
                end
            end
            default: ;
        endcase
    end
end
endmodule
