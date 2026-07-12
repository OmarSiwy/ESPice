module dff_neg(input clk, input d, output reg q);
  always @(negedge clk)
    q <= d;
endmodule
