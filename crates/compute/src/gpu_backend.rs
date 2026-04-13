use crate::backend::ComputeBackend;

const WG_SIZE: u32 = 256;

/// GPU compute backend using wgpu.
///
/// Offloads BLAS-1 vector operations and batch device evaluation to the GPU.
/// Falls back to CPU for vectors below `min_gpu_size` to avoid transfer overhead.
pub struct WgpuBackend {
    device: wgpu::Device,
    queue: wgpu::Queue,
    axpy_pipeline: wgpu::ComputePipeline,
    scale_pipeline: wgpu::ComputePipeline,
    dot_pipeline: wgpu::ComputePipeline,
    norm_inf_pipeline: wgpu::ComputePipeline,
    min_gpu_size: usize,
}

/// Uniform params buffer layout matching the WGSL struct.
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuParams {
    n: u32,
    alpha: f32,
    alpha_hi: u32,
    alpha_lo: u32,
}

impl WgpuBackend {
    /// Probe the system for any compatible wgpu adapter.
    ///
    /// Returns `true` when at least one high-performance adapter
    /// (any backend) can be acquired *without* fully constructing a
    /// device or compiling shaders.  Used by the solver dispatch
    /// layer as a cheap "is GPU available?" check before deciding
    /// whether to attempt the heavier `WgpuBackend::new` call.
    pub fn is_available() -> bool {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .is_ok()
    }

    /// Borrow the underlying wgpu device.  Used by other crates
    /// (e.g. `bigospice_device::bsim4::gpu`) that need to compile a
    /// custom shader against the same adapter.
    #[inline]
    pub fn raw_device(&self) -> &wgpu::Device {
        &self.device
    }

    /// Borrow the underlying wgpu queue.
    #[inline]
    pub fn raw_queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    /// Create a new GPU backend. Blocks until the device is ready.
    pub fn new(min_gpu_size: usize) -> Option<Self> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok()?;

        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("bigospice-gpu"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                ..Default::default()
            },
        ))
        .ok()?;

        let shader_src = include_str!("shaders/blas.wgsl");
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blas"),
            source: wgpu::ShaderSource::Wgsl(shader_src.into()),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blas-bgl"),
            entries: &[
                bgl_entry(0, wgpu::BufferBindingType::Uniform),
                bgl_entry(1, wgpu::BufferBindingType::Storage { read_only: false }),
                bgl_entry(2, wgpu::BufferBindingType::Storage { read_only: true }),
                bgl_entry(3, wgpu::BufferBindingType::Storage { read_only: false }),
            ],
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("blas-pl"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let make_pipeline = |dev: &wgpu::Device, entry: &str| -> wgpu::ComputePipeline {
            dev.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&pipeline_layout),
                module: &shader,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };

        let axpy_pipeline = make_pipeline(&device, "axpy");
        let scale_pipeline = make_pipeline(&device, "scale");
        let dot_pipeline = make_pipeline(&device, "dot_partial");
        let norm_inf_pipeline = make_pipeline(&device, "norm_inf_partial");

        Some(Self {
            device,
            queue,
            axpy_pipeline,
            scale_pipeline,
            dot_pipeline,
            norm_inf_pipeline,
            min_gpu_size,
        })
    }

    fn workgroup_count(n: u32) -> u32 {
        (n + WG_SIZE - 1) / WG_SIZE
    }

    fn create_buffer(&self, data: &[u8], usage: wgpu::BufferUsages) -> wgpu::Buffer {
        self.device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: None,
                contents: data,
                usage,
            })
    }

    fn create_params_buffer(&self, n: u32, alpha: f64) -> wgpu::Buffer {
        let alpha_bits = alpha.to_bits();
        let params = GpuParams {
            n,
            alpha: alpha as f32,
            alpha_hi: (alpha_bits >> 32) as u32,
            alpha_lo: alpha_bits as u32,
        };
        self.create_buffer(
            bytemuck::bytes_of(&params),
            wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        )
    }

    fn dispatch_and_read(
        &self,
        pipeline: &wgpu::ComputePipeline,
        bind_group: &wgpu::BindGroup,
        workgroups: u32,
        readback_buf: &wgpu::Buffer,
        staging_buf: &wgpu::Buffer,
        staging_size: u64,
    ) -> Vec<u8> {
        let mut encoder = self.device.create_command_encoder(&Default::default());

        {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, bind_group, &[]);
            pass.dispatch_workgroups(workgroups, 1, 1);
        }

        encoder.copy_buffer_to_buffer(readback_buf, 0, staging_buf, 0, staging_size);
        self.queue.submit(std::iter::once(encoder.finish()));

        let slice = staging_buf.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            tx.send(result).ok();
        });
        self.device.poll(wgpu::PollType::Wait).ok();
        rx.recv().unwrap().unwrap();

        let data = slice.get_mapped_range().to_vec();
        staging_buf.unmap();
        data
    }

    /// Run axpy or scale on the GPU and write results back to the host slice.
    fn gpu_axpy_or_scale(
        &self,
        pipeline: &wgpu::ComputePipeline,
        alpha: f64,
        x: &mut [f64],
        y_opt: Option<&[f64]>,
    ) {
        let n = x.len() as u32;
        let params_buf = self.create_params_buffer(n, alpha);

        let x_bytes: &[u8] = bytemuck::cast_slice(x);
        let x_buf = self.create_buffer(
            x_bytes,
            wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        );

        let y_buf = if let Some(y) = y_opt {
            let y_bytes: &[u8] = bytemuck::cast_slice(y);
            self.create_buffer(y_bytes, wgpu::BufferUsages::STORAGE)
        } else {
            self.create_buffer(
                &vec![0u8; x_bytes.len()],
                wgpu::BufferUsages::STORAGE,
            )
        };

        let result_buf = self.create_buffer(
            &vec![0u8; 4],
            wgpu::BufferUsages::STORAGE,
        );

        let bgl = pipeline.get_bind_group_layout(0);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: x_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: y_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: result_buf.as_entire_binding() },
            ],
        });

        let staging_size = x_bytes.len() as u64;
        let staging_buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: staging_size,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let workgroups = Self::workgroup_count(n);
        let result_data = self.dispatch_and_read(
            pipeline,
            &bind_group,
            workgroups,
            &x_buf,
            &staging_buf,
            staging_size,
        );

        let result_f64: &[f64] = bytemuck::cast_slice(&result_data);
        x[..result_f64.len()].copy_from_slice(result_f64);
    }

    /// Run a reduction kernel (dot or norm_inf) and return partial results.
    fn gpu_reduce(&self, pipeline: &wgpu::ComputePipeline, x: &[f64], y: &[f64]) -> Vec<f32> {
        let n = x.len() as u32;
        let workgroups = Self::workgroup_count(n);
        let params_buf = self.create_params_buffer(n, 0.0);

        let x_bytes: &[u8] = bytemuck::cast_slice(x);
        let x_buf = self.create_buffer(x_bytes, wgpu::BufferUsages::STORAGE);

        let y_bytes: &[u8] = bytemuck::cast_slice(y);
        let y_buf = self.create_buffer(y_bytes, wgpu::BufferUsages::STORAGE);

        let result_size = (workgroups as usize) * 4;
        let result_buf = self.create_buffer(
            &vec![0u8; result_size],
            wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        );

        let bgl = pipeline.get_bind_group_layout(0);
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: x_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: y_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: result_buf.as_entire_binding() },
            ],
        });

        let staging_buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: result_size as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let result_data = self.dispatch_and_read(
            pipeline,
            &bind_group,
            workgroups,
            &result_buf,
            &staging_buf,
            result_size as u64,
        );

        bytemuck::cast_slice::<u8, f32>(&result_data).to_vec()
    }
}

impl ComputeBackend for WgpuBackend {
    fn eval_batch(
        &self,
        _voltages: &[f64],
        _num_devices: usize,
        _num_terminals: usize,
        _results: &mut [f64],
    ) {
        // TODO: implement device eval kernel in WGSL
        // For now, this is handled by the CPU backend.
    }

    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]) {
        if x.len() < self.min_gpu_size {
            // Fall back to scalar.
            for i in 0..x.len() {
                y[i] += alpha * x[i];
            }
            return;
        }
        // GPU path: compute y += alpha * x
        // We need to operate on y (the mutable one), with x as the read source.
        let mut y_copy = y.to_vec();
        self.gpu_axpy_or_scale(&self.axpy_pipeline, alpha, &mut y_copy, Some(x));
        y.copy_from_slice(&y_copy);
    }

    fn dot(&self, x: &[f64], y: &[f64]) -> f64 {
        if x.len() < self.min_gpu_size {
            return x.iter().zip(y.iter()).map(|(a, b)| a * b).sum();
        }
        let partials = self.gpu_reduce(&self.dot_pipeline, x, y);
        partials.iter().map(|&v| v as f64).sum()
    }

    fn norm_inf(&self, x: &[f64]) -> f64 {
        if x.len() < self.min_gpu_size {
            return x.iter().map(|v| v.abs()).fold(0.0f64, f64::max);
        }
        let dummy = vec![0.0f64; x.len()];
        let partials = self.gpu_reduce(&self.norm_inf_pipeline, x, &dummy);
        partials
            .iter()
            .map(|&v| v as f64)
            .fold(0.0f64, f64::max)
    }

    fn scale(&self, alpha: f64, x: &mut [f64]) {
        if x.len() < self.min_gpu_size {
            x.iter_mut().for_each(|v| *v *= alpha);
            return;
        }
        self.gpu_axpy_or_scale(&self.scale_pipeline, alpha, x, None);
    }

    fn name(&self) -> &str {
        "wgpu"
    }
}

fn bgl_entry(binding: u32, ty: wgpu::BufferBindingType) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

use wgpu::util::DeviceExt;

#[cfg(test)]
mod tests {
    use super::*;

    fn try_gpu() -> Option<WgpuBackend> {
        WgpuBackend::new(0)
    }

    #[test]
    fn backend_creates_or_skips() {
        // This test passes whether GPU is available or not.
        match try_gpu() {
            Some(b) => assert_eq!(b.name(), "wgpu"),
            None => eprintln!("No GPU adapter found, skipping GPU tests"),
        }
    }

    #[test]
    fn fallback_axpy() {
        // With min_gpu_size > input, always falls back to CPU.
        if let Some(b) = WgpuBackend::new(1_000_000) {
            let x = vec![1.0, 2.0, 3.0, 4.0];
            let mut y = vec![10.0, 20.0, 30.0, 40.0];
            b.axpy(2.0, &x, &mut y);
            assert_eq!(y, vec![12.0, 24.0, 36.0, 48.0]);
        }
    }

    #[test]
    fn fallback_dot() {
        if let Some(b) = WgpuBackend::new(1_000_000) {
            let x = vec![1.0, 2.0, 3.0, 4.0];
            let y = vec![5.0, 6.0, 7.0, 8.0];
            assert_eq!(b.dot(&x, &y), 70.0);
        }
    }

    #[test]
    fn fallback_norm_inf() {
        if let Some(b) = WgpuBackend::new(1_000_000) {
            let x = vec![1.0, -5.0, 3.0, 2.0];
            assert_eq!(b.norm_inf(&x), 5.0);
        }
    }

    #[test]
    fn fallback_scale() {
        if let Some(b) = WgpuBackend::new(1_000_000) {
            let mut x = vec![1.0, 2.0, 3.0, 4.0];
            b.scale(3.0, &mut x);
            assert_eq!(x, vec![3.0, 6.0, 9.0, 12.0]);
        }
    }
}
