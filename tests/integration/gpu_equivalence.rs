//! GPU-CPU equivalence tests (TESTING.md Section 5).

#[test]
#[ignore = "requires GPU compute backend and VOLTAIC_GPU=1"]
fn gpu_cpu_equivalence_dc_inverter() {}

#[test]
#[ignore = "requires GPU compute backend and VOLTAIC_GPU=1"]
fn gpu_cpu_equivalence_dc_ring_osc() {}

#[test]
#[ignore = "requires GPU compute backend and VOLTAIC_GPU=1"]
fn gpu_cpu_equivalence_tran() {}

#[test]
#[ignore = "requires GPU sparse LU solver"]
fn gpu_cpu_equivalence_sparse_lu() {}

#[test]
#[ignore = "requires GPU device evaluation kernels"]
fn gpu_cpu_equivalence_device_eval() {}

#[test]
#[ignore = "requires multi-GPU support"]
fn gpu_multi_gpu_consistency() {}
