// One-bit full adder: s = a + b + cin, two bits wide.
module v_add(input a, input b, input cin, output [1:0] s);
  assign s = a + b + cin;
endmodule
