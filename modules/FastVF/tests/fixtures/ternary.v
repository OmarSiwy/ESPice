module ternary(input sel, input a, input b, output y);
  assign y = sel ? a : b;
endmodule
