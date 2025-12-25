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

        commonInputs = [
          zig
          verilator
          sv2v
        ];

        commonEnv = {
          VERILATOR_ROOT = "${verilator}/share/verilator";
        };
      in
      {
        # For !! benchmarking ONLY
        devShells.benchmarking = pkgs.mkShell (
          commonEnv
          // {
            packages = commonInputs ++ [
              pkgs.ngspice
              pkgs.perf
              pkgs.flamegraph
              pkgs.inferno
            ];
          }
        );

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
