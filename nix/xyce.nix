{ pkgs }:

let
  mpi = pkgs.openmpi;
  trilinos = pkgs.trilinos.override { withMPI = true; mpi = pkgs.openmpi; };
in
pkgs.stdenv.mkDerivation rec {
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
    trilinos
    mpi
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_TESTING=OFF"
    "-DMPI_C_COMPILER=${mpi}/bin/mpicc"
    "-DMPI_CXX_COMPILER=${mpi}/bin/mpicxx"
    "-DMPI_Fortran_COMPILER=${mpi}/bin/mpifort"
    "-DMPI_C_LIBRARIES=${mpi}/lib/libmpi.so"
    "-DMPI_CXX_LIBRARIES=${mpi}/lib/libmpi.so"
    "-DMPI_C_INCLUDE_DIRS=${mpi}/include"
    "-DMPI_CXX_INCLUDE_DIRS=${mpi}/include"
    "-DTrilinos_DIR=${trilinos}/lib/cmake/Trilinos"
    "-DXyce_ENABLE_PARALLEL_DAE=ON"
  ];

  env.NIX_LDFLAGS = "-L${mpi}/lib -lmpi";

  enableParallelBuilding = true;
  doCheck = false;

  installPhase = ''
    runHook preInstall
    cmake --install . --prefix $out
    ln -s $out/bin/Xyce $out/bin/xyce
    runHook postInstall
  '';

  meta = {
    description = "Xyce high-performance parallel SPICE simulator (from source, MPI via openmpi)";
    homepage = "https://xyce.sandia.gov";
    license = pkgs.lib.licenses.gpl3;
    platforms = [ "x86_64-linux" ];
  };
}
