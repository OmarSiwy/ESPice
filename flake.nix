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
        // prev.lib.optionalAttrs (p ? espice-cuda) { inherit (p) espice-cuda; };
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

        # Only what `zig build` reads (build.zig.zon's `.paths` minus docs), so a
        # docs or flake edit does not rebuild the package.
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
          inherit src;
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

        # `cuda = true` adds the CUDA device kernels as sm_75 PTX, which the driver
        # JITs forward to newer cards (release.yml's arch). Zig emits the PTX
        # itself, so the build needs no CUDA toolkit; at run time gompute dlopens
        # libcuda, trying /run/opengl-driver/lib (NixOS) after the loader path.
        #
        # ponytail: no HIP. With an explicit -Dtarget (which the sandbox needs,
        # see zigTarget), build.zig's device-kernel imports (models, contract,
        # device_abi, core, stdpp) keep the host target, and LLVM aborts on
        # "'x86-64' is not a recognized processor" in every amdgcn compile.
        # Add `-Dhip-arch=gfx1100` here once deviceKernelImports builds those
        # modules for the device target it is handed.
        mkEspice =
          {
            cuda ? false,
          }:
          let
            flags = toString (
              [
                "-Doptimize=ReleaseFast"
                "-Dtarget=${zigTarget}"
                "--cache-dir .zig-cache"
                # Zig defaults to every core and each heavy model's LLVM job
                # holds GBs; `nix build --cores N` bounds it.
                "-j$NIX_BUILD_CORES"
              ]
              ++ (
                if cuda then
                  [
                    "-Dcuda-arch=sm_75"
                    "-Dhip-arch=none"
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
            pname = if cuda then "espice-cuda" else "espice";
            version = "1.0.0";
            inherit src;

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
              wrapProgram $out/bin/espice --set-default ZIG ${zig}/bin/zig
              runHook postInstall
            '';

            meta = {
              description = "SPICE circuit simulator" + (if cuda then " with CUDA device kernels" else " (CPU build)");
              mainProgram = "espice";
              license = pkgs.lib.licenses.asl20;
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
        # NVIDIA ships no macOS driver past CUDA 10.2.
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux { espice-cuda = mkEspice { cuda = true; }; };

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
            # check FILE COLUMN WANT: row 1 of COLUMN is WANT to 1e-6 relative.
            check() {
              awk -F, -v col="$2" -v want="$3" '
                NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i }
                NR == 2 { d = $c - want; ok = c && d * d <= 1e-12 * want * want }
                END { exit !ok }' "$1" || { echo "$1: $2 != $3"; cat "$1"; exit 1; }
            }
            cp -r ${./tests/fixtures/hdl}/veriloga_res_divider.{sp,assets} .
            ${pkgs.lib.getExe espice} --format=csv --rawfile=op.csv ${./tests/fixtures/op/balanced_bridge.sp}
            check op.csv 'v(a)' 5
            ${pkgs.lib.getExe espice} --format=csv --rawfile=hdl.csv veriloga_res_divider.sp
            check hdl.csv 'v(out)' 0.35
            ls cache/hdl > /dev/null # the model compiled outside the store
            touch $out
          '';
        };
      }
    );
}
