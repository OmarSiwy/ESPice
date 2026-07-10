{ pkgs, openvafPkg }:

pkgs.stdenv.mkDerivation rec {
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
    suitesparse
    openblas
    boost
    tomlplusplus
  ];

  postPatch = ''
    # Remove Boost_NO_SYSTEM_PATHS so nix-installed boost is found.
    sed -i 's/set(Boost_NO_SYSTEM_PATHS TRUE)//' CMakeLists.txt
    # Remove version req (nixpkgs has 1.89) and drop 'system' component
    # (boost_system is header-only in boost >=1.87, no libboost_system.so).
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
}
