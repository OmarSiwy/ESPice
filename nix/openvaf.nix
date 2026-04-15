{ pkgs }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "openvaf-r";
  version = "unstable-2026";

  src = pkgs.fetchFromGitHub {
    owner = "arpadbuermen";
    repo = "OpenVAF";
    rev = "2e066436d985b05cf8e6563e936daf9ab875775a";
    hash = "sha256-AXtp8qaDq/MRYz2TYXRwT3kS+8EnKyakD3lQwdv3K34=";
  };

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    outputHashes = {
      "salsa-0.17.0-pre.2" = "sha256-6GssvV76lFr5OzAUekz2h6f82Tn7usz5E8MSZ5DmgJw=";
    };
  };

  # Patch build scripts to skip Windows-only steps on Linux hosts.
  # RUST_CHECK was used previously for this but it also skips osdi stdlib.c bitcode
  # generation, producing a broken binary. Instead patch each build.rs individually.
  postPatch = ''
    # target/build.rs: skip MSVC ucrt import-lib on non-Windows host
    sed -i 's/if check {/if check || !cfg!(target_os = "windows") {/g' \
      openvaf/target/build.rs
    # osdi/build.rs: skip generating bitcode for MSVC targets on non-Windows host
    sed -i 's/if no_gen {/if no_gen || (target.options.is_like_windows \&\& !cfg!(target_os = "windows")) {/' \
      openvaf/osdi/build.rs
  '';

  buildAndTestSubdir = "openvaf/openvaf-driver";

  buildFeatures = [ "llvm18" ];

  nativeBuildInputs = with pkgs; [ pkg-config ];

  buildInputs = with pkgs; [ llvm_18 libffi libxml2 zlib ];

  # symlinkJoin provides both llvm-config (for llvm-sys) AND unwrapped clang
  # (for osdi/build.rs stdlib.c -> bitcode cross-compilation).
  # The wrapped clang adds x86_64-specific Nix flags that break -target riscv64 etc.
  env.LLVM_SYS_181_PREFIX = "${pkgs.symlinkJoin {
    name = "llvm18-prefix";
    paths = [ pkgs.llvm_18.dev pkgs.llvmPackages_18.clang-unwrapped ];
  }}";

  doCheck = false;

  # Only install the openvaf-r binary
  postInstall = ''
    find $out/bin -type f ! -name "openvaf-r" -delete 2>/dev/null || true
  '';

  meta = {
    description = "OpenVAF-reloaded: Verilog-A compiler for VACASK";
    homepage = "https://github.com/arpadbuermen/OpenVAF";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
