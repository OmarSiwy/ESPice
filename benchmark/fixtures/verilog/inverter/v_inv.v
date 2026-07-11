// Digital Verilog inverter: a=5V (logic 1) -> y drives low against the 10k load.
module v_inv(input a, output y);
  assign y = ~a;
endmodule
