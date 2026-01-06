module arith(input [7:0] a, input [7:0] b, output [7:0] sum, output [7:0] diff, output [7:0] prod);
  assign sum  = a + b;
  assign diff = a - b;
  assign prod = a * b;
endmodule
