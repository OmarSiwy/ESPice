# docs/devices — device-model specifications

Clean math + flow + CPU/GPU pseudo-code per model, written against free
primary sources (ngspice C, production Verilog-A, Berkeley/TU-Dresden
manuals, designers-guide VA). Every device file has the same four
sections — (1) mathematical specification, (2) flow, (3) CPU-sequential
pseudo-code, (4) GPU-batched SoA pseudo-code — plus a
**Noise model (in-device)** section (convention:
[noise-contract.md](noise-contract.md) — the `noisePsd`/`PsdTerm` hook
landed in contract.zig, device impls pending) and Sources /
Verification / impl+fixture footers. Companion to `RESEARCH.md` §1.

Free production VA datasets confirmed:
**OpenVAF integration_tests** (`github.com/pascalkuthe/OpenVAF/tree/master/integration_tests`)
ships BSIM3/4/6, BSIMBULK/CMG/IMG/SOI, PSP102/103(+NQS/t), HICUML2,
HiSIM2/HV/SOTB, MEXTRAM, EKV, ASMHEMT, MVSG_CMC, DIODE_CMC;
**designers-guide.org** ships VBIC 1.2 VA + reference C + test vectors
(release tarball). Compileability matrix:
[fastvaf-va-coverage.md](fastvaf-va-coverage.md).

## Cross-cutting

| Doc | Scope |
|---|---|
| [noise-contract.md](noise-contract.md) | In-device noise convention: current thermal-only collection, landed `noisePsd`/`PsdTerm` contract surface, target CPU/GPU collection passes |
| [contract-requirements.md](contract-requirements.md) | Device contract member-by-member requirements (consumer-justified) |
| [fastvaf-va-coverage.md](fastvaf-va-coverage.md) | FastVAF vs production VA compile matrix |

## Device docs

Noise column: what the doc's noise section covers, vs the reference.

| Doc | Model(s) | Primary source | Verification | Free VA | Noise |
|---|---|---|---|---|---|
| [passives-and-sources.md](passives-and-sources.md) | R/C/L/K (flux sign), V/I waveforms+breakpoints, E/F/G/H, B, URC | ngspice urcsetup/resnoise/vsrcload/indload + in-tree | R-noise/URC-rule/flux-sign verified; waveform table from our impl | n/a | R thermal+flicker verified; others none (correct) |
| [diode.md](diode.md) | Junction diode incl. breakdown, DEVpnjlim | ngspice dioload/diotemp/devsup | source-verified | DIODE_CMC (different model, unused) | verified (dionoise.c): RS thermal, shot, flicker |
| [bjt-gummel-poon.md](bjt-gummel-poon.md) | Gummel-Poon: Early, Webster, τF(XTF), crowding RB, excess phase | ngspice bjtload/bjttemp/bjtnoise | source-verified (temp partial) | n/a (SGP native) | verified (bjtnoise.c): 3 thermal + 2 shot + flicker |
| [mos1-shichman-hodges.md](mos1-shichman-hodges.md) | MOS1 + MEYER caps, fetlim/limvds | ngspice mos1load/mos1temp/devsup | source-verified | no | verified (mos1noi.c) incl. Cox'² flicker denom; our `.shot` tag flagged wrong |
| [mos-legacy.md](mos-legacy.md) | MOS2, MOS3, MOS6 (Sakurai-Newton), MOS9, BSIM1/2, MOSVAR | ngspice mos6load (verified) + mos2/3/9 loads (block-level) | MOS6 verified; others block/structural | MOSVAR yes (CMC) | mos1-template (verified via mos1noi.c; per-level files derived) |
| [vdmos.md](vdmos.md) | VDMOS: body diode, quasi-sat, tanh Cgd | our port (ngspice vdmos dir absent from mirror) | topology verified vs port; equations derived | no | derived (MOS1 template + body-diode shot; verify vdmosnoi.c) |
| [jfet-mesfet-hfet.md](jfet-mesfet-hfet.md) | JFET (Sydney B-fac), JFET2 (Parker-Skellern), MESFET (Statz), MESA, HFET1/2 | ngspice jfet/jfet2+psmodel/mes loads + noise | JFET/JFET2/Statz verified; MESA/HFET structural (FAIL fixtures → audit next) | no | verified (jfetnoi incl. NLEV3 gdsnoi, jfet2noi, mesnoise); MESA/HFET: none in ngspice |
| [bsim3v3-core.md](bsim3v3-core.md) | BSIM3v3.3 core + derived defaults | ngspice b3ld/b3temp | source-verified (CV/NQS out of scope) | yes | verified (b3noi.c): noiMod table, unified Ssi/Swi flicker |
| [bsim4-core.md](bsim4-core.md) | BSIM4 deltas from BSIM3 | ngspice b4ld/b4temp + bsim4.va | source-verified incl. tunneling/GIDL | yes (v4.8) | b4noi.c: tnoiMod 0 verified; 1/2 structural (correlation case) |
| [b4soi.md](b4soi.md) | B4SOI body/self-heating, BSIMPD deltas | ngspice b4soild (4.4) + bsimsoi.va (4.6.1) | Iii/thermal cross-verified; FD structural | yes (4.6.1) | VA noise block spot-verified; 4.4 noi file derived |
| [vbic-1.2.md](vbic-1.2.md) | VBIC 1.2 full model | designers-guide tarball (`vbic.vcs`) | source-verified (exact qb/NKF) + official test vectors | yes | verified (vbicnoise.c): 7 thermal + 4 shot + flicker |
| [hicum-l2-transfer-current.md](hicum-l2-transfer-current.md) | HICUM/L2 GICCR + ICK | TU Dresden v2.4.0 manual PDF | source-verified (Δτf out of scope) | yes | derived (manual §2.13 pages unread; B-C correlation flagged) |
| [psp103.md](psp103.md) | PSP 103.7 SP core + JUNCAP200 | PSP103 VA (OpenVAF) | source-verified (charge partition/NQS out of scope) | yes | VA-verified fragments: FNT thermal, NFA/NFB/NFC flicker, c_igid-correlated induced gate |
| [va-advanced.md](va-advanced.md) | EKV, HiSIM2/HV, BSIMBULK, BSIM-CMG/IMG, LUTSOI, PSP102 delta | OpenVAF VA (normative, index-level) | structural by design | yes (all) | in-VA; `noisePsd` maps 1:1 from VA white/flicker contributions |
| [coupled-tlines.md](coupled-tlines.md) | CPL N-line modal decomposition (Jacobi + 3-pole Padé recursive convolution) | ngspice cplload/cplsetup | pipeline verified; operator-to-stamp mapping structural | no | none (ngspice computes none) |
| [ltra-lossy-line.md](ltra-lossy-line.md) | LTRA recursive convolution, Bessel kernels, compaction | ngspice ltraload/ltramisc/ltraset | source-verified (ltratemp closed forms derived) | no | none (ngspice computes none) |
| [tline-and-switch.md](tline-and-switch.md) | Ideal line (Bergeron) + switch hysteresis FSM | ngspice traload/swload | source-verified | no | switch thermal 4kT·G_eff (our addition; ngspice has none) |

Not yet documented (index-level note only): ASM-HEMT, MVSG, MEXTRAM,
DIODE_CMC, HiSIM-SOI/SOTB, HICUM/L0, JUNCAP standalone, R3_CMC,
ASM-ESD, b3soidd/fd — all have in-tree ports; VA exists for most
(OpenVAF/CMC). Write per-model docs when a fixture forces it.

## Wants-list status (RESEARCH.md §1 priority order)

1. **B4SOI 4.4 full spec** — [b4soi.md](b4soi.md); cross-checked against
   the Berkeley v4.6.1 VA. Remaining: FD-module equations; note the
   4.4↔4.6 self-heating Pdiss delta when matching ngspice.
2. **BSIMPD/B4SOI generation deltas** — [b4soi.md](b4soi.md) §1.5.
3. **LTRA convolution kernels** — [ltra-lossy-line.md](ltra-lossy-line.md).
   Remaining: `ltratemp.c` closed forms for the $\int_0^\infty h$
   constants.
4. **PSP 103** — [psp103.md](psp103.md): full DC core from the
   production VA. Remaining: intrinsic charge partition + verification
   vectors (`vacask/mul`/`c6288`).
5. **CMC models ngspice lacks (ASM-HEMT, MVSG)** — VA located (OpenVAF);
   docs deferred.

New urgent item surfaced by the catalog sweep: **CPL N≥3**
([coupled-tlines.md](coupled-tlines.md)) — `cpl3_4_line` 7.5e34 blowup
is a topology-mapping bug (3-line card forced through the 2-line
even/odd cognate), fix in `src/frontend/parser.zig` mapping before any device
work.
