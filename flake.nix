{
  description = "ESPice";

  # Prebuilt espice from CI (.github/workflows/nix.yml). Key from the Cachix API
  # (app.cachix.org/api/v1/cache/omarsiwy), the same one `cachix use omarsiwy` adds.
  nixConfig = {
    extra-substituters = [ "https://omarsiwy.cachix.org" ];
    extra-trusted-public-keys = [ "omarsiwy.cachix.org-1:fE15rGllP0D8ijLsCorvAx66mlXLp+1H1l0lR72iZ3U=" ];
  };

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
      ...
    }:
    {
      # `prev`, not `final`: the attribute names must not depend on this overlay.
      overlays.default =
        _: prev:
        let
          p = self.packages.${prev.stdenv.hostPlatform.system};
        in
        {
          inherit (p) espice;
        }
        // prev.lib.optionalAttrs (p ? espice-gpu) { inherit (p) espice-gpu; };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        zig = zig-overlay.packages.${system}."0.17.0";

        commonInputs = [
          zig
        ];

        # Zig's native-target detection finds no glibc inside the nix sandbox and quietly
        # falls back to musl — but emits a *dynamically linked* musl binary, whose loader
        # `/lib/ld-musl-x86_64.so.1` exists on no NixOS machine. The build went green and
        # produced something that could not execute at all. Naming the target explicitly
        # fixes that. It is glibc, not static musl: a deck's `.hdl` model is compiled
        # to a shared library at run time and dlopen'd, which a static musl binary
        # cannot do (it segfaulted). Zig links against its own glibc stubs, and
        # autoPatchelfHook points the result at nixpkgs' loader.
        zigTarget =
          {
            x86_64-linux = "x86_64-linux-gnu";
            aarch64-linux = "aarch64-linux-gnu";
            x86_64-darwin = "x86_64-macos";
            aarch64-darwin = "aarch64-macos";
          }
          .${system};

        # build.zig.zon pins VerA and Gompute as git+https URLs, which Zig resolves by
        # fetching them partway through `zig build`. A nix sandbox has no network, so
        # that build died with `unable to discover remote git server capabilities:
        # NameServerFailure` and the package could not be built or cached at all.
        #
        # A fixed-output derivation is the one place nix permits network access, so the
        # fetch happens here and the real build below runs entirely offline against the
        # result. `--fetch=all` rather than the default `needed`: the default skips lazy
        # dependencies, which would leave the offline build to discover a missing one.
        #
        # The output hash is over Zig's package cache (`p/`), whose entries are
        # content-addressed tarballs named by the same hashes build.zig.zon already pins
        # — so it is stable as long as those pins are. Bumping either dependency changes
        # this hash, and nix will print the new one.
        zigDeps = pkgs.stdenvNoCC.mkDerivation {
          name = "espice-zig-deps";
          src = ./.;
          nativeBuildInputs = [ zig ];

          dontConfigure = true;
          dontInstall = true;

          # Zig 0.17's `zig build` has no --global-cache-dir; the environment
          # names it, and HOME must not be the sandbox's unwritable /homeless-shelter.
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zgc"
            zig build --fetch=all
            cp -r "$TMPDIR/zgc/p" "$out"
            runHook postBuild
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-IkkUnW1gcZ0M7WXm9O1YDfD4lFCPzWPtIR9vDmlNFio=";
        };

        # GPU SUPPORT
        cudaPkgs = with pkgs.cudaPackages; [
          cudatoolkit # nvcc, headers, libs, nvidia-smi
          cuda_cudart # runtime (libcudart)
          cuda_nvcc # compiler driver
        ];
        rocmPkgs = with pkgs.rocmPackages; [
          clr # HIP runtime (libamdhip64)
          hipcc # HIP compiler
          rocminfo # device query
          rocm-smi # GPU monitoring
          hip-common # headers
        ];
        gpuLibPath = pkgs.lib.makeLibraryPath (
          [
            "/run/opengl-driver"
          ]
          ++ cudaPkgs
          ++ rocmPkgs
        );

        # Simulator packages for benchmarking against
        openvafPkg = import ./nix/openvaf.nix { inherit pkgs; };
        vacaskPkg = import ./nix/vacask.nix {
          inherit pkgs;
          openvafPkg = openvafPkg;
        };
        # Default dev shell: build tools + llc + CUDA/ROCm toolchains.
        devShells.default = pkgs.mkShell ({
          packages =
            commonInputs
            ++ [
              pkgs.llvmPackages_21.llvm
            ]
            ++ cudaPkgs
            ++ rocmPkgs;
          LD_LIBRARY_PATH = gpuLibPath;
        });

        # Benchmarking: adds ngspice + perf + flamegraph on top.
        devShells.benchmarking = pkgs.mkShell ({
          packages =
            commonInputs
            ++ [
              pkgs.ngspice
              pkgs.coreutils
              pkgs.time
              pkgs.gnucap
              (pkgs.python3.withPackages (ps: [ ps.matplotlib ])) # postlayout/gen.py, tools/bench_plot.py
              openvafPkg
              vacaskPkg
              pkgs.perf
              pkgs.flamegraph
              pkgs.inferno
              pkgs.llvmPackages_21.llvm
            ]
            ++ cudaPkgs
            ++ rocmPkgs;
          LD_LIBRARY_PATH = gpuLibPath;
        });

        # `gpu = true` adds the CUDA (sm_75 PTX, which the driver JITs forward to
        # newer cards) and HIP (gfx1100) device kernels, the arches release.yml
        # ships. Zig emits both itself, so the build needs no CUDA or ROCm
        # toolkit. At run time gompute dlopens libcuda (NixOS: /run/opengl-driver)
        # and libamdhip64 (nixpkgs' ROCm clr) from the wrapped LD_LIBRARY_PATH.
        mkEspice =
          {
            gpu ? false,
          }:
          let
            flags = toString (
              [
                "-Doptimize=ReleaseFast"
                "-Dtarget=${zigTarget}"
                "--cache-dir .zig-cache"
              ]
              ++ (
                if gpu then
                  [
                    "-Dcuda-arch=sm_75"
                    "-Dhip-arch=gfx1100"
                  ]
                else
                  [
                    "-Dgpu=false"
                    "-Dhip-arch=none"
                    "-Dcuda-arch=none"
                  ]
              )
            );
          in
          pkgs.stdenv.mkDerivation {
            pname = if gpu then "espice-gpu" else "espice";
            version = "1.0.0";
            # Only what `zig build` reads, so a docs or flake edit does not
            # rebuild the package.
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./build.zig
                ./build.zig.zon
                ./src
                ./models
                ./include
                ./tests
              ];
            };

            nativeBuildInputs = [
              zig
              pkgs.makeWrapper
            ]
            ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;

            dontConfigure = true;

            # Seed the global cache from the fetched-ahead dependencies. Copied rather
            # than symlinked, and made writable, because Zig writes into this directory
            # while unpacking and cannot do that through a read-only store path.
            preBuild = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              cp -r --no-preserve=mode,ownership ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            buildPhase = ''
              runHook preBuild
              zig build ${flags}
              runHook postBuild
            '';

            # A `.hdl` model is compiled on first load with the Zig espice was
            # built with; the build cache lives under $ESPICE_CACHE or
            # ~/.cache/espice, never in the store.
            installPhase = ''
              runHook preInstall
              zig build install ${flags} --prefix "$out"
              wrapProgram $out/bin/espice --set-default ZIG ${zig}/bin/zig ${pkgs.lib.optionalString gpu "--suffix LD_LIBRARY_PATH : /run/opengl-driver/lib:${pkgs.rocmPackages.clr}/lib"}
              runHook postInstall
            '';

            meta = {
              description =
                "SPICE circuit simulator" + (if gpu then " with CUDA/HIP device kernels" else " (CPU build)");
              mainProgram = "espice";
            };
          };
        espice = mkEspice { };
      in
      {
        inherit devShells;

        packages = {
          default = espice;
          inherit espice;
        }
        # nixpkgs' ROCm is Linux-only, and macOS has neither backend.
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux { espice-gpu = mkEspice { gpu = true; }; };

        apps.default = {
          type = "app";
          program = pkgs.lib.getExe espice;
          meta.description = "Run espice on a SPICE deck";
        };

        checks = {
          inherit espice;
          # One plain deck and one `.hdl` deck: the second compiles a Verilog-A
          # model at run time with the wrapped Zig against share/espice in the store.
          smoke = pkgs.runCommand "espice-smoke" { } ''
            export HOME=$TMPDIR ESPICE_CACHE=$TMPDIR/cache
            cp -r ${./tests/fixtures/hdl}/veriloga_res_divider.{sp,assets} .
            ${pkgs.lib.getExe espice} --format=print ${./tests/fixtures/op/balanced_bridge.sp} 2>&1 | tee op.log
            grep -q "Operating Point" op.log
            ${pkgs.lib.getExe espice} --format=print veriloga_res_divider.sp 2>&1 | tee hdl.log
            grep -Eq "3\.5(0*)e-01" hdl.log
            touch $out
          '';
        };
      }
    );
}
