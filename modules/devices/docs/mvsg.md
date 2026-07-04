# MVSG CMC 4.0.0 -- Parameter & Equation Reference

> GaN MOSFET (HEMT) -- MIT Virtual Source GaN FET Compact Model
> 356 total parameters (4 instance + 352 model) | March 2024

## Model Topology

The MVSG model captures an AlGaN/GaN HEMT as a sub-circuit of series-connected transistor elements: an intrinsic FET under the gate, up to 4 source-side and 4 drain-side field-plate transistors, and source/drain implicit-gate access transistors. External terminals are D (Drain), G (Gate), S (Source), B (Body), and an optional dt (thermal). Internal nodes include gi1, gi2 (distributed gate resistance), gi2p (p-GaN junction), si/di (intrinsic source/drain), src/drc (contact resistance nodes), fps1-fps4 (source-side FP nodes), and fp1-fp4 (drain-side FP nodes). The model includes Schottky gate diodes (forward + reverse recombination), a p-GaN module (Dsch, Csch, Rsch), channel breakdown diodes, bias-dependent fringing capacitances, a thermal self-heating sub-circuit, charge trapping sub-circuits (drain-lag and gate-lag), RF gm-dispersion, flicker noise, and distributed gate resistance.

## Parameters

### Instance Parameters (4)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| w | 180.0e-6 | m | (0, inf) | Width per finger |
| l | 250.0e-9 | m | (0, inf) | Effective gate length |
| ngf | 1 | -- | [1, inf) | Number of fingers |
| dtemp | 0.0 | K | (-inf, inf) | Device temperature offset from ambient |

### Core Model Parameters (51)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| version | 4.00 | -- | [0, inf) | Version number |
| tnom | 27.0 | deg C | [-273.15, inf) | Reference temperature for the model |
| type | 1 | -- | {-1, 1} | nFET=1, pFET=-1 |
| cg | 4.00e-3 | F/m^2 | (0, inf) | Gate capacitance per area |
| tcg | 0.0 | 1/K | (-inf, inf) | cg dependence on temperature |
| cofsm | 0.0 | F/m | [0, inf) | Gate-Source outer fringing cap/width (bias-dependent) |
| cofdm | 0.0 | F/m | [0, inf) | Gate-Drain outer fringing cap/width (bias-dependent) |
| cofdsm | 0.0 | F/m | [0, inf) | Source-Drain outer fringing cap/width (bias-dependent) |
| cofdsubm | 0.0 | F/m | [0, inf) | Sub-Drain outer fringing cap/width (bias-dependent) |
| cofssubm | 0.0 | F/m | [0, inf) | Sub-Source outer fringing cap/width (bias-dependent) |
| cofgsubm | 0.0 | F/m | [0, inf) | Sub-Gate outer fringing cap/width (bias-dependent) |
| cofsm0 | 0.0 | F/m | [0, inf) | Gate-Source outer fringing cap/width (bias-independent) |
| cofdm0 | 0.0 | F/m | [0, inf) | Gate-Drain outer fringing cap/width (bias-independent) |
| cofdsm0 | 0.0 | F/m | [0, inf) | Source-Drain outer fringing cap/width (bias-independent) |
| cofdsubm0 | 0.0 | F/m | [0, inf) | Sub-Drain outer fringing cap/width (bias-independent) |
| cofssubm0 | 0.0 | F/m | [0, inf) | Sub-Source outer fringing cap/width (bias-independent) |
| cofgsubm0 | 0.0 | F/m | [0, inf) | Sub-Gate outer fringing cap/width (bias-independent) |
| tcofs | 0.0 | 1/K | (-inf, inf) | cofs dependence on temperature |
| tcofd | 0.0 | 1/K | (-inf, inf) | cofd dependence on temperature |
| tcofds | 0.0 | 1/K | (-inf, inf) | cofds dependence on temperature |
| tcofssub | 0.0 | 1/K | (-inf, inf) | cofssub dependence on temperature |
| tcofdsub | 0.0 | 1/K | (-inf, inf) | cofdsub dependence on temperature |
| tcofgsub | 0.0 | 1/K | (-inf, inf) | cofgsub dependence on temperature |
| vtfrin | -50 | V | (-inf, inf) | Threshold voltage for fringing fields |
| nfrin | 1e2 | V | (0, inf) | Fringing capacitance V-dependent slope (must be > 65 mV/dec) |
| rsh | 150.0 | Ohms/Sq | (0, inf) | 2-DEG sheet resistance |
| rcs | 800e-6 | Ohm*m | [0, inf) | Source contact resistance * width |
| rcd | 800e-6 | Ohm*m | [0, inf) | Drain contact resistance * width |
| vx0 | 3.0e5 | m/s | (0, inf) | Source injection velocity |
| mu0 | 0.135 | m^2/Vs | (0, inf) | Low-field mobility |
| beta | 2.0 | -- | (0, inf) | Linear to saturation parameter (use even values for Gummel symmetry) |
| vto | -2.72 | V | (-inf, inf) | Threshold voltage |
| ss | 0.120 | V/dec | (0, inf) | Sub-threshold slope |
| delta1 | 16e-3 | -- | [0, inf) | DIBL coefficient 1 |
| delta2 | 0.0 | -- | [0, inf) | DIBL coefficient 2 |
| dibsat | 10.0 | V | [0, inf) | DIBL saturation voltage |
| nd | 0.0 | -- | [0, inf) | Punchthrough factor for subthreshold slope |
| alpha | 3.5 | -- | (0, inf) | Weak-to-strong inversion transition factor (scale with ss) |
| lambda | 0.0 | 1/V | [0, inf) | CLM parameter |
| vtheta | 0.0 | 1/V | [0, inf) | Scattering: velocity reduction with Vg |
| mtheta | 0.0 | 1/V | [0, inf) | Scattering: mobility reduction with Vg |
| vzeta | 150e3 | 1/K | [0, inf) | vx0 dependence on temperature |
| vtzeta | -0.4e-3 | V/K | (-inf, inf) | vto dependence on temperature |
| epsilon | 2.3 | -- | [0, inf) | Mobility dependence on temperature |
| rct1 | 0.0 | 1/K | (-inf, inf) | Linear Rsh and Rc temperature coefficient |
| rct2 | 0.0 | 1/K^2 | (-inf, inf) | Quadratic Rsh and Rc temperature coefficient |
| flagres | 0 | -- | [0, 1] | Flag: 1=resistor for access region, 0=implicit transistor |
| flagsp | 0 | -- | [0, 1] | Flag: VT-shift with surface potential (0=off, 1=on) |
| flaggum | 0 | -- | [0, 1] | Flag: xtanh(x) smoothing (1) or original (0) for Gummel symmetry |
| mmaxs | 4.0e-5 | -- | [0, inf) | Smoothing parameter for mmax and absfunc |

### Source Access Region (SAR) Parameters (12)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| lgs | 3.0e-6 | m | [0, inf) | SAR length |
| vtors | -650 | V | (-inf, inf) | SAR threshold voltage |
| cgrs | 5.0e-3 | F/m^2 | (0, inf) | SAR gate-cap/area |
| vx0rs | 100e3 | m/s | (0, inf) | SAR source injection velocity |
| mu0rs | 100e-3 | m^2/Vs | (0, inf) | SAR low-field mobility |
| betars | 1.00 | -- | (0, inf) | SAR linear to saturation parameter |
| delta1rs | 100e-3 | -- | [0, inf) | SAR DIBL coefficient |
| srs | 0.100 | V/dec | (0, inf) | SAR sub-threshold slope |
| ndrs | 0.0 | -- | [0, inf) | SAR punchthrough factor |
| vthetars | 0.0 | 1/V | [0, inf) | SAR scattering: velocity reduction with Vg |
| mthetars | 0.0 | 1/V | [0, inf) | SAR scattering: mobility reduction with Vg |
| alphars | 3.5 | -- | (0, inf) | SAR weak-to-strong inversion transition factor |

### Drain Access Region (DAR) Parameters (12)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| lgd | 4.85e-6 | m | [0, inf) | DAR length |
| vtord | -650 | V | (-inf, inf) | DAR threshold voltage |
| cgrd | 4.3e-3 | F/m^2 | (0, inf) | DAR gate-cap/area |
| vx0rd | 100e3 | m/s | (0, inf) | DAR source injection velocity |
| mu0rd | 100e-3 | m^2/Vs | (0, inf) | DAR low-field mobility |
| betard | 1.00 | -- | (0, inf) | DAR linear to saturation parameter |
| delta1rd | 0.35 | -- | [0, inf) | DAR DIBL coefficient |
| srd | 0.3 | V/dec | (0, inf) | DAR sub-threshold slope |
| ndrd | 3.8 | -- | [0, inf) | DAR punchthrough factor |
| vthetard | 0.0 | 1/V | [0, inf) | DAR scattering: velocity reduction with Vg |
| mthetard | 0.0 | 1/V | [0, inf) | DAR scattering: mobility reduction with Vg |
| alphard | 3.5 | -- | (0, inf) | DAR weak-to-strong inversion transition factor |

### Source-side Field-Plate 1 (FPS1) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfps1 | 1 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfps1 | 0.0 | m | [0, inf) | FP length (>minl to activate) |
| vtofps1 | -44.5 | V | (-inf, inf) | FP threshold voltage |
| cgfps1 | 2.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfps1 | 0.0 | 1/K | (-inf, inf) | cgfps1 temperature dependence |
| flagfps1s | 1 | -- | [0, 1] | Flag: cfps1s select=1 or not=0 |
| cfps1s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfps1b | 1 | -- | [0, 1] | Flag: ccfps1/cbfps1 select=1 or not=0 |
| ccfps1 | 0.9e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfps1 | 0.0 | 1/K | (-inf, inf) | ccfps1 temperature dependence |
| cbfps1 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfps1 | 0.0 | 1/K | (-inf, inf) | cbfps1 temperature dependence |
| vx0fps1 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fps1 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafps1 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fps1 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfps1 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfps1 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafps1 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafps1 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafps1 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafps1 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Source-side Field-Plate 2 (FPS2) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfps2 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfps2 | 0.0 | m | [0, inf) | FP length |
| vtofps2 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfps2 | 1.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfps2 | 0.0 | 1/K | (-inf, inf) | cgfps2 temperature dependence |
| flagfps2s | 1 | -- | [0, 1] | Flag: cfps2s select=1 or not=0 |
| cfps2s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfps2b | 1 | -- | [0, 1] | Flag: ccfps2/cbfps2 select=1 or not=0 |
| ccfps2 | 0.3e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfps2 | 0.0 | 1/K | (-inf, inf) | ccfps2 temperature dependence |
| cbfps2 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfps2 | 0.0 | 1/K | (-inf, inf) | cbfps2 temperature dependence |
| vx0fps2 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fps2 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafps2 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fps2 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfps2 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfps2 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafps2 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafps2 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafps2 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafps2 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Source-side Field-Plate 3 (FPS3) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfps3 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfps3 | 0.0 | m | [0, inf) | FP length |
| vtofps3 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfps3 | 1.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfps3 | 0.0 | 1/K | (-inf, inf) | cgfps3 temperature dependence |
| flagfps3s | 1 | -- | [0, 1] | Flag: cfps3s select=1 or not=0 |
| cfps3s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfps3b | 1 | -- | [0, 1] | Flag: ccfps3/cbfps3 select=1 or not=0 |
| ccfps3 | 0.3e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfps3 | 0.0 | 1/K | (-inf, inf) | ccfps3 temperature dependence |
| cbfps3 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfps3 | 0.0 | 1/K | (-inf, inf) | cbfps3 temperature dependence |
| vx0fps3 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fps3 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafps3 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fps3 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfps3 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfps3 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafps3 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafps3 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafps3 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafps3 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Source-side Field-Plate 4 (FPS4) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfps4 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfps4 | 0.0 | m | [0, inf) | FP length |
| vtofps4 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfps4 | 1.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfps4 | 0.0 | 1/K | (-inf, inf) | cgfps4 temperature dependence |
| flagfps4s | 1 | -- | [0, 1] | Flag: cfps4s select=1 or not=0 |
| cfps4s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfps4b | 1 | -- | [0, 1] | Flag: ccfps4/cbfps4 select=1 or not=0 |
| ccfps4 | 0.3e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfps4 | 0.0 | 1/K | (-inf, inf) | ccfps4 temperature dependence |
| cbfps4 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfps4 | 0.0 | 1/K | (-inf, inf) | cbfps4 temperature dependence |
| vx0fps4 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fps4 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafps4 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fps4 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfps4 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfps4 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafps4 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafps4 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafps4 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafps4 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Drain-side Field-Plate 1 (FP1) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfp1 | 1 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfp1 | 0.0 | m | [0, inf) | FP length |
| vtofp1 | -44.5 | V | (-inf, inf) | FP threshold voltage |
| cgfp1 | 2.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfp1 | 0.0 | 1/K | (-inf, inf) | cgfp1 temperature dependence |
| flagfp1s | 1 | -- | [0, 1] | Flag: cfp1s select=1 or not=0 |
| cfp1s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfp1b | 1 | -- | [0, 1] | Flag: ccfp1/cbfp1 select=1 or not=0 |
| ccfp1 | 0.9e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfp1 | 0.0 | 1/K | (-inf, inf) | ccfp1 temperature dependence |
| cbfp1 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfp1 | 0.0 | 1/K | (-inf, inf) | cbfp1 temperature dependence |
| vx0fp1 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fp1 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafp1 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fp1 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfp1 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfp1 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafp1 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafp1 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafp1 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafp1 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Drain-side Field-Plate 2 (FP2) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfp2 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfp2 | 0.0 | m | [0, inf) | FP length |
| vtofp2 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfp2 | 1.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfp2 | 0.0 | 1/K | (-inf, inf) | cgfp2 temperature dependence |
| flagfp2s | 1 | -- | [0, 1] | Flag: cfp2s select=1 or not=0 |
| cfp2s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfp2b | 1 | -- | [0, 1] | Flag: ccfp2/cbfp2 select=1 or not=0 |
| ccfp2 | 0.3e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfp2 | 0.0 | 1/K | (-inf, inf) | ccfp2 temperature dependence |
| cbfp2 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfp2 | 0.0 | 1/K | (-inf, inf) | cbfp2 temperature dependence |
| vx0fp2 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fp2 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafp2 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fp2 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfp2 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfp2 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafp2 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafp2 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafp2 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafp2 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Drain-side Field-Plate 3 (FP3) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfp3 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfp3 | 0.0 | m | [0, inf) | FP length |
| vtofp3 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfp3 | 2.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfp3 | 0.0 | 1/K | (-inf, inf) | cgfp3 temperature dependence |
| flagfp3s | 1 | -- | [0, 1] | Flag: cfp3s select=1 or not=0 |
| cfp3s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfp3b | 1 | -- | [0, 1] | Flag: ccfp3/cbfp3 select=1 or not=0 |
| ccfp3 | 0.9e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfp3 | 0.0 | 1/K | (-inf, inf) | ccfp3 temperature dependence |
| cbfp3 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfp3 | 0.0 | 1/K | (-inf, inf) | cbfp3 temperature dependence |
| vx0fp3 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fp3 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafp3 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fp3 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfp3 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfp3 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafp3 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafp3 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafp3 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafp3 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Drain-side Field-Plate 4 (FP4) Parameters (22)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagfp4 | 0 | -- | [0, 1] | Flag: GFP=1 or SFP=0 |
| lgfp4 | 0.0 | m | [0, inf) | FP length |
| vtofp4 | -74.5 | V | (-inf, inf) | FP threshold voltage |
| cgfp4 | 2.0e-4 | F/m^2 | (0, inf) | FP gate-cap/area |
| tcgfp4 | 0.0 | 1/K | (-inf, inf) | cgfp4 temperature dependence |
| flagfp4s | 1 | -- | [0, 1] | Flag: cfp4s select=1 or not=0 |
| cfp4s | 0e-19 | F/m | [0, inf) | FP (source-side) to source cap/width |
| flagfp4b | 1 | -- | [0, 1] | Flag: ccfp4/cbfp4 select=1 or not=0 |
| ccfp4 | 0.9e-10 | F/m | [0, inf) | Source or gate to drain (under FP) cap/width |
| tccfp4 | 0.0 | 1/K | (-inf, inf) | ccfp4 temperature dependence |
| cbfp4 | 0.0 | F/m | [0, inf) | Body to drain (under FP) cap/width |
| tcbfp4 | 0.0 | 1/K | (-inf, inf) | cbfp4 temperature dependence |
| vx0fp4 | 1.2e5 | m/s | (0, inf) | FP source injection velocity |
| mu0fp4 | 0.2 | m^2/Vs | (0, inf) | FP low-field mobility |
| betafp4 | 1.00 | -- | (0, inf) | FP linear to saturation parameter |
| delta1fp4 | 0.0 | -- | [0, inf) | FP DIBL coefficient |
| sfp4 | 3.2 | V/dec | (0, inf) | FP sub-threshold slope |
| ndfp4 | 0.0 | -- | [0, inf) | FP punchthrough factor |
| vtzetafp4 | -0.4e-3 | V/K | (-inf, inf) | FP vto temperature dependence |
| vthetafp4 | 0.0 | 1/V | [0, inf) | FP scattering: velocity reduction with Vg |
| mthetafp4 | 0.0 | 1/V | [0, inf) | FP scattering: mobility reduction with Vg |
| alphafp4 | 1e-2 | -- | (0, inf) | FP weak-to-strong inversion transition factor |

### Gate Leakage Parameters (33)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| igmod | 0 | -- | [0, 1] | Flag: gate leakage 0=off, 1=on |
| fracig | 0 | -- | [0, inf) | Fraction of IG de-biased through FP transistors |
| vjg | 1.1 | V | [0, inf) | Gate diode cut-in voltage |
| pg_param1 | 820e-3 | 1/V | [0, inf) | Temperature coefficient of exponent |
| pg_params | 1.00 | -- | [0, inf) | G-S diode inverse ideality factor |
| ijs | 1.00e-12 | A/m | [0, inf) | G-S reverse leakage current / width |
| vgsats | 1.00 | V | [0, inf) | G-S high injection onset voltage |
| fracs | 0.5 | -- | [0, 1] | G-S fractional change in ideality factor (high inj.) |
| alphags | 1.0 | -- | (0, inf) | G-S high injection smoothing parameter |
| pg_paramd | 1.00 | -- | [0, inf) | G-D diode inverse ideality factor |
| ijd | 1.00e-12 | A/m | [0, inf) | G-D reverse leakage current / width |
| vgsatd | 1.00 | V | [0, inf) | G-D high injection onset voltage |
| fracd | 0.5 | -- | [0, 1] | G-D fractional change in ideality factor (high inj.) |
| alphagd | 1.0 | -- | (0, inf) | G-D high injection smoothing parameter |
| pgsrecs | 0.5 | -- | [0, inf) | G-S inverse ideality factor (reverse recombination) |
| irecs | 1.0e-18 | A/m | [0, inf) | G-S reverse recombination current / width |
| vgsatqs | 2.00 | V | (0, inf) | G-S depletion saturation effective max voltage |
| betarecs | 2.00 | -- | (0, inf) | G-S reverse recombination saturation parameter |
| pgsrecd | 0.8 | -- | [0, inf) | G-D inverse ideality factor (reverse recombination) |
| irecd | 2e-5 | A/m | [0, inf) | G-D reverse recombination current / width |
| vgsatqd | 0.8 | V | (0, inf) | G-D depletion saturation effective max voltage |
| betarecd | 0.25 | -- | (0, inf) | G-D reverse recombination saturation parameter |
| kbdgates | 0 | -- | [0, inf) | G-S breakdown enable (0=off) |
| vbdgs | 600 | V | [0, inf) | G-S soft breakdown voltage |
| pbdgs | 4.00 | 1/V | [0, inf) | G-S breakdown inverse ideality factor |
| kbdgated | 0 | -- | [0, inf) | G-D breakdown enable (0=off) |
| vbdgd | 600 | V | [0, inf) | G-D soft breakdown voltage |
| pbdgd | 4.00 | 1/V | [0, inf) | G-D breakdown inverse ideality factor |
| igrecmod | 0 | -- | [0, 1] | Flag: secondary recombination 0=off, 1=on |
| pgsrecs2 | 0.5 | -- | [0, inf) | Secondary G-S inverse ideality (reverse recomb.) |
| irecs2 | 1.0e-18 | A/m | [0, inf) | Secondary G-S reverse recomb. current / width |
| vgsatqs2 | 2.00 | V | (0, inf) | Secondary G-S depletion saturation voltage |
| betarecs2 | 2.00 | -- | (0, inf) | Secondary G-S saturation parameter |
| pgsrecd2 | 0.8 | -- | [0, inf) | Secondary G-D inverse ideality (reverse recomb.) |
| irecd2 | 2e-5 | A/m | [0, inf) | Secondary G-D reverse recomb. current / width |
| vgsatqd2 | 0.8 | V | (0, inf) | Secondary G-D depletion saturation voltage |
| betarecd2 | 0.25 | -- | (0, inf) | Secondary G-D saturation parameter |

### p-GaN Junction Parameters (20)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| flagpgan | 0 | -- | [0, 1] | Flag: p-GaN module 0=off, 1=on |
| pg_param_pgan | 0.05 | 1/V | [0, inf) | p-GaN forward diode inverse ideality factor |
| ij_pgan | 2e-5 | A/m | [0, inf) | p-GaN forward diode leakage current / width |
| vgsat_pgan | 3 | V | [0, inf) | p-GaN high injection onset voltage |
| frac_pgan | 0.4 | -- | [0, 1] | p-GaN fractional change in ideality (high inj.) |
| alphag_pgan | 1.0 | -- | (0, inf) | p-GaN high injection smoothing parameter |
| pgsrec_pgan | 0.5 | -- | [0, inf) | p-GaN inverse ideality (reverse recombination) |
| irec_pgan | 1e-21 | A/m | [0, inf) | p-GaN reverse recombination current / width |
| vgsatq_pgan | 2e4 | V | (0, inf) | p-GaN depletion saturation voltage |
| betarec_pgan | 1 | -- | (0, inf) | p-GaN reverse recombination saturation parameter |
| pganrecmod | 0 | -- | [0, 1] | Flag: secondary p-GaN recombination 0=off, 1=on |
| pgsrec_pgan2 | 0.5 | -- | [0, inf) | Secondary p-GaN inverse ideality (reverse recomb.) |
| irec_pgan2 | 1e-21 | A/m | [0, inf) | Secondary p-GaN reverse recomb. current / width |
| vgsatq_pgan2 | 2e4 | V | (0, inf) | Secondary p-GaN depletion saturation voltage |
| betarec_pgan2 | 1 | -- | (0, inf) | Secondary p-GaN saturation parameter |
| vcsh0 | 2.0 | V | (0, inf) | Built-in potential of p-GaN Schottky junction |
| csh0 | 6e-8 | F/m | [0, inf) | p-GaN zero-bias Schottky junction capacitance |
| fc | 0.5 | -- | [0, 1) | Fractional voltage before Taylor series expansion |
| pgancshorder | 2 | -- | [0, 5] | Order of Taylor series for p-GaN charge |
| rsch0 | 0 | Ohm*m | [0, inf) | Ohmic contact resistance / width |
| ohmicratio | 0 | -- | [0, 1] | Fraction of device width that is ohmic |

### Channel Breakdown Parameters (8)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| icbdmod | 0 | -- | [0, 1] | Flag: channel breakdown 0=off, 1=on |
| cbddbmod | 1 | -- | [0, 1] | Flag: breakdown de-biasing 0=off (to s,d), 1=on (to src,drc) |
| ijscbd | 1.00e-9 | A/m | [0, inf) | S-D channel breakdown leakage current / width |
| vchbdgs | 50 | V | [0, inf) | S-D soft breakdown voltage |
| pchbdgs | 4.00 | 1/V | [0, inf) | S-D breakdown inverse ideality factor |
| ijdcbd | 1.00e-9 | A/m | [0, inf) | D-S channel breakdown leakage current / width |
| vchbdgd | 50 | V | [0, inf) | D-S soft breakdown voltage |
| pchbdgd | 4.00 | 1/V | [0, inf) | D-S breakdown inverse ideality factor |

### Thermal Sub-circuit Parameters (2)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| rth | 25 | K/W | [0, inf) | Thermal resistance |
| cth | 1e-4 | s*W/K | [0, inf) | Thermal capacitance |

### RF gm-Dispersion Parameters (2)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| gmdisp | 0 | -- | [0, 1] | Flag: gm-dispersion 0=off, 1=on |
| taugmrf | 1e-3 | s | [0, inf) | gm-dispersion time constant |

### Layout and DC-to-RF Gate Resistance Parameters (4)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| rgsp | 0.0 | Ohms/m | [0, inf) | Gate resistance / width (1 finger, 1 contact) |
| ngcon | 1 | -- | (0, inf) | Number of gate contacts per finger |
| lovg | 0 | m | [0, inf) | Gate-finger line length from contact to active width |
| agate | 1 | -- | [0, inf) | DC-to-RF dispersion factor (1 = DC maintained) |

### Trapping Model Parameters (19)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| trapselect | 0 | -- | [0, 2] | Trapping select: 0=off, 1=Rdson, 2=Isat+Rdson |
| rintrap1 | 1e9 | Ohm | (0, inf) | Input trapping shunt resistance |
| ctrap | 1e-3 | F | [0, inf) | DC-block capacitor |
| vttrap | 100 | V | [0, inf) | Trapping stress threshold voltage |
| taut | 3e-5 | s | [0, inf) | Trap time constant |
| alphat1 | 1e-3 | -- | [0, inf) | Trap coefficient 1 on bias stress |
| alphat2 | 0.05 | V | (0, inf) | Trap coefficient 2 on bias stress |
| alphat3 | 1e-3 | -- | (0, inf) | Input trapping feedback factor |
| tempt | 1e-4 | 1/K | [0, inf) | Temperature coefficient for trapping |
| vgltrapth | 10 | V | (0, inf) | Gate-lag stress threshold voltage |
| vdltrapth | 100 | V | (0, inf) | Drain-lag stress threshold voltage |
| rcapture | 10.0 | Ohm | (0, inf) | Capture time constant resistance (slower) |
| remission | 50e-3 | Ohm | (0, inf) | Emission time constant resistance (faster) |
| cdglag | 1e-6 | F | (0, inf) | Drain/gate lag time constant capacitance |
| rct1dl | -5e-3 | 1/K | (-inf, inf) | Linear drain-lag temperature coefficient |
| rct1gl | 5e-3 | 1/K | (-inf, inf) | Linear gate-lag temperature coefficient |
| rct2dl | 0.0 | 1/K^2 | (-inf, inf) | Quadratic drain-lag temperature coefficient |
| rct2gl | 0.0 | 1/K^2 | (-inf, inf) | Quadratic gate-lag temperature coefficient |
| isat | 1.0e-9 | A | [0, inf) | Trapping diode reverse saturation current |

### Noise Model Parameters (6)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| noisemod | 0 | -- | [0, 1] | Flag: noise model 0=off, 1=on |
| shs | 3.0 | -- | [0, inf) | G-S shot noise parameter |
| shd | 3.0 | -- | [0, inf) | G-D shot noise parameter |
| kf | 1.0e-4 | -- | [0, inf) | Flicker noise coefficient |
| af | 2.0 | -- | [0, inf) | Flicker noise exponent |
| ffe | 1.2 | -- | (0, inf) | Flicker noise frequency exponent |

### Minimum Element Parameters (3)

| Parameter | Default | Unit | Range | Description |
|-----------|---------|------|-------|-------------|
| minr | 1e-3 | Ohm | [0, inf) | Minimum resistance |
| minl | 1.0e-9 | m | [0, inf) | Minimum length for access/FP transistor activation |
| minc | 0.0 | F | [0, inf) | Minimum capacitance |

---

## Equations

### Temperature Dependence

$$
T_{DUT} = T_{amb} + dtemp + T_{sh}
$$

Device temperature clamped to $[T_{MIN} + 273.15, \; T_{MAX} + 273.15]$.

$$
\phi_t = \frac{k_B \, T_{DUT}}{q}
$$

Thermal voltage.

$$
R_{si} = R_{cs,w} \left(1 + rct1 \cdot (T_{DUT} - T_{nom}) + rct2 \cdot (T_{DUT} - T_{nom})^2\right)
$$

Temperature-modulated source contact resistance. Clamped: $R_{si} \ge 0.1 \cdot R_{cs,w}$. Same form for $R_{di}$ with $R_{cd,w}$.

$$
R_{cs,w} = \begin{cases} rcs / (W \cdot ngf) & \text{if } flagres = 0 \\ (rcs/W + rsh \cdot lgs/W) / ngf & \text{if } flagres = 1 \end{cases}
$$

Same form for $R_{cd,w}$ with $rcd$, $lgd$.

$$
\mu_f = \frac{\mu_0}{\left(\frac{T_{amb}}{T_{nom}}\right)^\epsilon \left(1 + mtheta \cdot \frac{Q_{inv,v}}{C_g}\right)}
$$

Temperature and charge-dependent mobility.

$$
v_x = vx0 \cdot \frac{1 + vzeta \cdot T_{nom}}{1 + vzeta \cdot T_{amb}} \cdot \frac{1 + \lambda \cdot |V_{DS}|/L}{1 + vtheta \cdot Q_{inv,v}/C_g}
$$

Temperature and charge-dependent saturation velocity including CLM.

$$
V_{T,f} = vto + vtzeta \cdot (T_{amb} - T_{nom})
$$

Temperature-dependent threshold voltage.

$$
t_{trapfac} = 1 + tempt \cdot (T_{DUT} - T_{nom,K}), \quad \text{clamped} \ge 0.1
$$

Trapping temperature factor.

$$
t_{facdiode} = \left(\frac{T_{DUT}}{T_{nom,K}}\right)^3
$$

Diode temperature scaling factor.

#### Temperature-dependent capacitance function (calc_capt)

$$
C_{out} = C_{in} \cdot \left(1 + tempco \cdot (T_{DUT} - T_{nom,K})\right), \quad \text{clamped} \ge 0.01 \cdot C_{in}
$$

Applied to fringing, channel, and FP capacitances.

### Gate Resistance

$$
R_{G,DC} = R_{G1} + R_{G2} = \frac{rgsp}{ngf \cdot ngcon} \cdot \left(lovg + \frac{W}{ngcon}\right)
$$

$$
R_{G1} = \frac{rgsp}{ngf \cdot ngcon} \cdot \left(lovg + agate \cdot \frac{W}{ngcon}\right)
$$

$$
R_{G2} = \frac{rgsp}{ngf \cdot ngcon} \cdot \left((1 - agate) \cdot \frac{W}{ngcon}\right)
$$

$R_{G1}$ connects G to gi1; $R_{G2}$ connects gi1 to gi2. Nodes collapse if resistance < minr.

### Self-Heating Thermal Sub-circuit

$$
P_{diss} = \sum_{\text{regions}} I_{\text{region}} \cdot V_{\text{region}} + \frac{V_{Rcs}^2}{R_{si}} + \frac{V_{Rcd}^2}{R_{di}}
$$

$$
C_{th} \frac{dT_{sh}}{dt} + \frac{T_{sh}}{R_{th}} = P_{diss}
$$

When $R_{th} = 0$, $T_{sh} = 0$. External power $P_{ext}$ can be injected via the dt thermal node.

### Access Region Voltages

Source access region (SAR) implicit-gate voltage:

$$
V_{ig,s} = vtors + \frac{1}{rsh \cdot cgrs \cdot \mu_0}
$$

$$
V_{GS,rs} = V_{ig,s} - V_{SAR,s}
$$

where $V_{SAR,s} = \max(V(src,d), V(src,s))$ (or smoothed via mmax when flaggum=1).

Drain access region (DAR):

$$
V_{ig,d} = vtord + \frac{1}{drsht \cdot rsh \cdot cgrd \cdot \mu_0}
$$

where $drsht$ is the dynamic sheet resistance factor from the trapping module (=1 when trapselect != 1).

### Drain Current Formulation (calc_iq)

#### Intermediate quantities

$$
n = \frac{ss}{\ln(10) \cdot \phi_t} + nd \cdot |V_{DS}|
$$

Subthreshold slope factor with punchthrough.

$$
V_{T,DIBL} = V_{T,f} - \delta, \quad \delta = (\delta_1 - V_{sat,DIBL} \cdot \delta_2) \cdot |V_{DS}|
$$

where $V_{sat,DIBL} = \frac{|V_{DS}|}{(1 + (|V_{DS}|/dibsat)^\beta)^{1/\beta}}$ (0 if dibsat=0).

#### Fermi function for weak-to-strong transition

$$
F_f = \frac{1}{1 + \exp\left(\frac{\max(V_{GS}, V_{GD}) - V_{T,DIBL} + flagsp \cdot \alpha\phi_t/2}{\alpha\phi_t}\right)}
$$

Clamped to 0 or 1 for extreme arguments.

#### Charge at virtual source (Qinv,v)

$$
\eta = \frac{\max(V_{GS}, V_{GD}) - (V_{T,DIBL} - flagsp \cdot 0.1 \cdot \alpha\phi_t \cdot F_f)}{2n\phi_t}
$$

$$
Q_{inv,v} = C_g \cdot 2n\phi_t \cdot \ln(1 + e^\eta)
$$

Asymptotic: $Q_{inv,v} \to C_g \cdot 2n\phi_t \cdot \eta$ for $\eta \gg 1$; $Q_{inv,v} \to C_g \cdot 2n\phi_t \cdot e^\eta$ for $\eta \ll -1$.

#### Velocity and VDSAT

$$
v_{xf} = 2 F_f \phi_t \frac{\mu_f}{L} + (1 - F_f) v_x
$$

Combines diffusion velocity (weak accumulation) and saturation velocity (strong accumulation).

$$
V_{DSAT,s} = \frac{v_x \cdot L}{\mu_f}
$$

$$
V_{DSAT,s1} = V_{DSAT,s} \sqrt{1 + \frac{2 Q_{inv,v}}{C_g \cdot V_{DSAT,s}}} - V_{DSAT,s}
$$

$$
V_{DSAT} = V_{DSAT,s}(1 - F_f) + 2n\phi_t F_f
$$

$$
V_{DSAT,1} = V_{DSAT,s1}(1 - F_f) + 2n\phi_t F_f
$$

#### Saturation function

$$
F_{sd} = \frac{1}{\left(1 + \left(\max\left(0, \frac{V_{DS}}{V_{DSAT,1}}\right)\right)^\beta\right)^{1/\beta}}
$$

$$
V_{dx} = V_{DS} \cdot F_{sd}, \quad V_{sx} = -V_{DS} \cdot F_{ds}
$$

where $F_{ds}$ uses $-V_{DS}/V_{DSAT,1}$.

#### Source and drain charge

$$
Q_{is} = C_g \cdot 2n\phi_t \cdot \ln\left(1 + \exp\left(\frac{V_{GD} - V_{sx} - (V_{T,DIBL} - flagsp \cdot 0.1 \cdot \alpha\phi_t \cdot F_{fs})}{2n\phi_t}\right)\right)
$$

$$
Q_{id} = C_g \cdot 2n\phi_t \cdot \ln\left(1 + \exp\left(\frac{V_{GS} - V_{dx} - (V_{T,DIBL} - flagsp \cdot 0.1 \cdot \alpha\phi_t \cdot F_{fd})}{2n\phi_t}\right)\right)
$$

where $F_{fs}$, $F_{fd}$ are Fermi functions evaluated at $V_{GS}$ and $V_{GD}$ respectively.

#### Current

$$
V_{DSC} = \frac{Q_{is} - Q_{id}}{C_g}
$$

$$
F_{sat} = \frac{V_{DSC}/V_{DSAT}}{\left(1 + \left|\frac{V_{DSC}}{V_{DSAT}}\right|^\beta\right)^{1/\beta}}
$$

$$
v_{el} = v_{xf} \cdot F_{sat}
$$

$$
I_{DS} = type \cdot W \cdot ngf \cdot \frac{Q_{is} + Q_{id}}{2} \cdot v_{el} \cdot trapfrac_{dl}
$$

This is the unified drain current expression valid from subthreshold through saturation.

#### GaN-specific effects (physical form, captured by the above through parameter mapping)

$$
v_{x0} = \frac{v_{inj}}{1 + \theta_v \frac{Q_{ix0}}{C_{inv}}} (1 - \eta_v I_D V_D)
$$

$$
\mu = \frac{\mu_0}{\left(1 + \theta_\mu \frac{Q_{ix0}}{C_{inv}}\right)\left(1 + \frac{\eta_\mu I_D V_D}{T_0}\right)^\epsilon}
$$

### Channel Charge Formulation (Ward-Dutton Partitioning)

Computed with DIBL removed (using $Q_{is0}$, $Q_{id0}$ without $\delta$ terms).

$$
Q_{inv} = \frac{2}{3} W L \cdot \frac{Q_{is0}^2 + Q_{id0}^2 + Q_{is0} Q_{id0}}{Q_{is0} + Q_{id0}}
$$

$$
Q_d = \frac{2}{15} W L \cdot \frac{2Q_{is0}^3 + 3Q_{id0}^3 + 4Q_{is0}^2 Q_{id0} + 6Q_{id0}^2 Q_{is0}}{Q_{is0}^2 + Q_{id0}^2 + 2Q_{is0}Q_{id0}}
$$

$$
Q_s = Q_{inv} - Q_d
$$

$$
Q_{GS} = W \cdot ngf \cdot L \cdot type \cdot Q_s \cdot trapfrac_{dl}
$$

$$
Q_{GD} = W \cdot ngf \cdot L \cdot type \cdot Q_d \cdot trapfrac_{dl}
$$

Small offsets ($10^{-38}$, $10^{-57}$, $10^{-19}$, $2\times10^{-19}$) are added to intermediate terms to prevent division by zero.

### Field Plate Cross-coupled and Body Charges

$$
Q_{C,FP\{i\}} = C_{C,FP\{i\}} \cdot W \cdot n_{FP\{i\}} \phi_t \cdot \ln\left(1 + \exp\left(\frac{V_{G\{s/d\},FP\{i\}} - V_{T,FP\{i\}} - \alpha\phi_t F_f}{n_{FP\{i\}}\phi_t}\right)\right)
$$

$$
Q_{B,FP\{i\}} = C_{B,FP\{i\}} \cdot W \cdot n_{FP\{i\}} \phi_t \cdot \ln\left(1 + \exp\left(\frac{V_{B,FP\{i\}} - V_{T,FP\{i\}} - \alpha\phi_t F_f}{n_{FP\{i\}}\phi_t}\right)\right)
$$

$$
Q_{S,FP\{i\}} = C_{S,FP\{i\}} \cdot W \cdot n_{FP\{i\}} \phi_t \cdot \ln\left(1 + \exp\left(\frac{V_{GS,FP\{i\}} - V_{T,FP\{i\}} - \alpha\phi_t F_f}{n_{FP\{i\}}\phi_t}\right)\right)
$$

$Q_{S,FP\{i\}}$ only computed when corresponding flagfp{i}s=1.

### Fringing Field Capacitances

For each terminal pair $\{i\} \in \{s, d, ds, ssub, dsub, gsub\}$:

$$
Q_{of\{i\}} = W \cdot ngf \left( C_{of\{i\},mt0} \cdot V + C_{of\{i\},mt} \cdot n_{frin} \cdot \ln\left(1 + \exp\left(\frac{V - vtfrin}{n_{frin}}\right)\right) \right)
$$

where $V$ is the voltage across the respective terminal pair. The first term is bias-independent, the second captures the bias-dependent tail. Clamped for large/small arguments.

### Forward Gate Current Model (calc_ig)

$$
I_{Fg\{s/d\},nohinj} = W \cdot ngf \cdot ij\{s/d\} \cdot \left(\frac{T}{T_0}\right)^{e_{gate}} \cdot \left(\exp\left(\frac{pg_{param\{s/d\}} \cdot V_{g\{s/d\}} - pg_{param1} \cdot V_{jg}}{\phi_t}\right) - K_{bd} \cdot I_{g,bd} - \exp\left(\frac{-pg_{param1} \cdot V_{jg}}{\phi_t}\right)\right)
$$

where $e_{gate} = 3.0$. Simplified when $K_{bd} = 0$:

$$
I_{Fg\{s/d\}} = W \cdot ngf \cdot ij\{s/d\} \cdot \left(\frac{T}{T_0}\right)^3 \cdot \exp\left(\frac{-pg_{param1} \cdot V_{jg}}{\phi_t}\right) \cdot \left(\exp\left(\frac{pg_{param\{s/d\}} \cdot V_{g\{s/d\}}}{\phi_t}\right) - 1\right)
$$

#### Gate breakdown term

$$
I_{g,bd} = \exp\left(-pbdg\{s/d\} \cdot (V_{g\{s/d\}} + vbdg\{s/d\}) - \frac{pg_{param1} \cdot V_{jg}}{\phi_t}\right) - \exp\left(-pbdg\{s/d\} \cdot vbdg\{s/d\} - \frac{pg_{param1} \cdot V_{jg}}{\phi_t}\right)
$$

#### High injection (when frac{s/d} < 1)

Unshifted high injection current uses $frac\{s/d\} \cdot pg_{param\{s/d\}}$ as the effective ideality:

$$
I_{Fg,hinj,un} = W \cdot ngf \cdot ij\{s/d\} \cdot \left(\frac{T}{T_0}\right)^3 \cdot \left(\exp\left(\frac{frac\{s/d\} \cdot pg_{param\{s/d\}} \cdot V_{g\{s/d\}}}{\phi_t}\right) - \frac{pg_{param1} \cdot V_{jg}}{\phi_t} - K_{bd} \cdot I_{g,bd} - \exp\left(\frac{-pg_{param1} \cdot V_{jg}}{\phi_t}\right)\right)
$$

Shifted to match at $V_{gsat\{s/d\}}$:

$$
I_{Fg,hinj} = I_{Fg,hinj,un} \cdot \frac{I_{Fg,nohinj}(V_{gsat})}{I_{Fg,hinj,un}(V_{gsat})}
$$

If $frac\{s/d\} = 0$: $I_{Fg,hinj} = I_{Fg,nohinj}(V_{gsat})$ (constant).

Fermi smoothing between the two regimes:

$$
F_{f,vg} = \frac{1}{1 + \exp\left(\frac{V_{g\{s/d\}} - V_{gsat\{s/d\}} + \frac{1}{2}\alpha_{g\{s/d\}}^2 \phi_t}{\alpha_{g\{s/d\}}^2 \phi_t}\right)}
$$

$$
I_{Fg\{s/d\}} = F_{f,vg} \cdot I_{Fg,nohinj} + (1 - F_{f,vg}) \cdot I_{Fg,hinj}
$$

### Reverse Recombination Gate Current

$$
F_{rec,g\{s/d\}} = \frac{-V_{g\{s/d\}}}{\left(1 + \left|\frac{V_{g\{s/d\}}}{V_{gsatq\{s/d\}}}\right|^{\beta_{rec\{s/d\}}}\right)^{1/\beta_{rec\{s/d\}}}}
$$

$$
I_{Rg\{s/d\}} = -W \cdot ngf \cdot irec\{s/d\} \cdot \left(\frac{T}{T_0}\right)^3 \cdot \left(\exp\left(\frac{pgs_{rec\{s/d\}} \cdot F_{rec,g\{s/d\}}}{\phi_t}\right) - 1\right)
$$

Total gate diode current: $I_g = I_{Fg} + I_{Rg}$.

A secondary recombination current with independent parameters ($irec\{s/d\}2$, $pgsrec\{s/d\}2$, $vgsatq\{s/d\}2$, $betarec\{s/d\}2$) is added when igrecmod=1.

### p-GaN Schottky Module

#### p-GaN Diode Current (Dsch)

$$
I_{F,dsch} = W \cdot (1 - ohmicratio) \cdot ngf \cdot ij_{pgan} \cdot \left(\frac{T}{T_0}\right)^3 \cdot \left(\exp\left(\frac{pg_{param,pgan} \cdot V_{gi2p,gi2}}{\phi_t}\right) - 1\right)
$$

$$
I_{R,dsch} = -W \cdot (1 - ohmicratio) \cdot ngf \cdot irec_{pgan} \cdot \left(\frac{T}{T_0}\right)^3 \cdot \left(\exp\left(\frac{pgs_{rec,pgan} \cdot F_{rec,pgan}}{\phi_t}\right) - 1\right)
$$

$$
F_{rec,pgan} = \frac{-V_{gi2p,gi2}}{\left(1 + \left|\frac{V_{gi2p,gi2}}{V_{gsatq,pgan}}\right|^{\beta_{rec,pgan}}\right)^{1/\beta_{rec,pgan}}}
$$

High injection for the p-GaN diode uses the same formulation as gate diodes with parameters vgsat_pgan, frac_pgan, alphag_pgan. Secondary recombination via pganrecmod=1 with separate parameter set.

#### p-GaN Junction Charge (Csch)

$$
Q_{sch}^{\dagger} = 2 \cdot csh0 \cdot W \cdot (1 - ohmicratio) \cdot ngf \cdot vcsh0 \cdot \left(1 - \sqrt{1 - \frac{V_{gi2p,gi2}}{vcsh0}}\right)
$$

Valid for $V_{gi2p,gi2} \le fc \cdot vcsh0$.

For $V_{gi2p,gi2} > fc \cdot vcsh0$ (Taylor series extension):

$$
Q_{sch} = 2 \cdot csh0 \cdot W \cdot (1 - ohmicratio) \cdot ngf \cdot vcsh0 \cdot \sum_{n=0}^{pgancshorder} \frac{1}{n!} \left.\frac{d^n}{dV^n}\left(1 - \sqrt{1 - V/vcsh0}\right)\right|_{V=fc \cdot vcsh0} (V_{gi2p,gi2} - fc \cdot vcsh0)^n
$$

The corresponding capacitance:

$$
C_{sch} = \frac{\partial Q_{sch}}{\partial V_{gi2p,gi2}} = csh0 \cdot W \cdot (1 - ohmicratio) \cdot ngf \cdot \frac{1}{\sqrt{1 - V_{gi2p,gi2}/vcsh0}}
$$

#### p-GaN Ohmic Resistance (Rsch)

$$
R_{sch} = \frac{rsch0}{W \cdot ohmicratio \cdot ngf}, \quad \text{active when } rsch0 \ne 0 \text{ and } ohmicratio \ne 0
$$

### Channel Breakdown Model

Forward-mode channel breakdown:

$$
I_{CH,F} = I_{R,CHBD} \cdot K_{CHBD} \cdot \left(\exp(-\phi_{BD} \cdot V_{BD}) - \exp(-\phi_{BD}(V_{DS} + V_{DG} - V_{BD}))\right)
$$

Reverse-mode:

$$
I_{CH,R} = I_{R,CHBD} \cdot K_{CHBD} \cdot \left(\exp(-\phi_{BD} \cdot V_{BD}) - \exp(-\phi_{BD}(V_{SD} + V_{SG} - V_{BD}))\right)
$$

Gate-diode breakdown:

$$
I_{G\{S/D\}} = I_R \cdot K_{BD} \cdot \left(\exp(-\phi_{BD} \cdot V_{BD}) - \exp(-\phi_{BD}(V_{G\{S/D\}} - V_{BD}))\right)
$$

Parameters: $K_{CHBD}$ = kbdgate{s/d}, $V_{BD}$ = vchbdg{s/d}, $\phi_{BD}$ = pchbdg{s/d}, $I_{R,CHBD}$ = ijscbd/ijdcbd. De-biased through contact resistances when cbddbmod=1.

### Charge Trapping -- RDS,On Increase (trapselect=1)

$$
V_{tcollapse,0} = \alpha_{t1} |V_{DG}| + \exp\left(\frac{V_{DG} - vttrap - \alpha_{t3} V_{IN}}{\alpha_{t2}}\right)
$$

Fed into RC network with time constant $\tau_t$ (taut). Output $V_{tcollapse}$ modulates drain access sheet resistance:

$$
drsht = 1 + V_{tcollapse} \cdot t_{trapfac}
$$

### Charge Trapping -- Gate-lag/Drain-lag (trapselect=2)

Drain-lag RC sub-circuit: input $V_D$, output $V_{D,eff}$. Gate-lag: input $V_G$, output $V_{G,eff}$.

Emission time constant: $\tau_{emission} \approx R_{emission} \cdot C_{DLT}$. Capture time constant: $\tau_{capture} \approx R_{capture} \cdot C_{DLT}$.

$$
Q_{frac,d} = \frac{|V_{D,eff}|}{V_{DLtrapth}}, \quad Q_{frac,g} = \frac{|V_{G,eff}|}{V_{GLtrapth}}
$$

$$
Q_{frac} = \frac{1}{1 + Q_{frac,d} + Q_{frac,g}}
$$

$$
I_{DS} = Q_{frac} \cdot I_{DS,0}, \quad Q_{\{GS,GD,GSUB\}} = Q_{frac} \cdot Q_{\{GS,GD,GSUB\},0}
$$

Temperature-dependent trapping capacitances:

$$
C_{DLT} = cdglag \cdot \left(1 + rct1dl \cdot (T_{DUT} - T_{nom}) + rct2dl \cdot (T_{DUT} - T_{nom})^2\right)
$$

$$
C_{GLT} = cdglag \cdot \left(1 + rct1gl \cdot (T_{DUT} - T_{nom}) + rct2gl \cdot (T_{DUT} - T_{nom})^2\right)
$$

### RF gm-Dispersion (NQS Transport)

$$
I_{DS,RF} = \frac{I_{DS}}{1 + s\tau_{gmrf} + \frac{s^2 \tau_{gmrf}^2}{3}}
$$

Implemented as a second-order transfer function with internal nodes xt1, xt2. Active when gmdisp=1.

### Noise Model

#### Channel thermal noise

$$
S_{I,ch} = 4kT \cdot g_m \cdot \Gamma, \quad \Gamma = \frac{Q_G}{W \cdot ngf \cdot L \cdot C_g}
$$

where $Q_G = Q_{inv}$ from the charge model.

#### Parasitic resistance thermal noise

$$
S_{I,R} = \frac{4kT}{R}
$$

Applied to $R_{cs}$, $R_{cd}$, gate resistances, and FP channel resistances ($rsh \cdot L_{fp} / (W \cdot ngf)$).

#### Gate shot noise

$$
S_{I,GS} = 2q \cdot shs \cdot \left|I_{GS} + 2(I_{Fg,sat,s} + I_{Rg,s})\right|
$$

$$
S_{I,GD} = 2q \cdot shd \cdot \left|I_{GD} + 2(I_{Fg,sat,d} + I_{Rg,d})\right|
$$

Applied to both internal (gi2p-si/di) and external (gi2p-fps4/fp4) gate diode branches.

#### Flicker noise (1/f)

$$
S_{I,1/f} = K_f \cdot \frac{W \cdot ngf}{L} \cdot \frac{|I_{DS}|^{a_f}}{(W \cdot ngf)^{a_f}} \cdot \frac{1}{f^{f_{fe}}}
$$

Polarity-aware: sign flips for $I_{DS} < 0$.

### Smoothing Functions

#### absfunc

$$
\text{absfunc}(x, s) = \begin{cases} \sqrt{x^2 + s} & \text{if } flaggum = 0 \\ x \cdot \tanh\left(\frac{10^{-3}}{s} \cdot x\right) & \text{if } flaggum = 1 \end{cases}
$$

#### mmax

$$
\text{mmax}(x, y, s) = \begin{cases} \frac{1}{2}\left(x + y + \sqrt{(x-y)^2 + s}\right) & \text{if } flaggum = 0 \\ \frac{1}{2}\left(x + y + (x-y)\tanh\left(\frac{10^{-3}}{s}(x-y)\right)\right) & \text{if } flaggum = 1 \end{cases}
$$

#### explim (safe exponential)

Clamps the argument to prevent overflow; standard bounded exponential.

### Power Dissipation

$$
P_{diss} = I_{DS} V(di,si) + I_{DS,rd} V(drc,fp4) + I_{DS,rs} V(fps4,src) + \sum_{i} I_{DS,fp_i} V_{fp_i} + \frac{V_{Rcs}^2}{R_{si}} + \frac{V_{Rcd}^2}{R_{di}}
$$

Sum over all transistor elements in the sub-circuit.
