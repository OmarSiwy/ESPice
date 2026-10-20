{
  description = "ESPice";

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
      overlays.default = _: prev: removeAttrs self.packages.${prev.stdenv.hostPlatform.system} [ "default" ];
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        lib = pkgs.lib;
        zig = zig-overlay.packages.${system}.master;

        # Explicit glibc target: in the sandbox Zig falls back to a dynamic musl binary that cannot run.
        zigTarget = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-${if pkgs.stdenv.isDarwin then "macos" else "linux-gnu"}";

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./src
            ./models
            ./include
            ./tests
          ];
        };

        # The sandbox has no network: fetch build.zig.zon's dependencies in a fixed-output derivation.
        zigDeps = pkgs.stdenvNoCC.mkDerivation {
          name = "espice-zig-deps";
          inherit src;
          nativeBuildInputs = [ zig ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            export HOME="$TMPDIR" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zgc"
            zig build --fetch
            cp -r "$TMPDIR/zgc/p" "$out"
          '';
          outputHashMode = "recursive";
          outputHash = "sha256-JwC+74Lp4EpggtnNg2Uu9tUxlZKPF+6/ZExDH+z7+IY=";
        };

        gpuPkgs = [
          pkgs.cudaPackages.cudatoolkit
          pkgs.rocmPackages.clr
          pkgs.rocmPackages.rocminfo
        ];
        gpuLibPath = lib.makeLibraryPath ([ "/run/opengl-driver" ] ++ gpuPkgs);

        openvafPkg = import ./nix/openvaf.nix { inherit pkgs; };
        vacaskPkg = import ./nix/vacask.nix { inherit pkgs openvafPkg; };

        devShells = rec {
          ci = pkgs.mkShell {
            packages = [
              zig
              pkgs.python3
            ];
            # One global cache per Zig store path: two builds of the same Zig version
            # sharing ~/.cache/zig evict each other's build runner on every `zig build`.
            shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
          };
          default = pkgs.mkShell {
            inputsFrom = [ ci ];
            packages = gpuPkgs;
            LD_LIBRARY_PATH = gpuLibPath;
          };
          benchmarking = pkgs.mkShell {
            inputsFrom = [ default ];
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.matplotlib ]))
              pkgs.ngspice
              openvafPkg
              vacaskPkg
              pkgs.perf
              pkgs.inferno
            ];
            LD_LIBRARY_PATH = gpuLibPath;
          };
        };

        # No HIP: device-kernel imports keep the host target, which LLVM rejects for amdgcn.
        mkEspice =
          {
            cuda ? false,
          }:
          pkgs.stdenv.mkDerivation {
            pname = if cuda then "espice-cuda" else "espice";
            version = "1.1.0";
            inherit src;
            nativeBuildInputs = [
              zig
              pkgs.makeWrapper
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;
            dontConfigure = true;
            dontInstall = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              cp -r --no-preserve=mode,ownership ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
              zig build install -Dtarget=${zigTarget} -Dhip-arch=none -Dcuda-arch=${if cuda then "sm_75" else "none"} \
                -j$NIX_BUILD_CORES --prefix "$out"
              wrapProgram $out/bin/espice --set-default ZIG ${zig}/bin/zig
            '';
            meta = {
              description = "SPICE circuit simulator" + (if cuda then " with CUDA device kernels" else " (CPU build)");
              mainProgram = "espice";
              license = lib.licenses.asl20;
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
        // lib.optionalAttrs pkgs.stdenv.isLinux { espice-cuda = mkEspice { cuda = true; }; };

        checks.smoke = pkgs.runCommand "espice-smoke" { } ''
          export HOME=$TMPDIR ESPICE_CACHE=$TMPDIR/cache
          check() {
            awk -F, -v col="$2" -v want="$3" '
              NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i }
              NR == 2 { d = $c - want; ok = c && d * d <= 1e-12 * want * want }
              END { exit !ok }' "$1" || { echo "$1: $2 != $3"; cat "$1"; exit 1; }
          }
          cp -r ${./tests/fixtures/hdl}/veriloga_res_divider.{sp,assets} .
          ${lib.getExe espice} --format=csv --rawfile=op.csv ${./tests/fixtures/op/balanced_bridge.sp}
          check op.csv 'v(a)' 5
          ${lib.getExe espice} --format=csv --rawfile=hdl.csv veriloga_res_divider.sp
          check hdl.csv 'v(out)' 0.35
          ls cache/hdl > /dev/null
          touch $out
        '';
      }
    );
}
