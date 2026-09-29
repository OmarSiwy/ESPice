`timescale 1ns/1ps
// One 50 ns pulse starting at 10 ns.
module v_pulse(output reg y);
  initial begin
    y = 1'b0;
    #10 y = 1'b1;
    #50 y = 1'b0;
  end
endmodule
