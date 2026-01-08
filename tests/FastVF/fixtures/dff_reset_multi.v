module dff_reset_multi(input clk, input rst, input [3:0] d,
                       output reg [3:0] q, output reg flag);
  always @(posedge clk)
    if (rst) begin q <= 4'd0; flag <= 1'b0; end
    else     begin q <= d;    flag <= 1'b1; end
endmodule
