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

          # Patch build scripts to skip Windows-only steps on Linux hosts.
          # RUST_CHECK was used previously for this but it also skips osdi stdlib.c bitcode
          # generation, producing a broken binary. Instead patch each build.rs individually.
          postPatch = ''
            # target/build.rs: skip MSVC ucrt import-lib on non-Windows host
            sed -i 's/if check {/if check || !cfg!(target_os = "windows") {/g' \
              openvaf/target/build.rs
            # osdi/build.rs: skip generating bitcode for MSVC targets on non-Windows host
            sed -i 's/if no_gen {/if no_gen || (target.options.is_like_windows \&\& !cfg!(target_os = "windows")) {/' \
              openvaf/osdi/build.rs
          '';

          buildAndTestSubdir = "openvaf/openvaf-driver";

          buildFeatures = [ "llvm18" ];

          nativeBuildInputs = with pkgs; [ pkg-config ];

          buildInputs = with pkgs; [ llvm_18 libffi libxml2 zlib ];

          # symlinkJoin provides both llvm-config (for llvm-sys) AND unwrapped clang
          # (for osdi/build.rs stdlib.c → bitcode cross-compilation).
          # The wrapped clang adds x86_64-specific Nix flags that break -target riscv64 etc.
          env.LLVM_SYS_181_PREFIX = "${pkgs.symlinkJoin {
            name = "llvm18-prefix";
            paths = [ pkgs.llvm_18.dev pkgs.llvmPackages_18.clang-unwrapped ];
          }}";

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
            ninja
            pkg-config
            python3
            bison
            flex
          ];

          buildInputs = with pkgs; [
            suitesparse   # provides KLU
            openblas
            boost
            tomlplusplus
          ];

          postPatch = ''
            # Remove Boost_NO_SYSTEM_PATHS so nix-installed boost is found.
            sed -i 's/set(Boost_NO_SYSTEM_PATHS TRUE)//' CMakeLists.txt
            # Remove version req (nixpkgs has 1.89) and drop 'system' component
            # (boost_system is header-only in boost ≥1.87, no libboost_system.so).
            sed -i 's/find_package(Boost 1.88 REQUIRED COMPONENTS filesystem process system)/find_package(Boost REQUIRED COMPONENTS filesystem process)/' CMakeLists.txt
            # Fix Boost extra link dir: cmake-found lib dir instead of manual build stage path.
            sed -i 's|set(Boost_EXTRA_LINK_DIR "''${Boost_INCLUDE_DIRS}/stage/lib")|set(Boost_EXTRA_LINK_DIR "''${Boost_LIBRARY_DIRS}")|' CMakeLists.txt
            # Remove boost_system from link libs (header-only, no .so).
            sed -i 's/boost_system boost_filesystem boost_process/boost_filesystem boost_process/' CMakeLists.txt
            # nixpkgs suitesparse puts klu.h directly in include/, not include/suitesparse/
            sed -i 's|suitesparse/klu.h|klu.h|g' include/klumatrix.h
          '';

          cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DOPENVAF_DIR=${openvafPkg}/bin"
            "-DTOMLPP_DIR=${pkgs.tomlplusplus}"
            "-DSuiteSparse_DIR=${pkgs.suitesparse}"
          ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            # The simulator binary is built into the simulator/ subdirectory.
            cp simulator/vacask $out/bin/vacask
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
          rustStable
          pkg-config
          openssl

          # Linker
          mold
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
            echo "BigOSpice dev shell — stable Rust $(rustc --version) + mold linker"
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
            mold
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
