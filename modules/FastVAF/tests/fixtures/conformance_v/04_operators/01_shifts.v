module shifter(input [7:0] a, input [2:0] amt, output [7:0] shl_out, output [7:0] shr_out);
  assign shl_out = a << amt;
  assign shr_out = a >> amt;
endmodule
