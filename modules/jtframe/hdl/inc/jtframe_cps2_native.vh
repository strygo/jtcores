// Native-only CPS2 capacity profile. Included inside both loader modules.
// Generated metadata is checked against the executable image_format.py gate.
`ifdef CPS2_NATIVE128
`ifndef CPS2_GFX64
    `CPS2_NATIVE128_requires_CPS2_GFX64
`endif
localparam [26:0] NATIVE_END = 27'd92545152;
function [7:0] native_expected;
    input [6:0] address;
    reg [31:0] word_value;
    begin
        case(address[6:2])
            5'd0: word_value = 32'h21002000;
            5'd1: word_value = 32'h61006108;
            5'd2: word_value = 32'h00000000;
            5'd3: word_value = 32'h07023243;
            5'd16: word_value = 32'h58453243;
            5'd17: word_value = 32'h00400002;
            5'd18: word_value = 32'h00000080;
            5'd19: word_value = 32'h00800000;
            5'd20: word_value = 32'h00800080;
            5'd21: word_value = 32'h00040000;
            5'd22: word_value = 32'h00840080;
            5'd23: word_value = 32'h01000000;
            5'd24: word_value = 32'h01840080;
            5'd25: word_value = 32'h00002000;
            5'd26: word_value = 32'h01842080;
            5'd27: word_value = 32'h04000000;
            5'd28: word_value = 32'h05842080;
            5'd29: word_value = 32'h00000000;
            5'd30: word_value = 32'h00000000;
            5'd31: word_value = 32'h00000000;
            default: word_value = 0; // configuration/keys are unconstrained
        endcase
        native_expected = word_value[{address[1:0],3'b000}+:8];
    end
endfunction
`ifdef CPS2_QSND32
`ifndef CPS2_QSND24
    `CPS2_QSND32_requires_CPS2_QSND24
`endif
localparam [26:0] NATIVE32_END = 27'd109322368;
function [7:0] native_expected_profile;
    input [6:0] address;
    input wide;
    reg [31:0] word_value;
    begin
        case(address[6:2])
            5'd0: word_value = 32'h21002000;
            5'd1: word_value = 32'ha100a108;
            5'd2: word_value = 32'h00000000;
            5'd3: word_value = 32'h07033243;
            5'd16: word_value = 32'h58453243;
            5'd17: word_value = 32'h00400003;
            5'd18: word_value = 32'h00000080;
            5'd19: word_value = 32'h00800000;
            5'd20: word_value = 32'h00800080;
            5'd21: word_value = 32'h00040000;
            5'd22: word_value = 32'h00840080;
            5'd23: word_value = 32'h02000000;
            5'd24: word_value = 32'h02840080;
            5'd25: word_value = 32'h00002000;
            5'd26: word_value = 32'h02842080;
            5'd27: word_value = 32'h04000000;
            5'd28: word_value = 32'h06842080;
            5'd29: word_value = 32'h00000000;
            5'd30: word_value = 32'h00000000;
            5'd31: word_value = 32'h00000000;
            default: word_value = 0;
        endcase
        native_expected_profile = wide ? word_value[{address[1:0],3'b000}+:8] : native_expected(address);
    end
endfunction
`endif
function native_fixed;
    input [6:0] address;
    begin native_fixed = address < 16 || address >= 64; end
endfunction
`endif
