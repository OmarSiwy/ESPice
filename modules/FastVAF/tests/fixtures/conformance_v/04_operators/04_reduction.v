module reduction(input [3:0] a, output y_or, output y_and, output y_xor);
  assign y_or  = |a;
  assign y_and = &a;
  assign y_xor = ^a;
endmodule
