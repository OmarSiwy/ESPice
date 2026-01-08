module counter_en(input clk, input en, output reg [3:0] count);
  always @(posedge clk)
    if (en) count <= count + 1'b1;
endmodule
