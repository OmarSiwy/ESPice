module concat_test(input [3:0] hi, input [3:0] lo, output [7:0] y);
  assign y = {hi, lo};
endmodule
