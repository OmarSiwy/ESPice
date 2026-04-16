{
  description = "BigOSpice - Vectorized Incremental Analog Circuit Simulator";

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

        rustStable = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };

        openvafPkg = import ./nix/openvaf.nix { inherit pkgs; };
        vacaskPkg = import ./nix/vacask.nix { inherit pkgs openvafPkg; };
        # Parallel MPI build; set fromSource = true if nixpkgs xyce-parallel crashes
        xcyePkg = import ./nix/xyce.nix { inherit pkgs; };

        commonInputs = with pkgs; [
          rustStable
          pkg-config
          openssl

          # Linker
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

          # Mixed-signal cosimulation
          verilator
          verible
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = commonInputs;

          shellHook = ''
            export RUST_BACKTRACE=1
            export RUST_LOG=bigospice=debug
            echo "BigOSpice dev shell — stable Rust $(rustc --version)"
            echo "Tip: use 'nix develop .#full' to get ngspice, xyce, and VACASK"
          '';

          SUITESPARSE_DIR = "${pkgs.suitesparse}";
          OPENBLAS_DIR = "${pkgs.openblas}";
        };

        devShells.full = pkgs.mkShell {
          buildInputs = commonInputs ++ [
            pkgs.ngspice
            xcyePkg
            vacaskPkg
          ];

          shellHook = ''
            export RUST_BACKTRACE=1
            export RUST_LOG=bigospice=debug
            export BIGOSPICE_HAVE_SIMS=1
            echo "BigOSpice FULL dev shell — stable Rust $(rustc --version)"
            echo "Simulators: ngspice $(ngspice --version 2>&1 | head -1)"
            echo "            vacask  $(vacask --version 2>&1 | head -1 || echo 'available')"
          '';

          SUITESPARSE_DIR = "${pkgs.suitesparse}";
          OPENBLAS_DIR = "${pkgs.openblas}";
        };

        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "bigospice";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = with pkgs; [
            pkg-config
            cmake
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
