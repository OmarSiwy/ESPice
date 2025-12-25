### EGSpice

A EG(yptian)Spice circuit simulator written in Zig for full control over performance leading to careful optimizations other libraries dont have. It supports BSIM3, BSIM4, BSIMSOI, Verilog-A models natively, with 0 dependencies.

Why the naming? The pyramids were built long ago from scratch, and were ahead of their time and built to last. This simulator is not ahead of its time, but its built to last.

#### Dependencies:

- Zig (~40MB)
- Verilator

#### Project Structure:

The project structure is purposely kept separated for flexibility in developing & addition of new devices, solvers, and analysis engines.

```
├── lib/                # The core library of ZPicey, containing all devices, solvers, and analysis engines.
├── frontend/            # The frontend module responsible for parsing Verilog-A files and generating Zig code.
├── tools/               # Utility tools, including the fastEval library for device evaluation.
```

#### Frontend:

The frontend currently supports 3 different formats: (PSpice, Spectre, NGSpice/Xyce). However, there are more analysis formats supported than those other simulators.
