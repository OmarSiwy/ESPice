# Annex E — SPICE compatibility

Source: docs/annex-e-spice.html. Every HTML section id is listed literally.

Boundary disclosure: every Table E.1 row now contains executable named-port and named-
parameter syntax, but FastVAF rejects hierarchy at `module instantiation is not
supported`; the diagnostics therefore prove source/parser coverage, not primitive-schema
validation or SPICE elaboration. CCCS/CCVS sources name a concrete `vsine` controlling
instance, but instance-name passing cannot be semantically checked past that boundary.

| HTML id | Normative area | Fixtures / disposition |
|---|---|---|
| `sE-1` | purpose and optional SPICE compatibility | all fixtures make the FastVAF boundary explicit |
| `sE-1-1` | compatible SPICE objects may be instantiated | `spice_model_unsupported.va`, `spice_subcircuit_unsupported.va` |
| `sE-1-2` | dialect, primitive, naming and mathematical incompatibilities | diagnostics retain implementation-dependent boundary |
| `sE-2` | SPICE primitive/model/subcircuit objects behave as definitions | `spice_model_unsupported.va`, `spice_subcircuit_unsupported.va`, `spice_passive_primitives_unsupported.va` |
| `sE-2-1` | exact-case HDL match, case-insensitive SPICE fallback | `spice_case_lookup_unsupported.va` |
| `sE-2-2` | access examples | the three following subsection fixtures |
| `sE-2-2-1` | model instantiation and ordered/named BJT ports | `spice_model_unsupported.va`, `primitive_named_ports_unsupported.va` |
| `sE-2-2-2` | subcircuit instantiation | `spice_subcircuit_unsupported.va` |
| `sE-2-2-3` | primitive instantiation | `spice_passive_primitives_unsupported.va`, `spice_source_primitives_unsupported.va` |
| `sE-3` | required Table E.1 primitive/port/parameter names | passive: resistor(p,n:r,tc1,tc2), capacitor(p,n:c,ic), inductor(p,n:l,ic); sources: iexp/ipulse/ipwl/isine/vexp/vpulse/vpwl/vsine; network: tline(t1,b1,t2,b2:z0,td,f,nl), vccs(sink,src,ps,ns:gm), vcvs(p,n,ps,ns:gain); semiconductor: diode(a,c:area), bjt(c,b,e,s:area), mosfet(d,g,s,b:w,l,ad,as,pd,ps,nrd,nrs), jfet/mesfet(d,g,s:area). See four primitive diagnostic fixtures. |
| Table E.1 atomic rows | one named-port fixture per remaining primitive row | `primitive_capacitor.va`, `primitive_inductor.va`, `primitive_iexp.va`, `primitive_ipulse.va`, `primitive_ipwl.va`, `primitive_isine.va`, `primitive_vexp.va`, `primitive_vpulse.va`, `primitive_vpwl.va`, `primitive_tline.va`, `primitive_vccs.va`, `primitive_vcvs.va`, `primitive_diode.va`, `primitive_bjt.va`, `primitive_jfet.va`, `primitive_mesfet.va`; named resistor, vsine, and mosfet rows are `passive_named_ports_unsupported.va`, `spice_source_primitives_unsupported.va`, and `spice_semiconductor_primitives_unsupported.va` |
| Table E.1 family snapshots | grouped parameter/port spellings retained alongside atomic rows | `spice_network_primitives_unsupported.va`, `spice_semiconductor_primitives_unsupported.va` |
| `sE-3-1` | ccvs, cccs and mutual inductors unsupported by LRM | `unsupported_current_controlled.va` and `unsupported_cccs.va` each refer to an actual controlling `vsine` instance but stop at hierarchy rejection; `unsupported_mutual_inductor.va` |
| `sE-3-2` | primitive discipline precedence | `primitive_discipline_unsupported.va` |
| `sE-3-2-1` | instance-level, port-level, and mixed port_discipline overrides | `primitive_discipline_unsupported.va`, `primitive_port_discipline_unsupported.va`, `primitive_mixed_discipline_override_unsupported.va` |
| `sE-3-2-2` | resolution or electrical fallback | `primitive_discipline_unsupported.va`; requires elaborated connectivity |
| `sE-3-3` | HDL module/paramset shadows SPICE exact name | `spice_name_shadow.va`; selection requires hierarchy |
| `sE-3-4` | fetlim, pnjlim and vdslim through $limit | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` |
| `sE-4` | additional compatibility issues | `mfactor_subcircuit.va`, `spice_binning_unsupported.va` |
| `sE-4-1` | subcircuit multiplicity through $mfactor | `mfactor_subcircuit.va` |
| `sE-4-2` | model binning/libraries and paramset analogue | `spice_binning_unsupported.va` |
| `table-e-1` | exact Table E.1 primitive/port/parameter source inventory, including named ports on every row and all source `mag`/`phase`, exponential/pulse/PWL, sine timing/modulation, and MOS geometry names | atomic named-port row fixtures, `primitive_named_ports_unsupported.va`, `passive_named_ports_unsupported.va`, `spice_source_primitives_unsupported.va`, and `spice_semiconductor_primitives_unsupported.va`; semantic schema validation remains unavailable past hierarchy rejection |
| `table-e-2` | exact fetlim/pnjlim/vdslim names and arguments | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` |
