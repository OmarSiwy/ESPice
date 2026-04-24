/// Source stepping convergence aid (Gillespie algorithm, matching ngspice).
///
/// When initial Newton-Raphson and GMIN stepping fail, ramp all independent
/// sources from 0 to their final value using adaptive step sizes.
///
/// Algorithm based on ngspice's `gillespie_src()` in `cktop.c`:
/// - Initial raise = 0.001 (0.1% of full source)
/// - Adaptive: fast convergence (≤ITL2/4 iters) → raise *= 1.5
///             slow convergence (>3*ITL2/4 iters) → raise *= 0.5
///             failure → raise /= 10
/// - Minimum raise = 1e-7 before giving up
/// - No extra GMIN during source ramping (only gmin_floor regularization)

/// Static configuration for source stepping (immutable parameters).
#[derive(Debug, Clone)]
pub struct SourceSteppingConfig {
    /// Initial raise size (fraction of full source value).
    /// ngspice default: 0.001
    pub initial_step: f64,
    /// Minimum step size before giving up.
    /// ngspice: 1e-7
    pub min_step: f64,
    /// Max NR iterations per source step.
    /// ngspice ITL2 default: 50
    pub itl2: u32,
    /// Maximum number of lambda steps before giving up.
    pub max_steps: usize,
}

impl Default for SourceSteppingConfig {
    fn default() -> Self {
        Self {
            initial_step: 0.001,
            min_step: 1e-7,
            itl2: 50,
            max_steps: 500,
        }
    }
}

impl SourceSteppingConfig {
    pub fn new(initial_step: f64, min_step: f64) -> Self {
        Self {
            initial_step,
            min_step,
            ..Self::default()
        }
    }

    /// Threshold for "fast" convergence: grow step.
    /// ngspice: ITL2/4
    #[inline]
    pub fn fast_threshold(&self) -> u32 {
        self.itl2 / 4
    }

    /// Threshold for "slow" convergence: shrink step.
    /// ngspice: 3*ITL2/4
    #[inline]
    pub fn slow_threshold(&self) -> u32 {
        3 * self.itl2 / 4
    }
}

/// Stateful adaptive source stepper implementing ngspice's `CKTsrcFact`-style
/// global multiplier with Gillespie adaptive step control.
///
/// This struct tracks the current source factor (`src_fact`, analogous to
/// ngspice's `CKTsrcFact`) and the adaptive raise size. It provides:
///
/// - [`scale()`](SourceStepping::scale): multiply a full source value by the
///   current `src_fact`, ramping sources 0→full during stepping.
/// - [`advance()`](SourceStepping::advance): move to next target and adapt step
///   size based on convergence quality.
/// - [`retreat()`](SourceStepping::retreat): shrink step on failure and restore.
/// - [`target()`](SourceStepping::target): peek at the next target lambda.
#[derive(Debug, Clone)]
pub struct SourceStepping {
    config: SourceSteppingConfig,
    /// Current source factor (analogous to ngspice `CKTsrcFact`).
    /// Ramps from 0.0 to 1.0 during source stepping.
    src_fact: f64,
    /// Current adaptive raise size.
    raise: f64,
    /// Number of steps taken so far.
    steps: usize,
}

impl SourceStepping {
    /// Create a new stepper from configuration, starting at `src_fact = 0`.
    pub fn new(config: SourceSteppingConfig) -> Self {
        let raise = config.initial_step;
        Self {
            config,
            src_fact: 0.0,
            raise,
            steps: 0,
        }
    }

    /// Scale a full source value by the current global source factor.
    ///
    /// During source stepping this ramps sources from 0 to their full value.
    /// At `src_fact = 0.0` all sources are off; at `src_fact = 1.0` they are
    /// at their nominal value. This is the `CKTsrcFact`-style multiplier
    /// that gets wired into device loading.
    #[inline]
    pub fn scale(&self, full_value: f64) -> f64 {
        full_value * self.src_fact
    }

    /// Current source factor (0.0 to 1.0).
    #[inline]
    pub fn src_fact(&self) -> f64 {
        self.src_fact
    }

    /// Set the source factor directly (used for phase 1 at `src_fact = 0`).
    #[inline]
    pub fn set_src_fact(&mut self, fact: f64) {
        self.src_fact = fact.clamp(0.0, 1.0);
    }

    /// Current adaptive raise size.
    #[inline]
    pub fn raise(&self) -> f64 {
        self.raise
    }

    /// Number of steps taken so far.
    #[inline]
    pub fn steps(&self) -> usize {
        self.steps
    }

    /// Maximum NR iterations per step.
    #[inline]
    pub fn itl2(&self) -> u32 {
        self.config.itl2
    }

    /// Whether stepping has reached `src_fact = 1.0` (within tolerance).
    #[inline]
    pub fn is_complete(&self) -> bool {
        self.src_fact >= 1.0 - 1e-12
    }

    /// Whether the step budget is exhausted.
    #[inline]
    pub fn budget_exhausted(&self) -> bool {
        self.steps >= self.config.max_steps
    }

    /// Peek at the next target source factor without advancing.
    #[inline]
    pub fn target(&self) -> f64 {
        (self.src_fact + self.raise).min(1.0)
    }

    /// Advance after a successful NR solve at [`target()`].
    ///
    /// Implements ngspice-style adaptive step control (cktop.c:480-658):
    /// - Fast convergence (iters <= ITL2/4): grow raise by 1.5x
    /// - Slow convergence (iters > 3*ITL2/4): shrink raise by 0.5x
    /// - Normal convergence: keep raise unchanged
    pub fn advance(&mut self, iters: u32) {
        self.src_fact = self.target();
        self.steps += 1;

        let fast = self.config.fast_threshold();
        let slow = self.config.slow_threshold();

        if iters <= fast {
            self.raise *= 1.5;
        } else if iters > slow {
            self.raise *= 0.5;
        }
        // Otherwise keep same raise.
    }

    /// Retreat after a failed NR solve: shrink step by 10x (ngspice cktop.c).
    ///
    /// Also caps raise at 0.01 (ngspice behavior). Returns `false` if the
    /// step is too small to continue (raise < min_step or target can't
    /// advance by 1e-8), meaning the caller should give up.
    pub fn retreat(&mut self) -> bool {
        self.steps += 1;
        self.raise /= 10.0;

        // Cap at 0.01 (ngspice does this on failure).
        if self.raise > 0.01 {
            self.raise = 0.01;
        }

        // Check if we can still make progress.
        let target = (self.src_fact + self.raise).min(1.0);
        if self.raise < self.config.min_step || (target - self.src_fact) < 1e-8 {
            return false;
        }
        true
    }

    /// Access the underlying configuration.
    #[inline]
    pub fn config(&self) -> &SourceSteppingConfig {
        &self.config
    }

    /// Threshold for "fast" convergence: grow step.
    #[inline]
    pub fn fast_threshold(&self) -> u32 {
        self.config.fast_threshold()
    }

    /// Threshold for "slow" convergence: shrink step.
    #[inline]
    pub fn slow_threshold(&self) -> u32 {
        self.config.slow_threshold()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config() {
        let cfg = SourceSteppingConfig::default();
        assert!((cfg.initial_step - 0.001).abs() < 1e-15);
        assert_eq!(cfg.min_step, 1e-7);
        assert_eq!(cfg.itl2, 50);
    }

    #[test]
    fn thresholds() {
        let cfg = SourceSteppingConfig::default();
        assert_eq!(cfg.fast_threshold(), 12); // 50/4
        assert_eq!(cfg.slow_threshold(), 37); // 3*50/4
    }

    #[test]
    fn scale_ramps_with_src_fact() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);

        // At src_fact=0, all sources are off.
        assert_eq!(ss.scale(10.0), 0.0);

        // Set to halfway.
        ss.set_src_fact(0.5);
        assert!((ss.scale(10.0) - 5.0).abs() < 1e-15);

        // Set to full.
        ss.set_src_fact(1.0);
        assert!((ss.scale(10.0) - 10.0).abs() < 1e-15);
    }

    #[test]
    fn scale_full() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        ss.set_src_fact(1.0);
        let v = ss.scale(5.0);
        assert!((v - 5.0).abs() < 1e-15);
    }

    #[test]
    fn scale_zero() {
        let cfg = SourceSteppingConfig::default();
        let ss = SourceStepping::new(cfg);
        assert_eq!(ss.scale(100.0), 0.0);
    }

    #[test]
    fn scale_negative_source() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        ss.set_src_fact(1.0);
        let v = ss.scale(-10.0);
        assert!((v - (-10.0)).abs() < 1e-14);
    }

    #[test]
    fn custom_constructor() {
        let cfg = SourceSteppingConfig::new(0.05, 1e-6);
        assert!((cfg.initial_step - 0.05).abs() < 1e-15);
        assert!((cfg.min_step - 1e-6).abs() < 1e-20);
        assert_eq!(cfg.itl2, 50); // from default
    }

    #[test]
    fn advance_fast_grows_step() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        let initial_raise = ss.raise();

        // Fast convergence: iters <= ITL2/4 = 12
        ss.advance(5);
        assert!((ss.raise() - initial_raise * 1.5).abs() < 1e-15);
        assert!((ss.src_fact() - initial_raise).abs() < 1e-15);
    }

    #[test]
    fn advance_slow_shrinks_step() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        let initial_raise = ss.raise();

        // Slow convergence: iters > 3*ITL2/4 = 37
        ss.advance(40);
        assert!((ss.raise() - initial_raise * 0.5).abs() < 1e-15);
    }

    #[test]
    fn advance_normal_keeps_step() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        let initial_raise = ss.raise();

        // Normal convergence: ITL2/4 < iters <= 3*ITL2/4
        ss.advance(20);
        assert!((ss.raise() - initial_raise).abs() < 1e-15);
    }

    #[test]
    fn retreat_shrinks_by_10x() {
        let cfg = SourceSteppingConfig::default();
        let mut ss = SourceStepping::new(cfg);
        let initial_raise = ss.raise();

        let can_continue = ss.retreat();
        assert!(can_continue);
        assert!((ss.raise() - initial_raise / 10.0).abs() < 1e-15);
        // src_fact should not advance on retreat.
        assert_eq!(ss.src_fact(), 0.0);
    }

    #[test]
    fn retreat_gives_up_at_min_step() {
        let cfg = SourceSteppingConfig::new(1e-7, 1e-7);
        let mut ss = SourceStepping::new(cfg);

        // raise starts at 1e-7, dividing by 10 gives 1e-8 < min_step
        let can_continue = ss.retreat();
        assert!(!can_continue);
    }

    #[test]
    fn full_ramp_completes() {
        let mut cfg = SourceSteppingConfig::default();
        cfg.initial_step = 0.1;
        let mut ss = SourceStepping::new(cfg);

        // Simulate fast convergence at every step.
        while !ss.is_complete() && !ss.budget_exhausted() {
            ss.advance(1); // very fast
        }
        assert!(ss.is_complete());
        assert!((ss.src_fact() - 1.0).abs() < 1e-12);
    }

    #[test]
    fn retreat_caps_at_001() {
        let mut cfg = SourceSteppingConfig::default();
        cfg.initial_step = 0.5; // large initial raise
        let mut ss = SourceStepping::new(cfg);

        let can_continue = ss.retreat();
        assert!(can_continue);
        // 0.5 / 10 = 0.05 > 0.01, so it should be capped at 0.01
        assert!((ss.raise() - 0.01).abs() < 1e-15);
    }

    #[test]
    fn source_stepping_clone() {
        let cfg = SourceSteppingConfig::default();
        let ss = SourceStepping::new(cfg);
        let sc = ss.clone();
        assert_eq!(sc.src_fact(), ss.src_fact());
        assert_eq!(sc.raise(), ss.raise());
    }

    #[test]
    fn source_stepping_debug() {
        let cfg = SourceSteppingConfig::default();
        let ss = SourceStepping::new(cfg);
        let s = format!("{:?}", ss);
        assert!(s.contains("src_fact"));
    }
}
