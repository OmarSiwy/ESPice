{
  description = "VAICS - Vectorized Incremental Analog Circuit Simulator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustNightly = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustNightly
            pkg-config
            openssl

            # Linker
            mold-wrapped
            clang

            # Linear algebra
            suitesparse
            openblas
            lapack

            # Build tools
            cmake
            gnumake

            # Dev tools
            cargo-watch
            cargo-nextest
            cargo-tarpaulin
            cargo-flamegraph
            cargo-expand

            # Benchmarks
            hyperfine

            # Reference simulators for head-to-head validation
            ngspice
            xyce-parallel  # 7.9.0, pre-built in cache

            # Mixed-signal cosimulation
            verilator
            verible # SystemVerilog parser/lint (optional but handy)
          ];

          shellHook = ''
            export RUST_BACKTRACE=1
            export RUST_LOG=pisim=debug
            echo "VAICS dev shell — nightly Rust $(rustc --version) + mold linker"
          '';

          SUITESPARSE_DIR = "${pkgs.suitesparse}";
          OPENBLAS_DIR = "${pkgs.openblas}";
        };

        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "vaics";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = with pkgs; [
            pkg-config
            cmake
            mold-wrapped
            clang
          ];
          buildInputs = with pkgs; [
            suitesparse
            openblas
            lapack
            openssl
          ];
        };
      }
    );
}
