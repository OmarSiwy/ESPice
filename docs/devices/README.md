# docs/devices — device-model specifications

Clean math + flow + CPU/GPU pseudo-code per model, written against free
primary sources (ngspice C, production Verilog-A, Berkeley/TU-Dresden
manuals, designers-guide VA). Every file has the same four sections —
(1) mathematical specification, (2) flow, (3) CPU-sequential
pseudo-code, (4) GPU-batched SoA pseudo-code — plus Sources /
Verification status / impl+fixture pointers. Companion to
`RESEARCH.md` §1.

Free production VA datasets confirmed:
**OpenVAF integration_tests** (`github.com/pascalkuthe/OpenVAF/tree/master/integration_tests`)
ships BSIM3/4/6, BSIMBULK/CMG/IMG/SOI, PSP102/103(+NQS/t), HICUML2,
HiSIM2/HV/SOTB, MEXTRAM, EKV, ASMHEMT, MVSG_CMC, DIODE_CMC;
**designers-guide.org** ships VBIC 1.2 VA + reference C + test vectors
(release tarball).

| Doc | Model | Primary source | Verification | Free VA |
|---|---|---|---|---|
| [diode.md](diode.md) | Junction diode incl. breakdown, DEVpnjlim | ngspice dioload.c/diotemp.c/devsup.c | source-verified | DIODE_CMC (OpenVAF) — different model, not used |
| [mos1-shichman-hodges.md](mos1-shichman-hodges.md) | MOS1 + MEYER caps, fetlim/limvds | ngspice mos1load.c/mos1temp.c/devsup.c | source-verified | no (SPICE-native only) |
| [bsim3v3-core.md](bsim3v3-core.md) | BSIM3v3.3 Vth/mobility/Vdsat/Ids + derived defaults | ngspice b3ld.c/b3temp.c | source-verified (DC core; CV/NQS out of scope) | yes — BSIM3 (OpenVAF) |
| [bsim4-core.md](bsim4-core.md) | BSIM4 core as deltas from BSIM3 | ngspice b4ld.c/b4temp.c + bsim4.va | source-verified incl. gate tunneling/GIDL (VA-audited) | yes — BSIM4 v4.8 (OpenVAF) |
| [b4soi.md](b4soi.md) | B4SOI body/floating-body, self-heating, BSIMPD deltas | ngspice b4soild.c (4.4) + bsimsoi.va (4.6.1) | Iii/thermal cross-verified C↔VA; FD module structural | yes — BSIMSOI v4.6.1 (OpenVAF) |
| [vbic-1.2.md](vbic-1.2.md) | VBIC 1.2 full model | designers-guide vbic1.2.tar.gz (`vbic.vcs`) | source-verified (exact qb/NKF; caveat cleared) | yes — designers-guide (+ official test vectors) |
| [hicum-l2-transfer-current.md](hicum-l2-transfer-current.md) | HICUM/L2 GICCR transfer current + ICK | TU Dresden L2 v2.4.0 manual PDF | source-verified (Δτf partition out of scope) | yes — HICUML2 (OpenVAF) |
| [psp103.md](psp103.md) | PSP 103.7 surface-potential core + JUNCAP200 | PSP103 VA (OpenVAF integration_tests) | source-verified (charge partition/NQS/noise out of scope) | yes — PSP102/PSP103 (OpenVAF) |
| [ltra-lossy-line.md](ltra-lossy-line.md) | LTRA recursive convolution, Bessel kernels, compaction | ngspice ltraload.c/ltramisc.c/ltraset.c | source-verified (DAC'91 paper paywalled; ltratemp closed forms derived) | no (SPICE-native only) |
| [tline-and-switch.md](tline-and-switch.md) | Ideal line (Bergeron) + switch hysteresis semantics | ngspice traload.c/swload.c | source-verified | no (SPICE-native only) |

## Wants-list status (RESEARCH.md §1 priority order)

1. **B4SOI 4.4 full spec** — [b4soi.md](b4soi.md); now cross-checked
   against the Berkeley v4.6.1 VA (single-file audit target for the
   remaining FD-module equations). Note the 4.4↔4.6 self-heating
   Pdiss delta when matching ngspice.
2. **BSIMPD/B4SOI generation deltas** — [b4soi.md](b4soi.md) §1.5.
3. **LTRA convolution kernels** — [ltra-lossy-line.md](ltra-lossy-line.md).
   Remaining gap: `ltratemp.c` closed forms for the $\int_0^\infty h$
   constants (fetch before implementing).
4. **PSP 103** — [psp103.md](psp103.md) NEW: full DC core (sp
   calculation, mobility, Vdsat/Vdse, CLM/velocity saturation, Ids,
   impact ionization, GIDL, JUNCAP200) from the production VA. Remaining:
   intrinsic charge partition + verification vectors — transcribe when
   attacking `vacask/mul`/`c6288`.
5. **CMC models ngspice lacks (ASM-HEMT, MVSG)** — VA source now located
   (OpenVAF ASMHEMT/MVSG_CMC); no doc written (future device coverage;
   we already carry `asm_hemt.zig` / `mvsg.zig`).
