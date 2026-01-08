module dff_arst_n(input clk, input rst_n, input [3:0] d, output reg [3:0] q);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= 4'd0;
    else        q <= d;
endmodule
