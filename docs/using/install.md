# Install

ESPice is one binary, `espice`, plus a static library and C header for
embedding. There are three ways to get it.

## Nix

The repository is a flake. Run it without installing:

```sh
nix run github:OmarSiwy/ESPice -- my_circuit.sp
```

Install it into your profile:

```sh
nix profile install github:OmarSiwy/ESPice
espice --version
```

Or use it as an input of your own flake:

```nix
{
  inputs.espice.url = "github:OmarSiwy/ESPice";

  outputs = { self, nixpkgs, espice, ... }: {
    # espice.packages.<system>.default is the espice package
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = [ espice.packages.x86_64-linux.default ];
    };
  };
}
```

The flake package is a CPU-only build (`-Dgpu=false`). Its `espice` wrapper
sets `ZIG` to the Zig it was built with, so decks that load Verilog-A
through `.hdl` work out of the box. For a GPU build, build from source
inside `nix develop`, which carries the CUDA and ROCm toolchains.

## Release tarballs

The release workflow builds a tarball per platform, plus a `SHA256SUMS`
file, for each tagged release on the
[GitHub releases page](https://github.com/OmarSiwy/ESPice/releases).

!!! note
    The 1.0.0 release has no tarballs: its release build failed. Until a
    release carries them, install with Nix or build from source.

The platforms are:

| Tarball | CPU | GPU kernels |
|---|---|---|
| `linux-x86_64-v2` | x86-64 with SSE4.2 (the safe fallback) | CUDA `sm_75`, HIP `gfx1100` |
| `linux-x86_64-v3` | x86-64 with AVX2 and FMA (Haswell and later) | CUDA `sm_75`, HIP `gfx1100` |
| `linux-x86_64-v4` | x86-64 with AVX-512 | CUDA `sm_75`, HIP `gfx1100` |
| `linux-aarch64` | ARMv8.0 | CUDA `sm_75` |
| `linux-aarch64-neoverse-n1` | Neoverse N1 (Graviton2, Ampere Altra) | CUDA `sm_75` |
| `macos-arm64` | Apple M1 and later | none |

The Linux builds target glibc 2.28 or newer. Pick the highest x86-64 level
your CPU supports; a binary built for a level the CPU lacks dies with
`SIGILL`. `grep -o 'avx512f\|avx2' /proc/cpuinfo | sort -u` tells you which.

```sh
tar xzf espice-1.0.0-linux-x86_64-v3.tar.gz
./espice-1.0.0-linux-x86_64-v3/bin/espice --version
```

The tarball holds `bin/espice`, `lib/libespice.a`, `include/espice.h`, and
`share/espice/`, the evaluator sources that `.hdl` needs at run time. Keep
the directory layout intact if you move it.

## From source

You need Zig 0.17.0 and nothing else; the Zig dependencies (VerA, Gompute,
stdpp) are pinned in `build.zig.zon` and fetched by the build.

```sh
git clone https://github.com/OmarSiwy/ESPice
cd ESPice
nix develop     # optional: Zig 0.17 plus the CUDA and ROCm toolchains
zig build       # zig-out/bin/espice
```

`zig build` compiles every Verilog-A model in `models/` and, by default,
device kernels for the GPU it detects. A CPU-only build compiles much
faster:

```sh
zig build -Dgpu=false
```

`zig build run -- FILE.sp` builds and runs in one step.

Build options (`zig build --help` lists them all):

| Option | Default | Effect |
|---|---|---|
| `-Doptimize=` | `ReleaseFast` | Zig optimize mode. `.hdl` decks need a release mode, not `Debug` |
| `-Dgpu=false` | `true` | skip the CUDA and HIP device kernels |
| `-Dcuda-arch=` | `auto` | CUDA arch (`sm_75`, ...); `auto` probes the build machine, `none` omits CUDA |
| `-Dhip-arch=` | `gfx1100` | HIP arch; `none` omits HIP |
| `-Ddebug-info` | `false` | DWARF in release builds, for profiling (about 3x the LLVM time) |

The install prefix (`zig-out/` unless you pass `--prefix`) gets the same
`bin/`, `lib/`, `include/` and `share/espice/` layout as the release
tarballs.

## Check the install

```sh
espice --version
```

prints `espice 1.0.0`. Then try the [quick start](../index.md#quick-start).
