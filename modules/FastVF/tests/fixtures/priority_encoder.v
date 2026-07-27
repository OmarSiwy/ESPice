module priority_encoder(input [3:0] req, output reg [1:0] grant, output reg valid);
  always @(*) begin
    if (req[3])      begin grant = 2'd3; valid = 1'b1; end
    else if (req[2]) begin grant = 2'd2; valid = 1'b1; end
    else if (req[1]) begin grant = 2'd1; valid = 1'b1; end
    else if (req[0]) begin grant = 2'd0; valid = 1'b1; end
    else             begin grant = 2'd0; valid = 1'b0; end
  end
endmodule
