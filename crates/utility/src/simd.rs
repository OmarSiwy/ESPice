//! # SIMD Batch Operations for SoA Data
//!
//! SIMD (Single Instruction, Multiple Data) processes 4-8 floats in a single CPU instruction.
//! SoA layout is the prerequisite for SIMD: you need contiguous arrays of the same type.
//! AoS layout makes SIMD nearly impossible because fields are interleaved.
//!
//! ## Why SIMD matters
//!
//! A scalar `a += b * dt` loop processes 1 float per instruction.
//! SSE processes 4 floats per instruction (~4x throughput).
//! AVX processes 8 floats per instruction (~8x throughput).
//!
//! ## This module provides
//!
//! - `add_scaled_f32`: `dst[i] += src[i] * scalar` — the physics integration kernel
//! - `mul_f32`: `dst[i] *= scalar` — uniform scaling
//! - `sum_f32`: sum all elements — reductions
//! - `min_f32` / `max_f32`: find extremes
//!
//! All functions fall back to scalar code on platforms without SIMD support.
//! On x86_64, they use SSE2 (128-bit, 4 floats at a time) which is available on
//! every x86_64 CPU since 2001.
//!
//! ## Usage with SoaVec
//!
//! ```rust,no_run
//! use bigospice_utility::simd;
//!
//! // After extracting field slices from your SoaVec:
//! // let positions_x = particles.x_mut();
//! // let velocities_x = particles.vx();
//! // simd::add_scaled_f32(positions_x, velocities_x, dt);
//! ```
//!
//! ## Design philosophy
//!
//! These are intentionally simple, flat functions operating on slices — not methods on
//! a wrapper type. This follows the DOD principle: data transformations are functions
//! that take arrays, not methods on objects. The caller owns the data layout; this module
//! just provides fast kernels.

/// `dst[i] += src[i] * scalar` for all i.
///
/// The fundamental physics integration kernel: position += velocity * dt.
/// Processes 4 floats at a time on x86_64 via SSE2.
///
/// # Panics
/// Panics if `dst.len() != src.len()`.
#[inline]
pub fn add_scaled_f32(dst: &mut [f32], src: &[f32], scalar: f32) {
    assert_eq!(dst.len(), src.len(), "add_scaled_f32: mismatched lengths");

    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = dst.len();
        let chunks = len / 4;

        unsafe {
            let scalar_v = _mm_set1_ps(scalar);
            let dst_ptr = dst.as_mut_ptr();
            let src_ptr = src.as_ptr();

            for i in 0..chunks {
                let offset = i * 4;
                let s = _mm_loadu_ps(src_ptr.add(offset));
                let d = _mm_loadu_ps(dst_ptr.add(offset));
                let result = _mm_add_ps(d, _mm_mul_ps(s, scalar_v));
                _mm_storeu_ps(dst_ptr.add(offset), result);
            }

            // Handle remainder with scalar ops
            let start = chunks * 4;
            for i in start..len {
                *dst.get_unchecked_mut(i) += *src.get_unchecked(i) * scalar;
            }
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        dst.iter_mut()
            .zip(src.iter())
            .for_each(|(d, s)| *d += s * scalar);
    }
}

/// `dst[i] *= scalar` for all i.
///
/// Uniform scaling: scale all velocities, apply drag, etc.
#[inline]
pub fn mul_scalar_f32(dst: &mut [f32], scalar: f32) {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = dst.len();
        let chunks = len / 4;

        unsafe {
            let scalar_v = _mm_set1_ps(scalar);
            let ptr = dst.as_mut_ptr();

            for i in 0..chunks {
                let offset = i * 4;
                let d = _mm_loadu_ps(ptr.add(offset));
                _mm_storeu_ps(ptr.add(offset), _mm_mul_ps(d, scalar_v));
            }

            for i in (chunks * 4)..len {
                *dst.get_unchecked_mut(i) *= scalar;
            }
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        dst.iter_mut().for_each(|d| *d *= scalar);
    }
}

/// `dst[i] = a[i] + b[i]` for all i. Writes result into `dst`.
///
/// Component-wise addition of two arrays.
///
/// # Panics
/// Panics if lengths don't match.
#[inline]
pub fn add_f32(dst: &mut [f32], a: &[f32], b: &[f32]) {
    assert_eq!(a.len(), b.len(), "add_f32: mismatched lengths");
    assert_eq!(dst.len(), a.len(), "add_f32: dst length mismatch");

    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = a.len();
        let chunks = len / 4;

        unsafe {
            for i in 0..chunks {
                let offset = i * 4;
                let va = _mm_loadu_ps(a.as_ptr().add(offset));
                let vb = _mm_loadu_ps(b.as_ptr().add(offset));
                _mm_storeu_ps(dst.as_mut_ptr().add(offset), _mm_add_ps(va, vb));
            }
            for i in (chunks * 4)..len {
                *dst.get_unchecked_mut(i) = *a.get_unchecked(i) + *b.get_unchecked(i);
            }
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        dst.iter_mut()
            .zip(a.iter().zip(b.iter()))
            .for_each(|(d, (a, b))| *d = a + b);
    }
}

/// Sum all elements. Uses SIMD horizontal add for throughput.
#[inline]
pub fn sum_f32(data: &[f32]) -> f32 {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = data.len();
        let chunks = len / 4;

        unsafe {
            let mut acc = _mm_setzero_ps();
            let ptr = data.as_ptr();

            for i in 0..chunks {
                let v = _mm_loadu_ps(ptr.add(i * 4));
                acc = _mm_add_ps(acc, v);
            }

            // Horizontal sum of the 4 floats in acc
            let shuf = _mm_movehdup_ps(acc); // [a1, a1, a3, a3]
            let sums = _mm_add_ps(acc, shuf); // [a0+a1, _, a2+a3, _]
            let shuf = _mm_movehl_ps(sums, sums); // [a2+a3, _, _, _]
            let sum = _mm_add_ss(sums, shuf);
            let mut result = _mm_cvtss_f32(sum);

            // Remainder
            for i in (chunks * 4)..len {
                result += *data.get_unchecked(i);
            }
            result
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        data.iter().sum()
    }
}

/// Find minimum value in a slice. Returns `f32::INFINITY` for empty slices.
#[inline]
pub fn min_f32(data: &[f32]) -> f32 {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = data.len();
        if len == 0 {
            return f32::INFINITY;
        }
        let chunks = len / 4;

        unsafe {
            let mut acc = _mm_set1_ps(f32::INFINITY);
            let ptr = data.as_ptr();

            for i in 0..chunks {
                let v = _mm_loadu_ps(ptr.add(i * 4));
                acc = _mm_min_ps(acc, v);
            }

            // Horizontal min
            let shuf = _mm_movehdup_ps(acc);
            let mins = _mm_min_ps(acc, shuf);
            let shuf = _mm_movehl_ps(mins, mins);
            let min_val = _mm_min_ss(mins, shuf);
            let mut result = _mm_cvtss_f32(min_val);

            for i in (chunks * 4)..len {
                let v = *data.get_unchecked(i);
                if v < result {
                    result = v;
                }
            }
            result
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        data.iter().copied().fold(f32::INFINITY, f32::min)
    }
}

/// Find maximum value in a slice. Returns `f32::NEG_INFINITY` for empty slices.
#[inline]
pub fn max_f32(data: &[f32]) -> f32 {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = data.len();
        if len == 0 {
            return f32::NEG_INFINITY;
        }
        let chunks = len / 4;

        unsafe {
            let mut acc = _mm_set1_ps(f32::NEG_INFINITY);
            let ptr = data.as_ptr();

            for i in 0..chunks {
                let v = _mm_loadu_ps(ptr.add(i * 4));
                acc = _mm_max_ps(acc, v);
            }

            let shuf = _mm_movehdup_ps(acc);
            let maxs = _mm_max_ps(acc, shuf);
            let shuf = _mm_movehl_ps(maxs, maxs);
            let max_val = _mm_max_ss(maxs, shuf);
            let mut result = _mm_cvtss_f32(max_val);

            for i in (chunks * 4)..len {
                let v = *data.get_unchecked(i);
                if v > result {
                    result = v;
                }
            }
            result
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        data.iter().copied().fold(f32::NEG_INFINITY, f32::max)
    }
}

/// Clamp all values in-place to `[min_val, max_val]`.
#[inline]
pub fn clamp_f32(data: &mut [f32], min_val: f32, max_val: f32) {
    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = data.len();
        let chunks = len / 4;

        unsafe {
            let vmin = _mm_set1_ps(min_val);
            let vmax = _mm_set1_ps(max_val);
            let ptr = data.as_mut_ptr();

            for i in 0..chunks {
                let offset = i * 4;
                let v = _mm_loadu_ps(ptr.add(offset));
                let clamped = _mm_min_ps(_mm_max_ps(v, vmin), vmax);
                _mm_storeu_ps(ptr.add(offset), clamped);
            }

            for i in (chunks * 4)..len {
                let v = data.get_unchecked_mut(i);
                *v = v.clamp(min_val, max_val);
            }
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        data.iter_mut().for_each(|v| *v = v.clamp(min_val, max_val));
    }
}

/// Linear interpolation: `dst[i] = a[i] + (b[i] - a[i]) * t`
///
/// Useful for animation blending, smooth transitions between states.
///
/// # Panics
/// Panics if lengths don't match.
#[inline]
pub fn lerp_f32(dst: &mut [f32], a: &[f32], b: &[f32], t: f32) {
    assert_eq!(a.len(), b.len());
    assert_eq!(dst.len(), a.len());

    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = a.len();
        let chunks = len / 4;

        unsafe {
            let vt = _mm_set1_ps(t);
            let one_minus_t = _mm_set1_ps(1.0 - t);

            for i in 0..chunks {
                let offset = i * 4;
                let va = _mm_loadu_ps(a.as_ptr().add(offset));
                let vb = _mm_loadu_ps(b.as_ptr().add(offset));
                // a * (1-t) + b * t  — more numerically stable than a + (b-a)*t
                let result = _mm_add_ps(
                    _mm_mul_ps(va, one_minus_t),
                    _mm_mul_ps(vb, vt),
                );
                _mm_storeu_ps(dst.as_mut_ptr().add(offset), result);
            }

            for i in (chunks * 4)..len {
                *dst.get_unchecked_mut(i) =
                    *a.get_unchecked(i) * (1.0 - t) + *b.get_unchecked(i) * t;
            }
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        dst.iter_mut()
            .zip(a.iter().zip(b.iter()))
            .for_each(|(d, (&a, &b))| *d = a * (1.0 - t) + b * t);
    }
}

/// Dot product of two f32 slices using SIMD.
///
/// # Panics
/// Panics if lengths don't match.
#[inline]
pub fn dot_f32(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len());

    #[cfg(target_arch = "x86_64")]
    {
        use std::arch::x86_64::*;
        let len = a.len();
        let chunks = len / 4;

        unsafe {
            let mut acc = _mm_setzero_ps();

            for i in 0..chunks {
                let offset = i * 4;
                let va = _mm_loadu_ps(a.as_ptr().add(offset));
                let vb = _mm_loadu_ps(b.as_ptr().add(offset));
                acc = _mm_add_ps(acc, _mm_mul_ps(va, vb));
            }

            // Horizontal sum
            let shuf = _mm_movehdup_ps(acc);
            let sums = _mm_add_ps(acc, shuf);
            let shuf = _mm_movehl_ps(sums, sums);
            let sum = _mm_add_ss(sums, shuf);
            let mut result = _mm_cvtss_f32(sum);

            for i in (chunks * 4)..len {
                result += *a.get_unchecked(i) * *b.get_unchecked(i);
            }
            result
        }
    }

    #[cfg(not(target_arch = "x86_64"))]
    {
        a.iter().zip(b.iter()).map(|(a, b)| a * b).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_scaled() {
        let mut dst = vec![1.0f32, 2.0, 3.0, 4.0, 5.0];
        let src = vec![10.0f32, 20.0, 30.0, 40.0, 50.0];
        add_scaled_f32(&mut dst, &src, 0.1);
        assert!((dst[0] - 2.0).abs() < 1e-6);
        assert!((dst[4] - 10.0).abs() < 1e-6);
    }

    #[test]
    fn test_mul_scalar() {
        let mut data = vec![1.0f32, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
        mul_scalar_f32(&mut data, 2.0);
        assert!((data[0] - 2.0).abs() < 1e-6);
        assert!((data[8] - 18.0).abs() < 1e-6);
    }

    #[test]
    fn test_sum() {
        let data = vec![1.0f32, 2.0, 3.0, 4.0, 5.0];
        assert!((sum_f32(&data) - 15.0).abs() < 1e-6);
    }

    #[test]
    fn test_min_max() {
        let data = vec![3.0f32, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0];
        assert!((min_f32(&data) - 1.0).abs() < 1e-6);
        assert!((max_f32(&data) - 9.0).abs() < 1e-6);
    }

    #[test]
    fn test_clamp() {
        let mut data = vec![-1.0f32, 0.5, 1.5, 3.0, -0.5];
        clamp_f32(&mut data, 0.0, 1.0);
        assert_eq!(data, vec![0.0, 0.5, 1.0, 1.0, 0.0]);
    }

    #[test]
    fn test_lerp() {
        let a = vec![0.0f32, 10.0, 20.0, 30.0, 40.0];
        let b = vec![100.0f32, 110.0, 120.0, 130.0, 140.0];
        let mut dst = vec![0.0f32; 5];
        lerp_f32(&mut dst, &a, &b, 0.5);
        assert!((dst[0] - 50.0).abs() < 1e-4);
        assert!((dst[4] - 90.0).abs() < 1e-4);
    }

    #[test]
    fn test_dot() {
        let a = vec![1.0f32, 2.0, 3.0, 4.0, 5.0];
        let b = vec![5.0f32, 4.0, 3.0, 2.0, 1.0];
        // 5 + 8 + 9 + 8 + 5 = 35
        assert!((dot_f32(&a, &b) - 35.0).abs() < 1e-4);
    }

    #[test]
    fn test_empty_slices() {
        let empty: Vec<f32> = vec![];
        assert_eq!(sum_f32(&empty), 0.0);
        assert_eq!(min_f32(&empty), f32::INFINITY);
        assert_eq!(max_f32(&empty), f32::NEG_INFINITY);
    }
}
