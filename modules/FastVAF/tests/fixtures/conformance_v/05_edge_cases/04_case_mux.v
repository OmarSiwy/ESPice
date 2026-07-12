module case_mux(input [1:0] sel, input a, input b, input c, input d, output reg y);
  always @(*) begin
    case (sel)
      2'b00: y = a;
      2'b01: y = b;
      2'b10: y = c;
      default: y = d;
    endcase
  end
endmodule
