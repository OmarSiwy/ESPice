module sv_always_comb(input logic [3:0] a, input logic [3:0] b,
                      output logic [3:0] max, output logic ge);
  always_comb begin
    ge  = (a >= b);
    max = (a >= b) ? a : b;
  end
endmodule
