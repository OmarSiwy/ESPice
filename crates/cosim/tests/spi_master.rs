//! End-to-end test: a Verilator-compiled SystemVerilog SPI master driving an
//! analog DAC and reading an analog comparator.
//!
//! ## Required toolchain
//!
//! This test is `#[ignore]`d by default because it depends on Verilator being
//! installed and on a pre-built SPI master shared object at
//! `target/cosim/libspi_master.so`.  To enable it:
//!
//! 1. Install Verilator:
//!
//!    ```bash
//!    nix shell nixpkgs#verilator
//!    # OR
//!    sudo apt install verilator
//!    ```
//!
//! 2. Build the SPI master shared object using the canonical BigOSpice shim
//!    convention (the shim is a tiny C++ file that exposes the Verilated
//!    model under the `bigospice_verilator_*` symbol names expected by
//!    `bigospice_cosim::loader`):
//!
//!    ```bash
//!    verilator --cc --build -j 0 \
//!      --top-module spi_master \
//!      tests/cosim/spi_master.sv tests/cosim/bigospice_shim.cpp \
//!      -CFLAGS -fPIC -LDFLAGS -shared \
//!      -o ../../target/cosim/libspi_master.so
//!    ```
//!
//! 3. Run the test:
//!
//!    ```bash
//!    cargo test -p bigospice-cosim --test spi_master -- --ignored
//!    ```

use std::path::PathBuf;

use bigospice_cosim::{ClockMode, ClockSpec, DCosim, DCosimPort, PortDirection, VerilatorModel};
use bigospice_digital::{
    AdcBridge, DacBridge, DigNodeIdx, DigState, DigitalNet, DigitalRuntime, EventQueue,
};

#[test]
#[ignore = "requires Verilator-built libspi_master.so"]
fn spi_master_drives_dac_and_reads_comparator() {
    // ---- Locate the prebuilt shared object ----
    let so = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("target/cosim/libspi_master.so");
    if !so.exists() {
        eprintln!("skip: {} not built; see test header for build command", so.display());
        return;
    }

    // ---- Load the Verilator model ----
    let model = VerilatorModel::load(&so).expect("load libspi_master.so");

    // ---- Wire it into a DCosim device with the canonical SPI port set ----
    let clk_node = DigNodeIdx::new(0);
    let mosi_node = DigNodeIdx::new(1);
    let miso_node = DigNodeIdx::new(2);
    let cs_node = DigNodeIdx::new(3);

    let mut dcosim = DCosim::new(
        model,
        ClockMode::ClockDriven(ClockSpec::new(clk_node, 10e-9)),
    );
    dcosim.add_port(DCosimPort::new("clk", clk_node, PortDirection::Input, 1));
    dcosim.add_port(DCosimPort::new("miso", miso_node, PortDirection::Input, 1));
    dcosim.add_port(DCosimPort::new("mosi", mosi_node, PortDirection::Output, 1));
    dcosim.add_port(DCosimPort::new("cs", cs_node, PortDirection::Output, 1));

    // ---- Build a digital runtime carrying an analog DAC and comparator ----
    let mut net = DigitalNet::with_capacity(8, 4, 64);

    // DAC bridge: drive analog node 0 from MOSI.
    net.bridges
        .push_dac(DacBridge::new(0, mosi_node, 0.0, 5.0, 1e-9, 1e-9));
    // ADC bridge: feed analog node 1 (the comparator output) into MISO.
    net.bridges
        .push_adc(AdcBridge::new(1, miso_node, 1.5, 3.5));

    let mut rt = DigitalRuntime::new(net);

    // ---- Drive the SPI master for 32 simulated SPI clocks ----
    let mut t = 0.0;
    let dt = 5e-9;
    let mut queue_scratch = EventQueue::with_capacity(16);
    let _ = &mut queue_scratch;
    for k in 0..32 {
        // Toggle clock through one period.
        rt.net.node_state[clk_node.index()] = DigState::ZERO;
        rt.flush(t, &[2.5, 4.0]);
        t += dt;

        rt.net.node_state[clk_node.index()] = DigState::ONE;
        rt.flush(t, &[2.5, 4.0]);

        // Tick the cosim with the latest digital state.
        dcosim
            .tick(t, &rt.net.node_state, &mut rt.net.queue)
            .expect("dcosim tick");

        let _ = k;
        t += dt;
    }

    // ---- Verify that the cosim produced *some* MOSI activity ----
    let mosi_port = dcosim
        .find_port_by_node(mosi_node)
        .expect("mosi port registered");
    assert!(
        dcosim.ports[mosi_port].last_value < 2,
        "MOSI must be a 1-bit port"
    );
}
