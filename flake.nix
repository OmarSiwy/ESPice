{
  description = "ESPice";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        zig = zig-overlay.packages.${system}."0.16.0";

        commonInputs = [
          zig
        ];

        # Zig's native-target detection finds no glibc inside the nix sandbox and quietly
        # falls back to musl — but emits a *dynamically linked* musl binary, whose loader
        # `/lib/ld-musl-x86_64.so.1` exists on no NixOS machine. The build went green and
        # produced something that could not execute at all. Naming the target explicitly
        # gets a statically linked musl binary on Linux, which runs anywhere.
        #
        # Naming it is also what forces `-Dgpu=false` below: with an explicit `-Dtarget`
        # the host `-mcpu` leaks into gompute's GPU kernel compilation and the amdgcn
        # build dies inside LLVM with "'x86-64' is not a recognized processor for this
        # target". A packaged simulator wants the portable CPU build anyway; `nix
        # develop` still carries the full CUDA/ROCm toolchain for kernel work.
        zigTarget =
          {
            x86_64-linux = "x86_64-linux-musl";
            aarch64-linux = "aarch64-linux-musl";
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

          buildPhase = ''
            runHook preBuild
            zig build --fetch=all --global-cache-dir "$TMPDIR/zgc"
            cp -r "$TMPDIR/zgc/p" "$out"
            runHook postBuild
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-2z1qOSBAUmFLxMr2OIREoCH/KH/sYQxvWgSFi2Y+DZ8=";
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
      in
      {
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

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "espice";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = [
            zig
          ];

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

            zig build \
              -Doptimize=ReleaseFast \
              -Dtarget=${zigTarget} \
              -Dgpu=false \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            zig build install \
              -Doptimize=ReleaseFast \
              -Dtarget=${zigTarget} \
              -Dgpu=false \
              --prefix "$out" \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postInstall
          '';
        };
      }
    );
}
