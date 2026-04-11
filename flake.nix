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

        rustNightly = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };

        # NOTE: VACASK SHA and hash are PLACEHOLDERS — fill them in before using .#full.
        # GitHub mirror: https://github.com/robtaylor/VACASK
        # To get the values:
        #   SHA=$(curl -s https://api.github.com/repos/robtaylor/VACASK/commits/main \
        #           | grep -m1 '"sha"' | cut -d'"' -f4)
        #   nix-prefetch-url --unpack \
        #     "https://github.com/robtaylor/VACASK/archive/${SHA}.tar.gz"
        # Then replace rev and hash below.
        vacaskPkg = pkgs.stdenv.mkDerivation rec {
          pname = "vacask";
          version = "unstable-2026";

          src = pkgs.fetchFromGitHub {
            owner = "robtaylor";
            repo = "VACASK";
            rev = "PLACEHOLDER_SHA_REPLACE_ME";
            hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            pkg-config
          ];

          buildInputs = with pkgs; [
            suitesparse   # provides KLU
            openblas
          ];

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
          ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            # VACASK produces a 'vacask' binary in the build directory
            cp vacask $out/bin/vacask
            runHook postInstall
          '';

          meta = {
            description = "VACASK – Verilog-A Circuit Analysis Kernel";
            homepage = "https://github.com/robtaylor/VACASK";
            license = pkgs.lib.licenses.gpl2Plus;
            platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
          };
        };

        commonInputs = with pkgs; [
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
            echo "BigOSpice dev shell — nightly Rust $(rustc --version) + mold linker"
            echo "Tip: use 'nix develop .#full' to get ngspice, xyce, and VACASK"
          '';

          SUITESPARSE_DIR = "${pkgs.suitesparse}";
          OPENBLAS_DIR = "${pkgs.openblas}";
        };

        devShells.full = pkgs.mkShell {
          buildInputs = commonInputs ++ [
            pkgs.ngspice
            # NOTE: pkgs.xyce-parallel may not be available in nixpkgs-unstable.
            # If evaluation fails, comment out the line below.
            pkgs.xyce-parallel
            vacaskPkg
          ];

          shellHook = ''
            export RUST_BACKTRACE=1
            export RUST_LOG=bigospice=debug
            export BIGOSPICE_HAVE_SIMS=1
            echo "BigOSpice FULL dev shell — nightly Rust $(rustc --version)"
            echo "Simulators: ngspice $(ngspice --version 2>&1 | head -1)"
            echo "            xyce    $(xyce --version 2>&1 | head -1)"
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
