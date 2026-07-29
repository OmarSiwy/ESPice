# GPU backend

ESPice can evaluate device models on an NVIDIA (CUDA) or AMD (HIP) GPU.
The device kernels are the same code as the CPU path, compiled for each
target, so a GPU run computes the same device stamps as a CPU run.

```sh
espice big.sp --backend=auto     # GPU if present and worth it, else CPU
espice big.sp --backend=cuda     # CUDA or fail
espice big.sp --backend=hip      # HIP or fail
espice big.sp --gpu              # like auto, but fail when there is no GPU
```

The default is `--backend=cpu`.

## What runs on the GPU

Per Newton iteration, the GPU evaluates the devices: every instance's
currents, charges and their derivatives, summed into the circuit matrix
and right-hand side in a fixed order. The sum is deterministic, so a
Newton iteration sees the same matrix every time. The matrix solve, the
Newton update, convergence checks and transient step control run on the
CPU.

For large circuits (10,000 unknowns or more) ESPice may also factor the
matrix on the GPU. `ESPICE_GPU_LU=1` forces that on under a GPU backend,
`ESPICE_GPU_LU=0` keeps the factorization on the CPU.

Not every device runs there. A device whose model keeps state the kernels
cannot carry (VBIC's limiting, for one) is evaluated on the CPU and added
to the GPU's result, so a circuit can mix both. `auto` also estimates the
cost: launching kernels and copying the solution vector each iteration has
a fixed price, and a small circuit is faster on the CPU.

## What fails, and when

| Request | No GPU, or the build has no kernels | Nothing in the circuit runs on the GPU | GPU slower than CPU (estimate) |
|---|---|---|---|
| `--backend=cpu` | CPU | CPU | CPU |
| `--backend=auto` | CPU, with a warning | CPU, with a warning | CPU, silently |
| `--gpu` | error | CPU, with a warning | CPU, silently |
| `--backend=cuda` or `hip` | error | error | GPU anyway |

An explicit `cuda` or `hip` that cannot run fails the deck, with an error
naming the hardware ESPice found. Here a CPU-only binary (no kernel images)
runs on a machine with an NVIDIA card:

```text
$ espice --backend=cuda divider.sp
note: GPU batch 'resistor' (2 instances) stays on the CPU: no kernel image in this build
Error: --backend cuda: GPU unavailable (CircuitNotEligible); detected GPU hardware: cuda
Error: divider.sp: CircuitNotEligible
```

The `note:` lines name each device type that stays on the CPU and why.
The reason in parentheses is one of:

| Reason | Meaning |
|---|---|
| `CircuitNotEligible` | no device in the circuit has a GPU kernel in this binary |
| `NoGpuArtifacts` | the binary was built with no device kernels at all |
| `NotEnoughGpuWork` | the cost estimate says the CPU is faster (`auto` only) |
| a driver error | the CUDA or HIP runtime refused |

With `--gpu` the same deck falls back, because the machine has a GPU and
only the circuit was ineligible:

```text
$ espice --gpu divider.sp
note: GPU batch 'resistor' (2 instances) stays on the CPU: no kernel image in this build
warning: GPU unavailable (CircuitNotEligible); running on the CPU
Voltage divider: 3 devices
  Operating Point: 1 points, 3 variables
```

The Nix package and any `-Dgpu=false` build carry no kernels, so they
always run on the CPU.

## Getting a GPU build

The release tarballs for Linux include CUDA kernels for `sm_75` (Turing)
and later, and the x86-64 ones also HIP kernels for `gfx1100` (RDNA3). To
build for your own card:

```sh
nix develop                      # CUDA and ROCm toolchains
zig build -Dcuda-arch=sm_89      # or auto, to probe this machine
zig build -Dhip-arch=gfx90a
```

`-Dcuda-arch=none` or `-Dhip-arch=none` leaves a target out. The machine
running ESPice needs the CUDA driver or the ROCm runtime; the toolkit is
only needed to build.

## Threads instead

On the CPU, `ESPICE_THREADS=N` evaluates devices on N threads and
`ESPICE_SOLVER_THREADS=N` (up to 16) factors the matrix in parallel blocks.
For many independent analyses in one deck, `--jobs=N` runs them at the
same time. These combine with each other and with a GPU backend.
