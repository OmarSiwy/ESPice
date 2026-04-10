/// SIMD-friendly complex number array stored as separate real/imaginary arrays.
///
/// Data-oriented layout: `re[0..n]` then `im[0..n]` instead of interleaved
/// `[(re,im), (re,im), ...]`. This lets the compiler auto-vectorize operations
/// on all real parts in one pass and all imaginary parts in another.
#[derive(Debug, Clone)]
pub struct SimdComplex {
    pub re: Vec<f64>,
    pub im: Vec<f64>,
}

impl SimdComplex {
    pub fn zeros(n: usize) -> Self {
        Self {
            re: vec![0.0; n],
            im: vec![0.0; n],
        }
    }

    pub fn from_real(re: Vec<f64>) -> Self {
        let n = re.len();
        Self {
            re,
            im: vec![0.0; n],
        }
    }

    pub fn from_parts(re: Vec<f64>, im: Vec<f64>) -> Self {
        assert_eq!(re.len(), im.len());
        Self { re, im }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.re.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.re.is_empty()
    }

    /// `self += alpha * other` where alpha is real.
    pub fn axpy_real(&mut self, alpha: f64, other: &Self) {
        assert_eq!(self.len(), other.len());
        self.re.iter_mut()
            .zip(other.re.iter())
            .for_each(|(dst, &src)| *dst += alpha * src);
        self.im.iter_mut()
            .zip(other.im.iter())
            .for_each(|(dst, &src)| *dst += alpha * src);
    }

    /// Complex multiply: `self[i] = self[i] * other[i]`.
    /// (a+bi)(c+di) = (ac-bd) + (ad+bc)i
    pub fn mul_assign(&mut self, other: &Self) {
        assert_eq!(self.len(), other.len());
        let n = self.len();

        for i in 0..n {
            let a = self.re[i];
            let b = self.im[i];
            let c = other.re[i];
            let d = other.im[i];
            self.re[i] = a * c - b * d;
            self.im[i] = a * d + b * c;
        }
    }

    /// Magnitude: `sqrt(re^2 + im^2)` per element.
    pub fn magnitude(&self) -> Vec<f64> {
        self.re.iter()
            .zip(self.im.iter())
            .map(|(&r, &i)| (r * r + i * i).sqrt())
            .collect()
    }

    /// Phase angle in radians: `atan2(im, re)` per element.
    pub fn phase(&self) -> Vec<f64> {
        self.im.iter()
            .zip(self.re.iter())
            .map(|(&i, &r)| i.atan2(r))
            .collect()
    }

    /// Magnitude in decibels: `20 * log10(|z|)`.
    pub fn magnitude_db(&self) -> Vec<f64> {
        self.magnitude().iter().map(|&m| 20.0 * m.max(1e-300).log10()).collect()
    }

    /// Scale all elements by a real scalar.
    pub fn scale(&mut self, alpha: f64) {
        self.re.iter_mut().for_each(|v| *v *= alpha);
        self.im.iter_mut().for_each(|v| *v *= alpha);
    }

    /// Conjugate in place: negate imaginary parts.
    pub fn conjugate(&mut self) {
        self.im.iter_mut().for_each(|v| *v = -*v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    #[test]
    fn zeros_has_zero() {
        let c = SimdComplex::zeros(8);
        assert!(c.re.iter().all(|&v| v == 0.0));
        assert!(c.im.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn from_real() {
        let c = SimdComplex::from_real(vec![1.0, 2.0, 3.0]);
        assert_eq!(c.re, vec![1.0, 2.0, 3.0]);
        assert!(c.im.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn magnitude_real_only() {
        let c = SimdComplex::from_real(vec![3.0, -4.0, 0.0, 5.0, 1.0]);
        let mag = c.magnitude();
        assert!((mag[0] - 3.0).abs() < 1e-12);
        assert!((mag[1] - 4.0).abs() < 1e-12);
        assert!((mag[2]).abs() < 1e-12);
    }

    #[test]
    fn magnitude_complex() {
        let c = SimdComplex::from_parts(vec![3.0, 0.0], vec![4.0, 1.0]);
        let mag = c.magnitude();
        assert!((mag[0] - 5.0).abs() < 1e-12);
        assert!((mag[1] - 1.0).abs() < 1e-12);
    }

    #[test]
    fn phase_basic() {
        let c = SimdComplex::from_parts(vec![1.0, 0.0, -1.0], vec![0.0, 1.0, 0.0]);
        let ph = c.phase();
        assert!((ph[0]).abs() < 1e-12);
        assert!((ph[1] - PI / 2.0).abs() < 1e-12);
        assert!((ph[2] - PI).abs() < 1e-12);
    }

    #[test]
    fn complex_multiply() {
        // (1+2i) * (3+4i) = (3-8) + (4+6)i = -5 + 10i
        let mut a = SimdComplex::from_parts(vec![1.0], vec![2.0]);
        let b = SimdComplex::from_parts(vec![3.0], vec![4.0]);
        a.mul_assign(&b);
        assert!((a.re[0] - (-5.0)).abs() < 1e-12);
        assert!((a.im[0] - 10.0).abs() < 1e-12);
    }

    #[test]
    fn complex_multiply_batch() {
        let mut a = SimdComplex::from_parts(vec![1.0; 7], vec![1.0; 7]);
        let b = SimdComplex::from_parts(vec![1.0; 7], vec![-1.0; 7]);
        // (1+i)(1-i) = 1+1 = 2+0i
        a.mul_assign(&b);
        for i in 0..7 {
            assert!((a.re[i] - 2.0).abs() < 1e-12);
            assert!(a.im[i].abs() < 1e-12);
        }
    }

    #[test]
    fn axpy_real_scaling() {
        let mut a = SimdComplex::from_parts(vec![1.0; 5], vec![2.0; 5]);
        let b = SimdComplex::from_parts(vec![3.0; 5], vec![4.0; 5]);
        a.axpy_real(2.0, &b);
        assert!(a.re.iter().all(|&v| (v - 7.0).abs() < 1e-12));
        assert!(a.im.iter().all(|&v| (v - 10.0).abs() < 1e-12));
    }

    #[test]
    fn conjugate() {
        let mut c = SimdComplex::from_parts(vec![1.0, 2.0], vec![3.0, 4.0]);
        c.conjugate();
        assert_eq!(c.re, vec![1.0, 2.0]);
        assert!((c.im[0] - (-3.0)).abs() < 1e-12);
        assert!((c.im[1] - (-4.0)).abs() < 1e-12);
    }

    #[test]
    fn magnitude_db() {
        let c = SimdComplex::from_real(vec![1.0, 10.0, 100.0]);
        let db = c.magnitude_db();
        assert!((db[0]).abs() < 1e-10);
        assert!((db[1] - 20.0).abs() < 1e-10);
        assert!((db[2] - 40.0).abs() < 1e-10);
    }
}
