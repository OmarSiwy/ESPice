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

        # OpenVAF-reloaded: the Verilog-A compiler required by VACASK.
        # Binary produced: openvaf-r (from the openvaf-driver crate).
        # LLVM 18 is used (available in nixpkgs as llvm_18).
        openvafPkg = pkgs.rustPlatform.buildRustPackage rec {
          pname = "openvaf-r";
          version = "unstable-2026";

          src = pkgs.fetchFromGitHub {
            owner = "arpadbuermen";
            repo = "OpenVAF";
            rev = "2e066436d985b05cf8e6563e936daf9ab875775a";
            hash = "sha256-AXtp8qaDq/MRYz2TYXRwT3kS+8EnKyakD3lQwdv3K34=";
          };

          cargoLock = {
            lockFile = ./nix/openvaf-Cargo.lock;
            outputHashes = {
              "salsa-0.17.0-pre.2" = "sha256-6GssvV76lFr5OzAUekz2h6f82Tn7usz5E8MSZ5DmgJw=";
            };
          };

          buildAndTestSubdir = "openvaf/openvaf-driver";

          buildFeatures = [ "llvm18" ];

          nativeBuildInputs = with pkgs; [ pkg-config ];

          buildInputs = with pkgs; [ llvm_18 libffi libxml2 zlib ];

          env.LLVM_SYS_181_PREFIX = "${pkgs.llvm_18.dev}";
          # Skip Windows UCRT import-lib generation in openvaf/target/build.rs
          # (Linux builds don't need MSVC target stubs)
          env.RUST_CHECK = "1";

          doCheck = false;

          # Only install the openvaf-r binary
          postInstall = ''
            find $out/bin -type f ! -name "openvaf-r" -delete 2>/dev/null || true
          '';

          meta = {
            description = "OpenVAF-reloaded: Verilog-A compiler for VACASK";
            homepage = "https://github.com/arpadbuermen/OpenVAF";
            license = pkgs.lib.licenses.gpl3Only;
            platforms = pkgs.lib.platforms.linux;
          };
        };

        vacaskPkg = pkgs.stdenv.mkDerivation rec {
          pname = "vacask";
          version = "unstable-2026";

          src = pkgs.fetchFromGitHub {
            owner = "robtaylor";
            repo = "VACASK";
            rev = "bcd48e2dd25182f5aaa3392c4e27b4e198372744";
            hash = "sha256-/x6yJ+fklipvYbtI5rHx4d5YIpC9IJ5uhHCtWC5eJJg=";
          };

          nativeBuildInputs = with pkgs; [
            cmake
            pkg-config
            python3
            bison
            flex
          ];

          buildInputs = with pkgs; [
            suitesparse   # provides KLU
            openblas
            boost
          ];

          postPatch = ''
            # Boost ≥1.87: boost_system is header-only — drop it from components.
            # Also remove Boost_NO_SYSTEM_PATHS so nix-installed boost is found.
            sed -i 's/set(Boost_NO_SYSTEM_PATHS TRUE)//' CMakeLists.txt
            sed -i 's/find_package(Boost 1.88 REQUIRED COMPONENTS filesystem process system)/find_package(Boost REQUIRED COMPONENTS filesystem)/' CMakeLists.txt
            sed -i '/Boost_EXTRA_LINK_DIR/d' CMakeLists.txt
            # nixpkgs suitesparse puts klu.h directly in include/, not include/suitesparse/
            sed -i 's|suitesparse/klu.h|klu.h|g' include/klumatrix.h
          '';

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DOPENVAF_DIR=${openvafPkg}/bin"
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
            # pkgs.xyce-parallel
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
