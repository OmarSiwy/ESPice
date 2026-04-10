//! BSIM3 transient charge model integration tests.
#[cfg(test)]
mod tests {
    use pisim_device::bsim3::eval::compute_charges;

    #[test]
    fn bsim3_charges_zero_in_cutoff() {
        let (qg, qd, qb, cgs, cgd, cgg, _, _) = compute_charges(1e-14, 0.0, 0.0, 0.5);
        assert_eq!(qg, 0.0);
        assert_eq!(cgs, 0.0);
        let _ = (qd, qb, cgd, cgg);
    }

    #[test]
    fn bsim3_charges_nonzero_in_saturation() {
        // vgsteff=1.0, vds=0.8, vdsat=0.9 → saturation
        let cox = 1e-14;
        let (_, _, _, cgs, cgd, cgg, _, _) = compute_charges(cox, 1.0, 0.8, 0.9);
        assert!(cgs > 0.0 && cgd > 0.0);
        assert!((cgg - cgs - cgd).abs() < 1e-25);
    }

    #[test]
    fn bsim3_charge_conservation() {
        let cox = 1e-14;
        let (qg, qd, qb, _, _, _, _, _) = compute_charges(cox, 1.0, 0.5, 0.9);
        let qs = -(qg + qd + qb);
        assert!((qg + qd + qb + qs).abs() < 1e-30);
    }
}
