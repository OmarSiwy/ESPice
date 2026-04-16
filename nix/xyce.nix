# Xyce parallel (MPI) build.
#
# Uses the nixpkgs xyce package with withMPI=true and trilinos-mpi.
# This gives us Trilinos 16.1.0 with Zoltan, Isorropia, Amesos2/KLU2,
# Belos, Kokkos, Stokhos — full parallel solver stack.
#
# If nixpkgs xyce-parallel breaks on your machine, set `fromSource = true`
# to build Xyce 7.10 from source against the same trilinos-mpi.
{ pkgs, fromSource ? false }:

let
  mpi = pkgs.openmpi;
  trilinosMpi = pkgs.trilinos.override { withMPI = true; inherit mpi; };

  # --- nixpkgs path: override + add lowercase symlink ---
  xyceFromNixpkgs = (pkgs.xyce.override {
    withMPI = true;
    trilinos = trilinosMpi;
    inherit mpi;
    enableDocs = false;
    enableTests = false;
  }).overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      ln -sf $out/bin/Xyce $out/bin/xyce
    '';
  });

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
