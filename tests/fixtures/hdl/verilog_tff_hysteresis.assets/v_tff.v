`timescale 1ns/1ps
// Toggle flip-flop: q flips on every rising edge of clk.
module v_tff(input clk, output reg q);
  initial q = 1'b0;
  always @(posedge clk) q <= ~q;
endmodule
