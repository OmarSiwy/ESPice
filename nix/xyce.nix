# Xyce, the Sandia parallel SPICE simulator.
#
# DEFAULT IS SERIAL, on purpose and measured. Plain `pkgs.xyce` is a pure
# binary-cache hit (146 MiB fetched, ZERO derivations built); flipping
# withMPI=true makes Xyce itself a local ~30 min compile, because the override
# changes the Xyce derivation even though trilinos-mpi is itself cached.
#
# Serial is also the CORRECT build for this benchmark. The runner times one
# process and counts its instructions; an MPI Xyce adds MPI_Init and
# domain-decomposition setup to every one of those runs while the fixtures
# (105x105 matrices, 280 small decks) have nothing to decompose. That would
# make Xyce look slower for reasons that have nothing to do with its solver.
#
# Set `withMPI = true` for a genuinely large deck where partitioning pays, or
# `fromSource = true` to build Xyce 7.10 against the same Trilinos by hand.
{
  pkgs,
  fromSource ? false,
  withMPI ? false,
}:

let
  mpi = pkgs.openmpi;
  trilinosMpi = pkgs.trilinos.override {
    withMPI = true;
    inherit mpi;
  };

  # --- nixpkgs path ---
  # Untouched when serial: ANY override or overrideAttrs (even just adding a
  # lowercase `xyce` symlink, even `enableDocs = false`) changes the derivation
  # hash and turns a 146 MiB fetch into a local compile. The runner takes an
  # explicit `--xyce PATH` and defaults to `.../bin/Xyce`, so the symlink that
  # used to justify the rebuild is no longer needed by anything.
  xyceFromNixpkgs =
    if withMPI then
      pkgs.xyce.override {
        withMPI = true;
        trilinos = trilinosMpi;
        inherit mpi;
      }
    else
      pkgs.xyce;

  # --- from-source path: same Trilinos, manual Xyce build ---
  xyceFromSource = pkgs.stdenv.mkDerivation rec {
    pname = "xyce";
    version = "7.10.0";

    src = pkgs.fetchgit {
      name = "Xyce";
      url = "https://github.com/Xyce/Xyce.git";
      rev = "Release-${version}";
      hash = "sha256-8cvglBCykZVQk3BD7VE3riXfJ0PAEBwsoloqUsrMlBc=";
    };

    nativeBuildInputs = with pkgs; [
      cmake
      gfortran
      libtool_2
      bison
      flex
      mpi
    ];

    buildInputs = with pkgs; [
      blas
      lapack
      fftw
      suitesparse
      trilinosMpi
      mpi
    ];

    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_C_COMPILER=${mpi}/bin/mpicc"
      "-DCMAKE_CXX_COMPILER=${mpi}/bin/mpicxx"
      "-DBUILD_TESTING=OFF"
      "-DTrilinos_DIR=${trilinosMpi}/lib/cmake/Trilinos"
    ];

    enableParallelBuilding = true;
    doCheck = false;

    installPhase = ''
      runHook preInstall
      cmake --install . --prefix $out
      ln -s $out/bin/Xyce $out/bin/xyce
      runHook postInstall
    '';

    meta = {
      description = "Xyce parallel SPICE simulator (from source, MPI)";
      homepage = "https://xyce.sandia.gov";
      license = pkgs.lib.licenses.gpl3;
      platforms = [ "x86_64-linux" ];
    };
  };
in
if fromSource then xyceFromSource else xyceFromNixpkgs
