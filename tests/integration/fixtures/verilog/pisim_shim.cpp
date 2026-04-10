// SPDX-License-Identifier: LGPL-3.0
//
// PiSIM ↔ Verilator C-ABI shim for the spi_master fixture.
//
// Exposes the canonical `pisim_verilator_*` symbol set that
// `crates/cosim/src/loader.rs` expects:
//
//   pisim_verilator_new        () -> void*
//   pisim_verilator_eval       (void*)
//   pisim_verilator_final      (void*)
//   pisim_verilator_set_signal (void*, const char* name, uint64_t value)
//   pisim_verilator_get_signal (void*, const char* name) -> uint64_t
//
// The shim is intentionally minimal — no contexts, no DPI exports — and
// dispatches port names to the corresponding fields on the generated
// `Vspi_master` C++ class.

#include "Vspi_master.h"

#include <cstdint>
#include <cstring>

namespace {

// Symbol-table dispatch keeps the loader generic and makes the test
// independent of Verilator's class layout.
inline Vspi_master* as_top(void* ctx) {
    return reinterpret_cast<Vspi_master*>(ctx);
}

} // namespace

extern "C" {

void* pisim_verilator_new() {
    return new Vspi_master{};
}

void pisim_verilator_eval(void* ctx) {
    if (ctx == nullptr) return;
    as_top(ctx)->eval();
}

void pisim_verilator_final(void* ctx) {
    if (ctx == nullptr) return;
    as_top(ctx)->final();
    delete as_top(ctx);
}

void pisim_verilator_set_signal(void* ctx, const char* name, std::uint64_t value) {
    if (ctx == nullptr || name == nullptr) return;
    auto* top = as_top(ctx);
    if      (std::strcmp(name, "clk")     == 0) top->clk     = static_cast<std::uint8_t>(value & 1);
    else if (std::strcmp(name, "rst_n")   == 0) top->rst_n   = static_cast<std::uint8_t>(value & 1);
    else if (std::strcmp(name, "start")   == 0) top->start   = static_cast<std::uint8_t>(value & 1);
    else if (std::strcmp(name, "tx_data") == 0) top->tx_data = static_cast<std::uint8_t>(value & 0xFF);
    else if (std::strcmp(name, "miso")    == 0) top->miso    = static_cast<std::uint8_t>(value & 1);
}

std::uint64_t pisim_verilator_get_signal(void* ctx, const char* name) {
    if (ctx == nullptr || name == nullptr) return 0;
    auto* top = as_top(ctx);
    if      (std::strcmp(name, "rx_data") == 0) return top->rx_data;
    else if (std::strcmp(name, "busy")    == 0) return top->busy;
    else if (std::strcmp(name, "sclk")    == 0) return top->sclk;
    else if (std::strcmp(name, "mosi")    == 0) return top->mosi;
    else if (std::strcmp(name, "cs_n")    == 0) return top->cs_n;
    else if (std::strcmp(name, "clk")     == 0) return top->clk;
    else if (std::strcmp(name, "rst_n")   == 0) return top->rst_n;
    else if (std::strcmp(name, "start")   == 0) return top->start;
    else if (std::strcmp(name, "tx_data") == 0) return top->tx_data;
    else if (std::strcmp(name, "miso")    == 0) return top->miso;
    return 0;
}

} // extern "C"
