module dff_sync_reset(input clk, input rst, input d, output reg q);
  always @(posedge clk)
    if (rst) q <= 1'b0;
    else     q <= d;
endmodule
