module decoder2to4(input [1:0] sel, output [3:0] y);
  assign y = 4'b0001 << sel;
endmodule
