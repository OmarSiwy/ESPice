// SPDX-License-Identifier: LGPL-3.0
//
// 8-bit SPI master, mode 0 (CPOL=0, CPHA=0).
//
// One SPI bit-period is exactly two clk cycles: data is launched on the
// falling edge of sclk and sampled on the rising edge of sclk.  The MSB of
// `tx_data` shifts out first onto `mosi`; bits arriving on `miso` are
// sampled into `rx_data` in the same MSB-first order.
//
// Used by tests/integration/verilator_spi_master.rs.
//
// Ports
//   clk          : input  — host clock (twice the sclk frequency).
//   rst_n        : input  — active-low synchronous reset.
//   start        : input  — pulse high for one clk cycle to begin a transfer.
//   tx_data[7:0] : input  — byte to transmit, MSB first.
//   rx_data[7:0] : output — byte assembled from miso, MSB first.
//   busy         : output — high while a transfer is in progress.
//   sclk         : output — SPI clock; idle low (CPOL=0).
//   mosi         : output — master-out, slave-in serial data line.
//   miso         : input  — master-in, slave-out serial data line.
//   cs_n         : output — active-low chip select; low for the whole frame.

module spi_master (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] tx_data,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        sclk,
    output reg        mosi,
    input  wire       miso,
    output reg        cs_n
);

    // Bit counter 0..7, decrements as bits are shifted out.
    reg [3:0] bit_cnt;
    // High while we are in the high half of the current SCLK period
    // (i.e. between the rising edge and the next falling edge).
    reg       half;
    reg [7:0] shift_tx;
    reg [7:0] shift_rx;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            sclk     <= 1'b0;
            mosi     <= 1'b0;
            cs_n     <= 1'b1;
            rx_data  <= 8'h00;
            bit_cnt  <= 4'd0;
            half     <= 1'b0;
            shift_tx <= 8'h00;
            shift_rx <= 8'h00;
        end else if (!busy) begin
            // Idle.
            sclk <= 1'b0;
            cs_n <= 1'b1;
            mosi <= 1'b0;
            half <= 1'b0;
            if (start) begin
                busy     <= 1'b1;
                cs_n     <= 1'b0;
                shift_tx <= {tx_data[6:0], 1'b0};
                shift_rx <= 8'h00;
                bit_cnt  <= 4'd8;
                // Launch the first MSB onto mosi during the low half of sclk.
                mosi     <= tx_data[7];
                sclk     <= 1'b0;
                half     <= 1'b0;
            end
        end else begin
            // busy
            if (half == 1'b0) begin
                // Currently in the low half of sclk.  Drive sclk high
                // (the rising edge) and sample miso.
                sclk     <= 1'b1;
                shift_rx <= {shift_rx[6:0], miso};
                half     <= 1'b1;
            end else begin
                // Currently in the high half of sclk.  Drive sclk low
                // (the falling edge) and decide what to do next.
                sclk     <= 1'b0;
                half     <= 1'b0;
                bit_cnt  <= bit_cnt - 4'd1;
                if (bit_cnt == 4'd1) begin
                    // We just sampled the last bit on the previous clk; the
                    // 8-bit transfer is complete on this falling edge.
                    busy    <= 1'b0;
                    cs_n    <= 1'b1;
                    rx_data <= shift_rx;
                    mosi    <= 1'b0;
                end else begin
                    // Shift the next bit out for the upcoming low half.
                    mosi     <= shift_tx[7];
                    shift_tx <= {shift_tx[6:0], 1'b0};
                end
            end
        end
    end

endmodule
