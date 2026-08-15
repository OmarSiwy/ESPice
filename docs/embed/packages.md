# Zig package and Nix input

## As a Zig package

ESPice builds with Zig 0.17.0 and can be a dependency of your own
`build.zig`. Add it to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/OmarSiwy/ESPice#main
```

Pin a revision after 1.0.0: the `libespice` lazy path used below was added
after that release. ESPice's own dependencies (VerA, Gompute, stdpp) come
along through its `build.zig.zon`.

The package exposes the C API. Link the static library and translate the
header:

```zig
const espice = b.dependency("espice", .{
    .target = target,
    .optimize = .fast, // ReleaseFast
    .gpu = false, // skip the CUDA/HIP kernels; much faster to build
});

const espice_h = b.addTranslateC(.{
    .root_source_file = espice.path("include/espice.h"),
    .target = target,
    .optimize = optimize,
}).createModule();

exe.root_module.addImport("espice_h", espice_h);
exe.root_module.addObjectFile(espice.namedLazyPath("libespice"));
exe.root_module.link_libc = true;
```

Then call it from Zig through the header's names:

```zig
const c = @import("espice_h");

var options: c.espice_create_options = undefined;
c.espice_default_options(&options);
```

The [C API page](c-api.md) explains the calls. `dependency.artifact("espice")`
does not work: the package installs both the `espice` executable and the
`espice` library, so the name is ambiguous. Use the `libespice` lazy path.

The dependency builds every built-in Verilog-A model, so the first build
takes a while; later builds hit the Zig cache. `.hdl` models need more at
run time (the Zig compiler and the evaluator sources); see
[Verilog-A](../using/devices.md#your-own-verilog-a). A host that ships
them in its own bundle passes their paths in `zig_path` and `share_path`
(`Options.hdl_toolchain` from Zig) instead of relying on `$ZIG` and the
executable's location; from Zig, `hdl_toolchain.cache_dir` also replaces
the `$ESPICE_CACHE` build cache. Their display-task lines print on the process's
standard output; no option redirects them yet (#127).

## As a Nix flake input

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.espice.url = "github:OmarSiwy/ESPice";

  outputs = { nixpkgs, espice, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ espice.packages.${system}.default ];
      };
    };
}
```

`espice.packages.<system>.default` provides `bin/espice`,
`lib/libespice.a`, `include/espice.h` and `share/espice/`. It is a CPU-only
build, and its `espice` wrapper points `ZIG` at the Zig it was built with,
so `.hdl` decks work. A C program links it as on the [C API page](c-api.md), with `$espice` the
package's store path:

```sh
gcc host.c -I$espice/include $espice/lib/libespice.a -lc -lm -lpthread -o host
```

The systems are `x86_64-linux`, `aarch64-linux`, `x86_64-darwin` and
`aarch64-darwin`.
