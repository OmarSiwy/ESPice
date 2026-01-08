module latch_en(input en, input d, output reg q);
  always @(*)
    if (en) q = d;
endmodule
