{
  description = "ARPice";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        zig = zig-overlay.packages.${system}."0.16.0";
        verilator = pkgs.verilator;
        sv2v = pkgs.haskellPackages.sv2v;
        # VHDL front-end: `ghdl synth --out=verilog` lowers VHDL to Verilog,
        # which then takes the same verilator path as every other HDL input.
        ghdl = pkgs.ghdl;
        mineruPython = pkgs.python313;

        commonInputs = [
          zig
          verilator
          sv2v
          ghdl
        ];

        # CUDA toolkit (headers, nvcc, profiler, cuda-gdb, nvidia-smi stub)
        cudaPkgs = with pkgs.cudaPackages; [
          cudatoolkit # nvcc, headers, libs, nvidia-smi
          cuda_cudart # runtime (libcudart)
          cuda_nvcc # compiler driver
        ];

        # ROCm / HIP (compiler, runtime, monitoring)
        rocmPkgs = with pkgs.rocmPackages; [
          clr # HIP runtime (libamdhip64)
          hipcc # HIP compiler
          rocminfo # device query
          rocm-smi # GPU monitoring
          hip-common # headers
        ];

        # LD_LIBRARY_PATH: system driver + nix-packaged CUDA/ROCm runtime
        gpuLibPath = pkgs.lib.makeLibraryPath ([
          "/run/opengl-driver" # NixOS NVIDIA driver (libcuda.so.1)
        ] ++ cudaPkgs ++ rocmPkgs);

        # Simulator packages for benchmarking
        openvafPkg = import ./nix/oepnvaf.nix { inherit pkgs; };
        vacaskPkg = import ./nix/vacask.nix { inherit pkgs; openvafPkg = openvafPkg; };
        xycePkg = import ./nix/xyce.nix { inherit pkgs; };

        commonEnv = {
          VERILATOR_ROOT = "${verilator}/share/verilator";
        };
      in
      {
        # Default dev shell: build tools + llc + CUDA/ROCm toolchains.
        devShells.default = pkgs.mkShell (
          commonEnv
          // {
            packages = commonInputs ++ [
              pkgs.llvmPackages_21.llvm # llc for nvptx kernel pipeline
            ] ++ cudaPkgs ++ rocmPkgs;
            LD_LIBRARY_PATH = gpuLibPath;
          }
        );

        # Benchmarking: adds ngspice + perf + flamegraph on top.
        devShells.benchmarking = pkgs.mkShell (
          commonEnv
          // {
            packages = commonInputs ++ [
              pkgs.ngspice
              pkgs.gnucap
              openvafPkg
              vacaskPkg
              xycePkg
              pkgs.perf
              pkgs.flamegraph
              pkgs.inferno
              pkgs.llvmPackages_21.llvm
            ] ++ cudaPkgs ++ rocmPkgs;
            LD_LIBRARY_PATH = gpuLibPath;
          }
        );

        # PDF-to-Markdown extraction for the Verilog-AMS LRM documentation.
        devShells.mineru = pkgs.mkShell {
          packages = [
            mineruPython
            pkgs.python313Packages.virtualenv
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.stdenv.cc.cc.lib
            pkgs.glib
            pkgs.libGL
            pkgs.libx11
            pkgs.libxext
            pkgs.libxrender
            pkgs.libxcb
          ];
          # MinerU otherwise assumes 1 GiB on CPU and processes VLM regions one at a time.
          MINERU_VIRTUAL_VRAM_SIZE = "8";
          shellHook = ''
            if [ ! -x .venv-mineru/bin/python ]; then
              virtualenv --python ${mineruPython}/bin/python .venv-mineru
            fi
            source .venv-mineru/bin/activate
            pip install -U mineru
            pip install -U 'mineru[pipeline]'
            pip install -U six
            pip install -U accelerate
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zpicey";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = [
            zig
            verilator
          ];

          VERILATOR_ROOT = "${verilator}/share/verilator";

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            zig build \
              -Doptimize=ReleaseSafe \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            zig build install \
              -Doptimize=ReleaseSafe \
              --prefix "$out" \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postInstall
          '';
        };
      }
    );
}
