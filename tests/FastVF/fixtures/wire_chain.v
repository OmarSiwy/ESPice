module wire_chain(input a, input b, input c, output y);
  wire n2;
  wire n1;
  assign y  = n2 ^ c;
  assign n2 = n1 | b;
  assign n1 = a & b;
endmodule
