// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Hand-port of the BSIM4.8.3 model card parameter set into a flat,
// `Copy`-able struct.  This is the *cold tier*: every value comes straight
// out of the user's `.MODEL` card with no per-instance binning, geometry
// scaling, or temperature pre-compute applied yet (those happen in
// `instance.rs` and `temp.rs`).
//
// The full Berkeley parameter set is ~500 entries.  We carry every name
// the simulator may need to evaluate the DC load path; cap-only and
// noise-only parameters are still parsed but stored unused so that any
// vendor PDK card loads cleanly.
//
// References (READ-ONLY for algorithmic intent):
//   tests/external/ngspice/src/spicelib/devices/bsim4/bsim4def.h
//   tests/external/ngspice/src/spicelib/devices/bsim4/b4mpar.c

#![allow(non_snake_case, dead_code)]

use pisim_core::ParamMap;

/// Polarity of a BSIM4 device: +1 for NMOS, -1 for PMOS.
///
/// Stored as f64 so it can multiply directly into the bias polarity
/// equations without branching.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Bsim4Type {
    Nmos,
    Pmos,
}

impl Bsim4Type {
    #[inline]
    pub fn polarity(self) -> f64 {
        match self {
            Bsim4Type::Nmos => 1.0,
            Bsim4Type::Pmos => -1.0,
        }
    }
}

/// Boolean flags / mode selectors that the user picks per `.MODEL` card.
///
/// Mirrors the `int BSIM4XxxMod;` fields in `bsim4def.h`.  All defaults
/// match Berkeley `BSIM4checkModel` after `BSIM4mpar`.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4ModelFlags {
    pub mobMod:     i32,    // 0..6 mobility model selector (default 0)
    pub capMod:     i32,    // 0..2 capacitance model selector (default 2)
    pub diomod:     i32,    // 0..2 source/drain diode model
    pub rdsmod:     i32,    // 0/1 internal Rds model
    pub trnqsmod:   i32,    // 0/1 transient NQS
    pub acnqsmod:   i32,    // 0/1 AC NQS
    pub fnoimod:    i32,    // 0/1 flicker noise model
    pub tnoimod:    i32,    // 0/1/2 thermal noise model
    pub rbodymod:   i32,    // 0/1/2 substrate network
    pub rgatemod:   i32,    // 0..3 gate resistance network
    pub permod:     i32,    // 0/1 perimeter model
    pub geomod:     i32,    // 0..10 geometry model
    pub rgeomod:    i32,    // 0..2 R(W) geometry
    pub igcmod:     i32,    // 0..2 channel gate tunneling
    pub igbmod:     i32,    // 0/1 substrate gate tunneling
    pub mtrlmod:    i32,    // 0/1 alternative gate-stack material
    pub mtrlcompatmod: i32, // 0/1 4.7 compatibility
    pub gidlmod:    i32,    // 0/1 GIDL/GISL extended model
}

impl Default for Bsim4ModelFlags {
    fn default() -> Self {
        // Berkeley BSIM4.8.3 defaults from b4mpar.c.
        Self {
            mobMod:    0,
            capMod:    2,
            diomod:    1,
            rdsmod:    0,
            trnqsmod:  0,
            acnqsmod:  0,
            fnoimod:   1,
            tnoimod:   0,
            rbodymod:  0,
            rgatemod:  0,
            permod:    1,
            geomod:    0,
            rgeomod:   0,
            igcmod:    0,
            igbmod:    0,
            mtrlmod:   0,
            mtrlcompatmod: 0,
            gidlmod:   0,
        }
    }
}

/// The full BSIM4.8.3 model-card parameter struct (cold tier).
///
/// Every value here is dimensionally identical to the corresponding
/// `pParam->BSIM4*` / `model->BSIM4*` field in Berkeley.  We do **not**
/// store the per-instance binning corrections (`l*`, `w*`, `p*`); those
/// live in [`crate::bsim4::instance::Bsim4Instance`] after binning.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4ModelParams {
    // ── identity ─────────────────────────────────────────────────────────
    pub mos_type:   Bsim4Type,
    pub flags:      Bsim4ModelFlags,
    pub version:    f64,    // 4.83
    pub level:      i32,    // 14 (alias 54)

    // ── process / oxide / substrate ──────────────────────────────────────
    pub tnom:       f64,    // K
    pub epsrox:     f64,    // SiO2 dielectric constant (default 3.9)
    pub epsrsub:    f64,    // Si  (default 11.7)
    pub easub:      f64,    // electron affinity Si
    pub ni0sub:     f64,    // intrinsic carrier conc.
    pub bg0sub:     f64,    // bandgap @ 0K
    pub tbgasub:    f64,    // bandgap T-coeff
    pub tbgbsub:    f64,
    pub toxe:       f64,    // electrical oxide thickness
    pub toxp:       f64,    // physical oxide thickness
    pub toxm:       f64,    // tox at which params extracted
    pub dtox:       f64,    // tox bias dependence
    pub xj:         f64,    // junction depth
    pub gamma1:     f64,
    pub gamma2:     f64,
    pub ndep:       f64,    // channel doping
    pub nsub:       f64,    // substrate doping
    pub nsd:        f64,    // S/D doping
    pub vbm:        f64,    // max applied body bias
    pub xt:         f64,    // doping depth
    pub vbx:        f64,    // body bias for full depletion
    pub phi:        f64,    // 2*phi_F (auto-computed if not given)

    // ── threshold voltage ────────────────────────────────────────────────
    pub vth0:       f64,    // long-channel zero-Vbs threshold
    pub vfb:        f64,    // flat-band voltage
    pub k1:         f64,    // 1st-order body-effect coeff
    pub k2:         f64,    // 2nd-order body-effect
    pub k3:         f64,    // narrow-width
    pub k3b:        f64,    // narrow-width Vbs coeff
    pub w0:         f64,    // narrow-width param
    pub lpe0:       f64,    // pocket-implant @ Vbs=0
    pub lpeb:       f64,    // pocket-implant Vbs term
    pub dvt0:       f64,    // SCE coeff
    pub dvt1:       f64,
    pub dvt2:       f64,
    pub dvt0w:      f64,    // narrow-width SCE
    pub dvt1w:      f64,
    pub dvt2w:      f64,
    pub dsub:       f64,    // DIBL exp coefficient
    pub eta0:       f64,    // DIBL coefficient
    pub etab:       f64,    // DIBL Vbs coefficient
    pub minv:       f64,    // sub-threshold-strong-inv smoothing
    pub minvcv:     f64,
    pub voff:       f64,    // sub-threshold offset
    pub voffl:      f64,    // L-dependent offset
    pub voffcv:     f64,
    pub voffcvl:    f64,
    pub nfactor:    f64,    // sub-threshold swing factor
    pub cdsc:       f64,    // S/D coupling factor
    pub cdscb:      f64,
    pub cdscd:      f64,
    pub cit:        f64,    // interface trap cap
    pub vfbsdoff:   f64,    // S/D vfb offset

    // ── mobility ────────────────────────────────────────────────────────
    pub u0:         f64,    // low-field mobility
    pub ua:         f64,
    pub ub:         f64,
    pub uc:         f64,
    pub ud:         f64,
    pub eu:         f64,
    pub ucs:        f64,
    pub vsat:       f64,    // saturation velocity
    pub a0:         f64,    // Abulk param
    pub ags:        f64,    // gate-bias Abulk dependence
    pub b0:         f64,
    pub b1:         f64,
    pub keta:       f64,
    pub a1:         f64,
    pub a2:         f64,
    pub rdsw:       f64,    // S/D parasitic R per width
    pub rdswmin:    f64,
    pub rdw:        f64,
    pub rdwmin:     f64,
    pub rsw:        f64,
    pub rswmin:     f64,
    pub prwg:       f64,    // gate bias coefficient
    pub prwb:       f64,    // body bias coefficient
    pub wr:         f64,
    pub nf:         f64,    // number of fingers (instance, but mirror)
    pub mstar:      f64,
    pub vgsteffvth: f64,
    pub vfbsd:      f64,

    // ── output / CLM / SCBE / DIBL2 / etc ────────────────────────────────
    pub pclm:       f64,    // CLM coefficient
    pub pdiblc1:    f64,
    pub pdiblc2:    f64,
    pub pdiblcb:    f64,
    pub drout:      f64,    // DIBL exp T1 coefficient
    pub pscbe1:     f64,    // SCBE coefficients
    pub pscbe2:     f64,
    pub pvag:       f64,    // gate bias dep of Early V
    pub delta:      f64,    // Vds smoothing
    pub fprout:     f64,
    pub pdits:      f64,    // DITS coefficient
    pub pditsd:     f64,
    pub pditsl:     f64,    // L-dependent DITS

    // ── GIDL / GISL ──────────────────────────────────────────────────────
    pub agidl:      f64,
    pub bgidl:      f64,
    pub cgidl:      f64,
    pub egidl:      f64,
    pub fgidl:      f64,
    pub kgidl:      f64,
    pub rgidl:      f64,
    pub agisl:      f64,
    pub bgisl:      f64,
    pub cgisl:      f64,
    pub egisl:      f64,
    pub fgisl:      f64,
    pub kgisl:      f64,
    pub rgisl:      f64,

    // ── gate tunneling ──────────────────────────────────────────────────
    pub aigbacc:    f64,
    pub bigbacc:    f64,
    pub cigbacc:    f64,
    pub nigbacc:    f64,
    pub aigbinv:    f64,
    pub bigbinv:    f64,
    pub cigbinv:    f64,
    pub eigbinv:    f64,
    pub nigbinv:    f64,
    pub aigc:       f64,
    pub bigc:       f64,
    pub cigc:       f64,
    pub aigsd:      f64,
    pub bigsd:      f64,
    pub cigsd:      f64,
    pub aigs:       f64,
    pub bigs:       f64,
    pub cigs:       f64,
    pub aigd:       f64,
    pub bigd:       f64,
    pub cigd:       f64,
    pub dlcig:      f64,
    pub dlcigd:     f64,
    pub nigc:       f64,
    pub poxedge:    f64,
    pub pigcd:      f64,
    pub ntox:       f64,
    pub toxref:     f64,

    // ── source/drain junction diodes ─────────────────────────────────────
    pub jss:        f64,
    pub jsws:       f64,
    pub jswgs:      f64,
    pub jsd:        f64,
    pub jswd:       f64,
    pub jswgd:      f64,
    pub njs:        f64,
    pub njd:        f64,
    pub xtis:       f64,
    pub xtid:       f64,
    pub bvs:        f64,
    pub bvd:        f64,
    pub xjbvs:      f64,
    pub xjbvd:      f64,
    pub ijthsfwd:   f64,
    pub ijthdfwd:   f64,
    pub ijthsrev:   f64,
    pub ijthdrev:   f64,
    pub tnjs:       f64,
    pub tnjd:       f64,

    // ── temperature scaling ─────────────────────────────────────────────
    pub kt1:        f64,
    pub kt1l:       f64,
    pub kt2:        f64,
    pub ute:        f64,
    pub ucste:      f64,
    pub ua1:        f64,
    pub ub1:        f64,
    pub uc1:        f64,
    pub ud1:        f64,
    pub at:         f64,
    pub prt:        f64,
    pub xtssws:     f64,
    pub xtsswgs:    f64,
    pub xtsswd:     f64,
    pub xtsswgd:    f64,
    pub tcjswgs:    f64,
    pub tcjswgd:    f64,
    pub tpbswgs:    f64,
    pub tpbswgd:    f64,
    pub tcjswd:     f64,
    pub tpbswd:     f64,
    pub tcj:        f64,
    pub tpb:        f64,
    pub tcjsw:      f64,
    pub tpbsw:      f64,

    // ── overlap / fringe / gate caps (parsed but DC-irrelevant) ─────────
    pub cgso:       f64,
    pub cgdo:       f64,
    pub cgbo:       f64,
    pub cgdl:       f64,
    pub cgsl:       f64,
    pub cf:         f64,
    pub ckappas:    f64,
    pub ckappad:    f64,
    pub clc:        f64,
    pub cle:        f64,
    pub dwc:        f64,
    pub dlc:        f64,
    pub xw:         f64,    // W bias / etch
    pub xl:         f64,    // L bias / etch
    pub dwj:        f64,
    pub wint:       f64,
    pub lint:       f64,
    pub ll:         f64,
    pub wl:         f64,
    pub lln:        f64,
    pub wln:        f64,
    pub lw:         f64,
    pub ww:         f64,
    pub lwn:        f64,
    pub wwn:        f64,
    pub lwl:        f64,
    pub wwl:        f64,
    pub xpart:      f64,    // 0/0.5/1 partition
    pub moin:       f64,
    pub noff:       f64,
    pub voffcvref:  f64,
    pub acde:       f64,

    // ── thermal / flicker noise (parsed) ────────────────────────────────
    pub noia:       f64,
    pub noib:       f64,
    pub noic:       f64,
    pub em:         f64,
    pub ef:         f64,
    pub af:         f64,
    pub kf:         f64,
    pub ntnoi:      f64,
    pub rnoia:      f64,
    pub rnoib:      f64,
    pub rnoic:      f64,
    pub tnoia:      f64,
    pub tnoib:      f64,
    pub tnoic:      f64,
    pub lintnoi:    f64,

    // ── well / DTMOS / RBODY / RGATE ─────────────────────────────────────
    pub rshg:       f64,
    pub gbmin:      f64,
    pub rbpb:       f64,
    pub rbpd:       f64,
    pub rbps:       f64,
    pub rbdb:       f64,
    pub rbsb:       f64,
    pub ngcon:      f64,
    pub xgw:        f64,
    pub xgl:        f64,

    // ── stress effect / well proximity (parsed) ──────────────────────────
    pub saref:      f64,
    pub sbref:      f64,
    pub wlod:       f64,
    pub ku0:        f64,
    pub kvsat:      f64,
    pub kvth0:      f64,
    pub tku0:       f64,
    pub llodku0:    f64,
    pub wlodku0:    f64,
    pub llodvth:    f64,
    pub wlodvth:    f64,
    pub lku0:       f64,
    pub wku0:       f64,
    pub pku0:       f64,
    pub lkvth0:     f64,
    pub wkvth0:     f64,
    pub pkvth0:     f64,
    pub stk2:       f64,
    pub lodk2:      f64,
    pub steta0:     f64,
    pub lodeta0:    f64,
    pub web:        f64,
    pub wec:        f64,
    pub kvth0we:    f64,
    pub k2we:       f64,
    pub ku0we:      f64,
    pub scref:      f64,
    pub wpemod:     i32,
}

impl Default for Bsim4ModelParams {
    fn default() -> Self {
        // Berkeley BSIM4.8.3 default values from b4set.c / b4mpar.c.
        // PHYSICAL CONSTANTS USED:
        //   q  = 1.6021918e-19 C
        //   k  = 1.3806226e-23 J/K
        //   ε0 = 8.8542148e-12 F/m
        //   εSiO2 = 3.453143e-11 F/m  (3.9 * ε0)
        Self {
            mos_type: Bsim4Type::Nmos,
            flags:    Bsim4ModelFlags::default(),
            version:  4.83,
            level:    14,

            tnom:     300.15,
            epsrox:   3.9,
            epsrsub:  11.7,
            easub:    4.05,
            ni0sub:   1.45e10,
            bg0sub:   1.16,
            tbgasub:  7.02e-4,
            tbgbsub:  1108.0,
            toxe:     3.0e-9,
            toxp:     3.0e-9,
            toxm:     3.0e-9,
            dtox:     0.0,
            xj:       1.5e-7,
            gamma1:   0.0,
            gamma2:   0.0,
            ndep:     1.7e17,
            nsub:     6.0e16,
            nsd:      1.0e20,
            vbm:      -3.0,
            xt:       1.55e-7,
            vbx:      0.0,
            phi:      0.0,    // computed in temp.rs

            vth0:     0.7,
            vfb:      -1.0,   // computed if vth0 specified
            k1:       0.53,
            k2:       -0.0186,
            k3:       80.0,
            k3b:      0.0,
            w0:       2.5e-6,
            lpe0:     1.74e-7,
            lpeb:     0.0,
            dvt0:     2.2,
            dvt1:     0.53,
            dvt2:     -0.032,
            dvt0w:    0.0,
            dvt1w:    5.3e6,
            dvt2w:    -0.032,
            dsub:     0.56,    // = drout default
            eta0:     0.08,
            etab:     -0.07,
            minv:     0.0,
            minvcv:   0.0,
            voff:     -0.08,
            voffl:    0.0,
            voffcv:   0.0,
            voffcvl:  0.0,
            nfactor:  1.0,
            cdsc:     2.4e-4,
            cdscb:    0.0,
            cdscd:    0.0,
            cit:      0.0,
            vfbsdoff: 0.0,

            u0:       0.067,
            ua:       1.0e-9,
            ub:       1.0e-19,
            uc:       0.0,
            ud:       0.0,
            eu:       1.67,
            ucs:      1.67,
            vsat:     8.0e4,
            a0:       1.0,
            ags:      0.0,
            b0:       0.0,
            b1:       0.0,
            keta:     -0.047,
            a1:       0.0,
            a2:       1.0,
            rdsw:     200.0,
            rdswmin:  0.0,
            rdw:      100.0,
            rdwmin:   0.0,
            rsw:      100.0,
            rswmin:   0.0,
            prwg:     1.0,
            prwb:     0.0,
            wr:       1.0,
            nf:       1.0,
            mstar:    0.5,
            vgsteffvth: 0.07,
            vfbsd:    0.0,

            pclm:     1.3,
            pdiblc1:  0.39,
            pdiblc2:  0.0086,
            pdiblcb:  0.0,
            drout:    0.56,
            pscbe1:   4.24e8,
            pscbe2:   1.0e-5,
            pvag:     0.0,
            delta:    0.01,
            fprout:   0.0,
            pdits:    0.0,
            pditsd:   0.0,
            pditsl:   0.0,

            agidl:    0.0,
            bgidl:    2.3e9,
            cgidl:    0.5,
            egidl:    0.8,
            fgidl:    0.0,
            kgidl:    0.0,
            rgidl:    1.0,
            agisl:    0.0,
            bgisl:    2.3e9,
            cgisl:    0.5,
            egisl:    0.8,
            fgisl:    0.0,
            kgisl:    0.0,
            rgisl:    1.0,

            aigbacc:  1.36e-2,
            bigbacc:  1.71e-3,
            cigbacc:  0.075,
            nigbacc:  1.0,
            aigbinv:  1.11e-2,
            bigbinv:  9.49e-4,
            cigbinv:  0.006,
            eigbinv:  1.1,
            nigbinv:  3.0,
            aigc:     0.0,    // = aigbacc for NMOS, aigbinv for PMOS
            bigc:     0.0,
            cigc:     0.0,
            aigsd:    0.0,
            bigsd:    0.0,
            cigsd:    0.0,
            aigs:     0.0,
            bigs:     0.0,
            cigs:     0.0,
            aigd:     0.0,
            bigd:     0.0,
            cigd:     0.0,
            dlcig:    0.0,
            dlcigd:   0.0,
            nigc:     1.0,
            poxedge:  1.0,
            pigcd:    1.0,
            ntox:     1.0,
            toxref:   3.0e-9,

            jss:      1.0e-4,
            jsws:     0.0,
            jswgs:    0.0,
            jsd:      1.0e-4,
            jswd:     0.0,
            jswgd:    0.0,
            njs:      1.0,
            njd:      1.0,
            xtis:     3.0,
            xtid:     3.0,
            bvs:      10.0,
            bvd:      10.0,
            xjbvs:    1.0,
            xjbvd:    1.0,
            ijthsfwd: 0.1,
            ijthdfwd: 0.1,
            ijthsrev: 0.1,
            ijthdrev: 0.1,
            tnjs:     0.0,
            tnjd:     0.0,

            kt1:      -0.11,
            kt1l:     0.0,
            kt2:      0.022,
            ute:      -1.5,
            ucste:    -4.775e-3,
            ua1:      1.0e-9,
            ub1:      -1.0e-18,
            uc1:      0.067,
            ud1:      0.0,
            at:       3.3e4,
            prt:      0.0,
            xtssws:   3.0,
            xtsswgs:  3.0,
            xtsswd:   3.0,
            xtsswgd:  3.0,
            tcjswgs:  0.0,
            tcjswgd:  0.0,
            tpbswgs:  0.0,
            tpbswgd:  0.0,
            tcjswd:   0.0,
            tpbswd:   0.0,
            tcj:      0.0,
            tpb:      0.0,
            tcjsw:    0.0,
            tpbsw:    0.0,

            cgso:     0.0,
            cgdo:     0.0,
            cgbo:     0.0,
            cgdl:     0.0,
            cgsl:     0.0,
            cf:       0.0,
            ckappas:  0.6,
            ckappad:  0.6,
            clc:      1.0e-7,
            cle:      0.6,
            dwc:      0.0,
            dlc:      0.0,
            xw:       0.0,
            xl:       0.0,
            dwj:      0.0,
            wint:     0.0,
            lint:     0.0,
            ll:       0.0,
            wl:       0.0,
            lln:      1.0,
            wln:      1.0,
            lw:       0.0,
            ww:       0.0,
            lwn:      1.0,
            wwn:      1.0,
            lwl:      0.0,
            wwl:      0.0,
            xpart:    0.0,
            moin:     15.0,
            noff:     1.0,
            voffcvref: 0.0,
            acde:     1.0,

            noia:     6.25e41,
            noib:     3.125e26,
            noic:     8.75e9,
            em:       4.1e7,
            ef:       1.0,
            af:       1.0,
            kf:       0.0,
            ntnoi:    1.0,
            rnoia:    0.577,
            rnoib:    0.5164,
            rnoic:    0.395,
            tnoia:    1.5,
            tnoib:    3.5,
            tnoic:    0.0,
            lintnoi:  0.0,

            rshg:     0.1,
            gbmin:    1.0e-12,
            rbpb:     50.0,
            rbpd:     50.0,
            rbps:     50.0,
            rbdb:     50.0,
            rbsb:     50.0,
            ngcon:    1.0,
            xgw:      0.0,
            xgl:      0.0,

            saref:    1.0e-6,
            sbref:    1.0e-6,
            wlod:     0.0,
            ku0:      0.0,
            kvsat:    0.0,
            kvth0:    0.0,
            tku0:     0.0,
            llodku0:  0.0,
            wlodku0:  0.0,
            llodvth:  0.0,
            wlodvth:  0.0,
            lku0:     0.0,
            wku0:     0.0,
            pku0:     0.0,
            lkvth0:   0.0,
            wkvth0:   0.0,
            pkvth0:   0.0,
            stk2:     0.0,
            lodk2:    1.0,
            steta0:   0.0,
            lodeta0:  1.0,
            web:      0.0,
            wec:      0.0,
            kvth0we:  0.0,
            k2we:     0.0,
            ku0we:    0.0,
            scref:    1.0e-6,
            wpemod:   0,
        }
    }
}

impl Bsim4ModelParams {
    /// Build a `Bsim4ModelParams` from a `ParamMap`.  Anything missing
    /// falls back to the default.  Aliased names (`vto` ↔ `vth0`) are
    /// resolved here.
    ///
    /// Following b4mpar.c → BSIM4mpar.
    pub fn from_map(map: &ParamMap, mos_type: Bsim4Type) -> Self {
        let d = Bsim4ModelParams::default();
        // Helper to read either canonical or alias name.
        let g = |k: &str, dv: f64| map.get_or(k, dv);
        let g2 = |k1: &str, k2: &str, dv: f64| map.get(k1).or_else(|| map.get(k2)).unwrap_or(dv);
        let gi = |k: &str, dv: i32| map.get(k).map(|v| v as i32).unwrap_or(dv);

        let mut p = d;
        p.mos_type = mos_type;

        // Mode flags
        p.flags.mobMod    = gi("mobmod", d.flags.mobMod);
        p.flags.capMod    = gi("capmod", d.flags.capMod);
        p.flags.diomod    = gi("diomod", d.flags.diomod);
        p.flags.rdsmod    = gi("rdsmod", d.flags.rdsmod);
        p.flags.trnqsmod  = gi("trnqsmod", d.flags.trnqsmod);
        p.flags.acnqsmod  = gi("acnqsmod", d.flags.acnqsmod);
        p.flags.fnoimod   = gi("fnoimod", d.flags.fnoimod);
        p.flags.tnoimod   = gi("tnoimod", d.flags.tnoimod);
        p.flags.rbodymod  = gi("rbodymod", d.flags.rbodymod);
        p.flags.rgatemod  = gi("rgatemod", d.flags.rgatemod);
        p.flags.permod    = gi("permod", d.flags.permod);
        p.flags.geomod    = gi("geomod", d.flags.geomod);
        p.flags.rgeomod   = gi("rgeomod", d.flags.rgeomod);
        p.flags.igcmod    = gi("igcmod", d.flags.igcmod);
        p.flags.igbmod    = gi("igbmod", d.flags.igbmod);
        p.flags.mtrlmod   = gi("mtrlmod", d.flags.mtrlmod);
        p.flags.gidlmod   = gi("gidlmod", d.flags.gidlmod);

        p.version = g("version", d.version);
        p.level   = gi("level", d.level);

        // Process / oxide
        p.tnom    = g2("tnom", "tref", d.tnom);
        p.epsrox  = g("epsrox", d.epsrox);
        p.epsrsub = g("epsrsub", d.epsrsub);
        p.toxe    = g("toxe", d.toxe);
        p.toxp    = g("toxp", p.toxe);
        p.toxm    = g("toxm", p.toxe);
        p.dtox    = g("dtox", d.dtox);
        p.xj      = g("xj", d.xj);
        p.ndep    = g("ndep", d.ndep);
        p.nsub    = g("nsub", d.nsub);
        p.nsd     = g("nsd", d.nsd);
        p.xt      = g("xt", d.xt);
        p.vbm     = g("vbm", d.vbm);
        p.phi     = g("phi", 0.0);

        // Vth
        p.vth0    = g2("vth0", "vto", d.vth0);
        p.vfb     = g("vfb", d.vfb);
        p.k1      = g("k1", d.k1);
        p.k2      = g("k2", d.k2);
        p.k3      = g("k3", d.k3);
        p.k3b     = g("k3b", d.k3b);
        p.w0      = g("w0", d.w0);
        p.lpe0    = g("lpe0", d.lpe0);
        p.lpeb    = g("lpeb", d.lpeb);
        p.dvt0    = g("dvt0", d.dvt0);
        p.dvt1    = g("dvt1", d.dvt1);
        p.dvt2    = g("dvt2", d.dvt2);
        p.dvt0w   = g("dvt0w", d.dvt0w);
        p.dvt1w   = g("dvt1w", d.dvt1w);
        p.dvt2w   = g("dvt2w", d.dvt2w);
        p.dsub    = g("dsub", d.drout);  // dsub defaults to drout
        p.eta0    = g("eta0", d.eta0);
        p.etab    = g("etab", d.etab);
        p.minv    = g("minv", d.minv);
        p.voff    = g("voff", d.voff);
        p.voffl   = g("voffl", d.voffl);
        p.nfactor = g("nfactor", d.nfactor);
        p.cdsc    = g("cdsc", d.cdsc);
        p.cdscb   = g("cdscb", d.cdscb);
        p.cdscd   = g("cdscd", d.cdscd);
        p.cit     = g("cit", d.cit);

        // Mobility
        p.u0      = g("u0", d.u0);
        p.ua      = g("ua", d.ua);
        p.ub      = g("ub", d.ub);
        p.uc      = g("uc", d.uc);
        p.eu      = g("eu", d.eu);
        p.ucs     = g("ucs", d.ucs);
        p.vsat    = g("vsat", d.vsat);
        p.a0      = g("a0", d.a0);
        p.ags     = g("ags", d.ags);
        p.b0      = g("b0", d.b0);
        p.b1      = g("b1", d.b1);
        p.keta    = g("keta", d.keta);
        p.a1      = g("a1", d.a1);
        p.a2      = g("a2", d.a2);
        p.rdsw    = g("rdsw", d.rdsw);
        p.prwg    = g("prwg", d.prwg);
        p.prwb    = g("prwb", d.prwb);
        p.wr      = g("wr", d.wr);

        // Output
        p.pclm    = g("pclm", d.pclm);
        p.pdiblc1 = g("pdiblc1", d.pdiblc1);
        p.pdiblc2 = g("pdiblc2", d.pdiblc2);
        p.pdiblcb = g("pdiblcb", d.pdiblcb);
        p.drout   = g("drout", d.drout);
        p.pscbe1  = g("pscbe1", d.pscbe1);
        p.pscbe2  = g("pscbe2", d.pscbe2);
        p.pvag    = g("pvag", d.pvag);
        p.delta   = g("delta", d.delta);
        p.fprout  = g("fprout", d.fprout);
        p.pdits   = g("pdits", d.pdits);
        p.pditsd  = g("pditsd", d.pditsd);
        p.pditsl  = g("pditsl", d.pditsl);

        // GIDL/GISL
        p.agidl = g("agidl", d.agidl);
        p.bgidl = g("bgidl", d.bgidl);
        p.cgidl = g("cgidl", d.cgidl);
        p.egidl = g("egidl", d.egidl);
        p.agisl = g("agisl", p.agidl);
        p.bgisl = g("bgisl", p.bgidl);
        p.cgisl = g("cgisl", p.cgidl);
        p.egisl = g("egisl", p.egidl);

        // Gate tunneling
        p.aigbacc = g("aigbacc", d.aigbacc);
        p.bigbacc = g("bigbacc", d.bigbacc);
        p.cigbacc = g("cigbacc", d.cigbacc);
        p.nigbacc = g("nigbacc", d.nigbacc);
        p.aigbinv = g("aigbinv", d.aigbinv);
        p.bigbinv = g("bigbinv", d.bigbinv);
        p.cigbinv = g("cigbinv", d.cigbinv);
        p.eigbinv = g("eigbinv", d.eigbinv);
        p.nigbinv = g("nigbinv", d.nigbinv);
        p.aigc    = g("aigc",    if matches!(mos_type, Bsim4Type::Nmos) { d.aigbacc } else { d.aigbinv });
        p.bigc    = g("bigc",    if matches!(mos_type, Bsim4Type::Nmos) { d.bigbacc } else { d.bigbinv });
        p.cigc    = g("cigc",    if matches!(mos_type, Bsim4Type::Nmos) { d.cigbacc } else { d.cigbinv });
        p.nigc    = g("nigc",    d.nigc);
        p.poxedge = g("poxedge", d.poxedge);
        p.pigcd   = g("pigcd",   d.pigcd);
        p.ntox    = g("ntox",    d.ntox);
        p.toxref  = g("toxref",  d.toxref);

        // S/D diodes
        p.jss = g("jss", d.jss);
        p.jsd = g("jsd", p.jss);
        p.njs = g("njs", d.njs);
        p.njd = g("njd", p.njs);
        p.xtis = g("xtis", d.xtis);
        p.xtid = g("xtid", p.xtis);
        p.bvs  = g("bvs",  d.bvs);
        p.bvd  = g("bvd",  p.bvs);
        p.xjbvs = g("xjbvs", d.xjbvs);
        p.xjbvd = g("xjbvd", p.xjbvs);

        // Temperature
        p.kt1   = g("kt1",  d.kt1);
        p.kt1l  = g("kt1l", d.kt1l);
        p.kt2   = g("kt2",  d.kt2);
        p.ute   = g("ute",  d.ute);
        p.ua1   = g("ua1",  d.ua1);
        p.ub1   = g("ub1",  d.ub1);
        p.uc1   = g("uc1",  d.uc1);
        p.at    = g("at",   d.at);
        p.prt   = g("prt",  d.prt);

        // Geometry biases
        p.dwc = g("dwc", d.dlc);    // dwc defaults to dlc, dlc to lint
        p.dlc = g("dlc", d.dlc);
        p.xw  = g("xw",  d.xw);
        p.xl  = g("xl",  d.xl);
        p.wint = g("wint", d.wint);
        p.lint = g("lint", d.lint);

        // Caps (for parser acceptance only)
        p.cgso = g("cgso", d.cgso);
        p.cgdo = g("cgdo", d.cgdo);
        p.cgbo = g("cgbo", d.cgbo);

        p
    }
}
