module sv_logic_ff(input logic clk, input logic rst_n, input logic [3:0] d,
                   output logic [3:0] q);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= '0;
    else        q <= d;
  end
endmodule
