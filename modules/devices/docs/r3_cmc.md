# R3 CMC 1.1.2 — Parameter & Equation Reference

> Three-terminal nonlinear (diffused and poly-silicon) resistor model and JFET model

## Model Topology

The r3_cmc model is a 3-terminal device with external ports n1 (terminal 1), nc (control/substrate), and n2 (terminal 2), plus an optional self-heating node dt. Internal nodes i1 and i2 sit between the external terminals and the resistor body: end resistances connect n1-to-i1 and i2-to-n2, the nonlinear resistor body connects i1-to-i2, and parasitic diode currents and capacitances connect nc-to-i1 and nc-to-i2. The self-heating network is a parallel R-C (thermal resistance and capacitance) driven by total dissipated power.

Netlist syntax: `r<name> (<n1> <nc> <n2>) <modelName> <instanceParams>`

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| `w` | m | 1e-6 | 0.0 | inf | design width of resistor body |
| `l` | m | 1e-6 | 0.0 | inf | design length of resistor body |
| `wd` | m | 0.0 | 0.0 | inf | dogbone width (total; not per side) |
| `a1` | m^2 | 0.0 | 0.0 | inf | area of port n1 partition |
| `p1` | m | 0.0 | 0.0 | inf | perimeter of port n1 partition |
| `c1` | -- | 0 | 0 | inf | number of contacts at n1 port |
| `a2` | m^2 | 0.0 | 0.0 | inf | area of port n2 partition |
| `p2` | m | 0.0 | 0.0 | inf | perimeter of port n2 partition |
| `c2` | -- | 0 | 0 | inf | number of contacts at n2 port |
| `trise` (`dtemp`) | degC | 0.0 | -- | -- | local temperature offset from ambient (before self-heating) |
| `sw_noise` | -- | 1 | 0 | 1 | switch for including noise: 0=no, 1=yes |
| `sw_et` | -- | 1 | 0 | 1 | switch for self-heating: 0=exclude, 1=include |
| `sw_lin` | -- | 0 | 0 | 1 | switch to force linearity: 0=no, 1=yes |
| `sw_mman` | -- | 0 | 0 | 1 | switch for mismatch analysis: 0=no, 1=yes |
| `nsmm_rsh` | -- | 0.0 | -- | -- | number of sigma's of local variation for rsh |
| `nsmm_w` | -- | 0.0 | -- | -- | number of sigma's of local variation for w |
| `nsmm_l` | -- | 0.0 | -- | -- | number of sigma's of local variation for l |

### Special Model Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| `version` | -- | 1 | -- | -- | model version (major model change) |
| `subversion` | -- | 1 | -- | -- | model subversion (minor model change) |
| `revision` | -- | 2 | -- | -- | model revision (implementation update) |
| `level` | -- | 1003 | -- | -- | model level |
| `type` | -- | -1 | -1 | +1 | resistor type: -1=n-body, +1=p-body |
| `scale` | -- | 1.0 | 0.0 | 1.0 | scale factor for instance geometries |
| `shrink` | % | 0.0 | 0.0 | 100.0 | shrink percentage for instance geometries |
| `tmin` | degC | -100.0 | -250.0 | 27.0 | minimum ambient temperature |
| `tmax` | degC | 500.0 | 27.0 | 1000.0 | maximum ambient temperature |
| `rthresh` | Ohm | 0.001 | 0.0 | inf | threshold to switch end resistance to V=I*R form |
| `imax` | A | 1.0 | 0.0 | inf | current at which to linearize diode currents |
| `tnom` | degC | 27.0 | -250.0 | 1000.0 | nominal (reference) temperature |
| `lmin` | um | 0.0 | 0.0 | inf | minimum allowed drawn length |
| `lmax` | um | 9.9e9 | lmin | inf | maximum allowed drawn length |
| `wmin` | um | 0.0 | 0.0 | inf | minimum allowed drawn width |
| `wmax` | um | 9.9e9 | wmin | inf | maximum allowed drawn width |
| `jmax` | A/um | 100.0 | 0.0 | inf | maximum current density |
| `vmax` | V | 9.9e9 | 0.0 | inf | maximum voltage w.r.t. control port nc |
| `tminclip` | degC | -100.0 | -250.0 | 27.0 | clip minimum temperature |
| `tmaxclip` | degC | 500.0 | 27.0 | 1000.0 | clip maximum temperature |

### Geometry Parameters (Resistance Body)

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `rsh` | $R_{sh}$ | Ohm/sq | 100.0 | 0.0 | inf | sheet resistance |
| `xw` | $xw$ | um | 0.0 | -- | -- | width offset (total) |
| `nwxw` | $nwxw$ | um^2 | 0.0 | -- | -- | narrow width width offset correction coefficient |
| `wexw` | $wexw$ | um | 0.0 | -- | -- | webbing effect width offset correction coefficient (for dog-boned devices) |
| `fdrw` | $fdrw$ | um | 1.0 | 0.0 | inf | finite doping width offset reference width |
| `fdxwinf` | $fdx_{\infty}$ | um | 0.0 | -- | -- | finite doping width offset width value for wide devices |
| `xl` | $xl$ | um | 0.0 | -- | -- | length offset (total) |
| `xlw` | $xlw$ | -- | 0.0 | -- | -- | width dependence of length offset |
| `dxlsat` | $dxlsat$ | um | 0.0 | -- | -- | additional length offset for velocity saturation calculation |

### Depletion Pinching Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `nst` | $nst$ | -- | 1.0 | 0.1 | 5.0 | subthreshold slope parameter |
| `dfinf` | $df_{\infty}$ | 1/V^0.5 | 0.01 | 1e-4 | 10.0 | depletion factor for wide/long device |
| `dfl` | $df_l$ | um/V^0.5 | 0.0 | -- | -- | depletion factor 1/l coefficient |
| `dfw` | $df_w$ | um/V^0.5 | 0.0 | -- | -- | depletion factor 1/w coefficient |
| `dfwl` | $df_{wl}$ | um^2/V^0.5 | 0.0 | -- | -- | depletion factor 1/(w*l) coefficient |
| `sw_dfgeo` | -- | -- | 1 | 0 | 1 | switch for depletion factor geometry dependence: 0=drawn, 1=effective |
| `dp` (`dpinf`) | $dp$ | V | 2.0 | 0.1 | inf | depletion potential |
| `dpl` | $dp_l$ | V*um^dple | 0.0 | -- | -- | depletion potential l dependence coefficient |
| `dple` | $dp_{le}$ | -- | 2.0 | -- | -- | depletion potential l dependence exponent |
| `dpw` | $dp_w$ | V*um^dpwe | 0.0 | -- | -- | depletion potential w dependence coefficient |
| `dpwe` | $dp_{we}$ | -- | 0.5 | -- | -- | depletion potential w dependence exponent |
| `dpwl` | $dp_{wl}$ | V*um^(dpwe+dple) | 0.0 | -- | -- | depletion potential wl dependence coefficient |

Note: The PDF documentation lists `dple`=1.0 and `dpwe`=1.0, but the Verilog-A source code uses `dple`=2.0 and `dpwe`=0.5. The source code values are shown here as they are authoritative.

### Velocity Saturation Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `ecrit` | $E_{crit}$ | V/um | 4.0 | 0.0 | 1000.0 | velocity saturation critical field |
| `ecorn` | $E_{corn}$ | V/um | 0.4 | 0.0 | ecrit | velocity saturation corner field |
| `sw_vsatt` | -- | -- | 0 | 0 | 1 | switch for vsat temperature effects: 0=none, 1=link with body resistance |
| `xvsat` | $x_{vsat}$ | -- | 0.0 | -- | -- | exponent for saturation velocity temperature dependence |
| `du` | $du$ | -- | 0.02 | 0.0 | 1000.0 | mobility reduction at ecorn |

### Saturation Smoothing Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `ats` (`atsinf`) | $ats$ | V | 0.0 | 0.0 | -- | saturation smoothing parameter |
| `atsl` | $ats_l$ | V*um | 0.0 | 0.0 | -- | saturation smoothing parameter 1/l coefficient |

### Pinch-off Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `sw_accpo` | -- | -- | 0 | 0 | 3 | switch for pinch-off modeling (0-3, increasing accuracy and cost) |
| `grpo` | $g_{rpo}$ | -- | 1e-12 | 0.0 | 0.1 | minimum body conductance in pinch-off (ratio w.r.t. Vc=0) |

### Contact Resistance Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `rc` | $R_c$ | Ohm | 0.0 | 0.0 | inf | resistance per contact |
| `rcw` | $R_{cw}$ | Ohm*um | 0.0 | 0.0 | inf | width adjustment for contact resistance |

### Parasitic Diode Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `fc` | $f_c$ | -- | 0.9 | 0.0 | 0.99 | depletion capacitance linearization factor |
| `isa` | $I_{sa}$ | A/um^2 | 0.0 | 0.0 | inf | diode saturation current per unit area |
| `na` | $n_a$ | -- | 1.0 | 0.0 | inf | ideality factor for isa |
| `ca` | $C_a$ | F/um^2 | 0.0 | 0.0 | inf | fixed capacitance per unit area |
| `cja` | $C_{ja}$ | F/um^2 | 0.0 | 0.0 | inf | depletion capacitance per unit area |
| `pa` | $P_a$ | V | 0.75 | 0.0 | inf | built-in potential for cja |
| `ma` | $m_a$ | -- | 0.33 | 0.0 | 1.0 | grading coefficient for cja |
| `aja` | $a_{ja}$ | V | -0.5 | -- | -- | smoothing parameter for cja |
| `isp` | $I_{sp}$ | A/um | 0.0 | 0.0 | inf | diode saturation current per unit perimeter |
| `np` | $n_p$ | -- | 1.0 | 0.0 | inf | ideality factor for isp |
| `cp` | $C_p$ | F/um | 0.0 | 0.0 | inf | fixed capacitance per unit perimeter |
| `cjp` | $C_{jp}$ | F/um | 0.0 | 0.0 | inf | depletion capacitance per unit perimeter |
| `pp` | $P_p$ | V | 0.75 | 0.0 | inf | built-in potential for cjp |
| `mp` | $m_p$ | -- | 0.33 | 0.0 | 1.0 | grading coefficient for cjp |
| `ajp` | $a_{jp}$ | V | -0.5 | -- | -- | smoothing parameter for cjp |
| `vbv` | $V_{bv}$ | V | 0.0 | 0.0 | inf | breakdown voltage |
| `ibv` | $I_{bv}$ | A | 1e-6 | 0.0 | inf | current at breakdown |
| `nbv` | $n_{bv}$ | -- | 1.0 | 0.0 | inf | ideality factor for breakdown current |

### Flicker Noise Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `kfn` | $K_{fn}$ | -- | 0.0 | 0.0 | inf | flicker noise coefficient (unit depends on afn) |
| `afn` | $a_{fn}$ | -- | 2.0 | 0.0 | inf | flicker noise current exponent |
| `bfn` | $b_{fn}$ | -- | 1.0 | 0.0 | inf | flicker noise 1/f exponent |
| `sw_fngeo` | -- | -- | 0 | 0 | 1 | switch for flicker noise geometry calculation: 0=drawn, 1=effective |

### Temperature Coefficient Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `ea` | $E_a$ | V | 1.12 | -- | -- | activation voltage for diode temperature dependence |
| `xis` | $x_{is}$ | -- | 3.0 | -- | -- | exponent for diode temperature dependence |
| `tc1` | $TC_1$ | 1/K | 0.0 | -- | -- | resistance linear TC |
| `tc2` | $TC_2$ | 1/K^2 | 0.0 | -- | -- | resistance quadratic TC |
| `tc1l` | $TC_{1l}$ | um/K | 0.0 | -- | -- | resistance linear TC 1/l coefficient |
| `tc2l` | $TC_{2l}$ | um/K^2 | 0.0 | -- | -- | resistance quadratic TC 1/l coefficient |
| `tc1w` | $TC_{1w}$ | um/K | 0.0 | -- | -- | resistance linear TC 1/w coefficient |
| `tc2w` | $TC_{2w}$ | um/K^2 | 0.0 | -- | -- | resistance quadratic TC 1/w coefficient |
| `tc1wl` | $TC_{1wl}$ | um^2/K | 0.0 | -- | -- | resistance linear TC 1/(w*l) coefficient |
| `tc2wl` | $TC_{2wl}$ | um^2/K^2 | 0.0 | -- | -- | resistance quadratic TC 1/(w*l) coefficient |
| `tc1rc` | $TC_{1rc}$ | 1/K | 0.0 | -- | -- | contact resistance linear TC |
| `tc2rc` | $TC_{2rc}$ | 1/K^2 | 0.0 | -- | -- | contact resistance quadratic TC |
| `tc1dp` | $TC_{1dp}$ | 1/K | 0.0 | -- | -- | depletion potential linear TC |
| `tc2dp` | $TC_{2dp}$ | 1/K^2 | 0.0 | -- | -- | depletion potential quadratic TC |
| `tc1kfn` | $TC_{1kfn}$ | 1/K | 0.0 | -- | -- | flicker noise coefficient linear TC |
| `tc1vbv` | $TC_{1vbv}$ | 1/K | 0.0 | -- | -- | breakdown voltage linear TC |
| `tc2vbv` | $TC_{2vbv}$ | 1/K^2 | 0.0 | -- | -- | breakdown voltage quadratic TC |
| `tc1nbv` | $TC_{1nbv}$ | 1/K | 0.0 | -- | -- | breakdown ideality factor linear TC |

### Thermal Network Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `tegth` | $t_{egth}$ | -- | 0.0 | -inf | 0.0 | thermal conductance temperature exponent |
| `gth0` | $G_{th0}$ | W/K | 1e6 | 0.0 | inf | thermal conductance fixed component |
| `gthp` | $G_{thp}$ | W/K/um | 0.0 | 0.0 | inf | thermal conductance perimeter component |
| `gtha` | $G_{tha}$ | W/K/um^2 | 0.0 | 0.0 | inf | thermal conductance area component |
| `gthc` | $G_{thc}$ | W/K | 0.0 | 0.0 | inf | thermal conductance contact component |
| `cth0` | $C_{th0}$ | s*W/K | 0.0 | 0.0 | inf | thermal capacitance fixed component |
| `cthp` | $C_{thp}$ | s*W/K/um | 0.0 | 0.0 | inf | thermal capacitance perimeter component |
| `ctha` | $C_{tha}$ | s*W/K/um^2 | 0.0 | 0.0 | inf | thermal capacitance area component |
| `cthc` | $C_{thc}$ | s*W/K | 0.0 | 0.0 | inf | thermal capacitance contact component |

### Statistical Variation Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| `nsig_rsh` | $n_{\sigma,rsh}$ | -- | 0.0 | -- | -- | number of standard deviations of global variation for rsh |
| `nsig_w` | $n_{\sigma,w}$ | -- | 0.0 | -- | -- | number of standard deviations of global variation for w |
| `nsig_l` | $n_{\sigma,l}$ | -- | 0.0 | -- | -- | number of standard deviations of global variation for l |
| `sig_rsh` | $\sigma_{rsh}$ | % | 0.0 | 0.0 | inf | global variation standard deviation for rsh (relative) |
| `sig_w` | $\sigma_w$ | um | 0.0 | 0.0 | inf | global variation standard deviation for w (absolute) |
| `sig_l` | $\sigma_l$ | um | 0.0 | 0.0 | inf | global variation standard deviation for l (absolute) |
| `smm_rsh` | $smm_{rsh}$ | %*um | 0.0 | 0.0 | inf | local variation standard deviation for rsh (relative) |
| `smm_w` | $smm_w$ | um^1.5 | 0.0 | 0.0 | inf | local variation standard deviation for w (absolute) |
| `smm_l` | $smm_l$ | um^1.5 | 0.0 | 0.0 | inf | local variation standard deviation for l (absolute) |
| `sw_mmgeo` | -- | -- | 0 | 0 | 1 | switch for mismatch geometry calculation: 0=drawn, 1=effective |

## Equations

### Geometry Dependence

#### Drawn Dimensions (um)

$$
l_{um} = l \cdot scale \cdot (1 - shrink/100) \cdot 10^6 \tag{1}
$$

$$
w_{um} = w \cdot scale \cdot (1 - shrink/100) \cdot 10^6 \tag{2}
$$

#### Effective Length Offset

$$
xl_{eff} = \bigl(xl + xlw / w_{um}\bigr) \cdot \frac{(c_1 > 0) + (c_2 > 0)}{2} \tag{3}
$$

Zero if neither end contacted, full value if both contacted, half if one contacted.

#### Effective Length

$$
l_{eff,um} = l_{um} + xl_{eff} \tag{4}
$$

#### Effective Width

$$
w_{eff,um} = \frac{w_{um} + xw + (nwxw / w_{um}) + fdx_{\infty} \cdot \bigl(1 - \exp(-w_{um}/fdrw)\bigr)}{1 - wexw \cdot wd_{um} / (l_{um} \cdot w_{um})} \tag{5}
$$

#### Dogbone Width (um)

$$
wd_{um} = wd \cdot scale \cdot (1 - shrink/100) \cdot 10^6 \tag{6}
$$

#### Depletion Factor Geometry Dependence

$$
df = df_{\infty} + \frac{df_w}{W} + \frac{df_l}{L} + \frac{df_{wl}}{W \cdot L} \tag{7}
$$

$W$ and $L$ are effective geometries if `sw_dfgeo`=1, drawn geometries otherwise (in um).

#### Depletion Potential Geometry Dependence

$$
dp_i = dp \cdot \left(1 + \frac{dp_w}{W^{dp_{we}}}\right) \cdot \left(1 + \frac{dp_l}{L^{dp_{le}}}\right) \cdot \left(1 + \frac{dp_{wl}}{W^{dp_{we}} \cdot L^{dp_{le}}}\right) \tag{8}
$$

(In version 1.0.0, $dp_i = dp$.)

#### Zero-Bias Resistance

$$
R_0 = rsh \cdot \frac{l_{eff,um}}{w_{eff,um}} \cdot \left(1.0 - df \cdot \sqrt{dp_i}\right), \quad g_f = 1/R_0 \tag{9}
$$

#### Effective Temperature Coefficients

$$
TC_1^{eff} = tc1 + \frac{tc1w}{w_{eff,um}} + \frac{0.5 \cdot [(c_1>0)+(c_2>0)]}{l_{eff,um}} \cdot \left(tc1l + \frac{tc1wl}{w_{eff,um}}\right) \tag{10}
$$

$$
TC_2^{eff} = tc2 + \frac{tc2w}{w_{eff,um}} + \frac{0.5 \cdot [(c_1>0)+(c_2>0)]}{l_{eff,um}} \cdot \left(tc2l + \frac{tc2wl}{w_{eff,um}}\right) \tag{11}
$$

Length dependence is switched on/off/halved depending on whether both ends, no ends, or one end is contacted.

#### Thermal Conductance and Capacitance

$$
G_{TH} = gth0 + gthp \cdot p_{um} + gtha \cdot a_{um2} + gthc \cdot (c_1 + c_2) \tag{12}
$$

$$
C_{TH} = cth0 + cthp \cdot p_{um} + ctha \cdot a_{um2} + cthc \cdot (c_1 + c_2) \tag{13}
$$

where:

$$
a_{um2} = l_{um} \cdot w_{um} \tag{14}
$$

$$
p_{um} = 2 \cdot l_{um} + [(c_1 > 0) + (c_2 > 0)] \cdot w_{um} \tag{15}
$$

#### End Resistances

$$
R_{e1} = \frac{rc + rcw / w_{um}}{c_1}, \quad R_{e2} = \frac{rc + rcw / w_{um}}{c_2} \tag{17}
$$

#### Partition Area and Perimeter Scaling

$$
p_{1,um} = p_1 \cdot scale \cdot (1 - shrink/100) \cdot 10^6 \tag{18}
$$

$$
a_{1,um2} = a_1 \cdot \bigl[scale \cdot (1 - shrink/100) \cdot 10^6\bigr]^2 \tag{19}
$$

$$
p_{2,um} = p_2 \cdot scale \cdot (1 - shrink/100) \cdot 10^6 \tag{20}
$$

$$
a_{2,um2} = a_2 \cdot \bigl[scale \cdot (1 - shrink/100) \cdot 10^6\bigr]^2 \tag{21}
$$

#### Contact Count Calculation (scalable contacts)

$$
c_{[1,2]} = \frac{\max(w + wd,\; w_c + 2 \cdot w_{c2e}) - 2 \cdot w_{c2e}}{w_c} \tag{22}
$$

#### Contact Count Calculation (fixed-width contacts)

$$
c_{[1,2]} = \text{int}\!\left(\frac{\max(w + wd,\; w_c + 2 \cdot w_{c2e}) - 2 \cdot w_{c2e} + w_{c2c}}{w_c + w_{c2c}}\right) \tag{23}
$$

### Temperature Dependence

#### Resistance Temperature Factor

$$
R_0(T) = R_0 \cdot tfac \tag{24}
$$

$$
tfac = 1 + TC_1^{eff} \cdot dT + TC_2^{eff} \cdot dT^2 \tag{25}
$$

$dT$ = temperature difference (including self-heating) with respect to `tnom`. $tfac$ is smoothly limited to a minimum of 0.01.

$$
g_f = 1 / R_0(T) \tag{26}
$$

#### Depletion Potential Temperature Dependence

$$
dp(T) = dp_i \cdot \bigl(1 + tc1dp \cdot dT + tc2dp \cdot dT^2\bigr) \tag{27}
$$

#### Velocity Saturation Temperature Dependence (sw_vsatt=1)

$$
E_{corn}(T) = ecorn \cdot r_T^{x_{vsat}} \cdot tfac \tag{28}
$$

$$
E_{crit}(T) = ecrit \cdot r_T^{x_{vsat}} \cdot tfac \tag{29}
$$

where $r_T = T_{dev}(K) / T_{nom}(K)$.

If `sw_vsatt`=0 (default), no temperature dependence on velocity saturation fields.

#### End Resistance Temperature Dependence

$$
R_{e[1,2]}(T) = R_{e[1,2]} \cdot \bigl(1 + tc1rc \cdot dT + tc2rc \cdot dT^2\bigr) \tag{30}
$$

Temperature coefficient limited to minimum 0.01.

#### Diode Saturation Current Temperature Dependence

$$
I_{sa}(T) = isa \cdot r_T^{xis/na} \cdot \exp\!\left(-ea \cdot \frac{1 - r_T}{na \cdot \phi_t}\right) \tag{31}
$$

$$
I_{sp}(T) = isp \cdot r_T^{xis/np} \cdot \exp\!\left(-ea \cdot \frac{1 - r_T}{np \cdot \phi_t}\right) \tag{32}
$$

where $\phi_t = kT/q$.

#### Built-in Potential Temperature Dependence

$$
P_a(T) = pa \cdot r_T - 3 \cdot \phi_t \cdot \ln(r_T) - ea \cdot (r_T - 1) \tag{33}
$$

$$
P_p(T) = pp \cdot r_T - 3 \cdot \phi_t \cdot \ln(r_T) - ea \cdot (r_T - 1) \tag{34}
$$

Smoothly limited to zero for high temperatures (never negative).

#### Zero-Bias Capacitance Temperature Dependence

$$
C_{ja}(T) = cja \cdot \left(\frac{pa}{P_a(T)}\right)^{ma} \tag{35}
$$

$$
C_{jp}(T) = cjp \cdot \left(\frac{pp}{P_p(T)}\right)^{mp} \tag{36}
$$

#### Flicker Noise Coefficient Temperature Dependence

$$
K_{FN}(T) = kfn \cdot (1 + tc1kfn \cdot dT) \tag{37}
$$

Result clipped to zero as lower limit.

#### Breakdown Voltage and Ideality Temperature Dependence

$$
V_{bv}(T) = vbv \cdot \bigl(1 + tc1vbv \cdot dT + tc2vbv \cdot dT^2\bigr) \tag{38}
$$

$$
n_{bv}(T) = nbv \cdot (1 + tc1nbv \cdot dT) \tag{39}
$$

#### Thermal Conductance Temperature Dependence

$$
G_{TH}(T) = G_{TH} \cdot r_T^{tegth}
$$

(From Verilog-A source; `tegth` <= 0.)

### Bias Dependence of Resistor Body Current

#### Depletion Pinching

$$
I_{depl} = g \cdot V_{21}, \quad g = g_f \cdot \bigl(1 - df \cdot \sqrt{dp + V_i}\bigr), \quad V_i = V_{21} + 2 \cdot V_{1c} \tag{40}
$$

where $V_{21} = V(i_2) - V(i_1)$ and $V_{1c} = V(i_1) - V(nc)$.

#### Velocity Saturation: Mobility Reduction Factor

$$
r_\mu = \sqrt{\left(\frac{E - E_{ce}}{2 \cdot ecrit}\right)^2 + du_e} + \sqrt{\left(\frac{E + E_{ce}}{2 \cdot ecrit}\right)^2 + du_e} - \sqrt{\left(\frac{E_{ce}}{ecrit}\right)^2 + 4 \cdot du_e} \tag{41}
$$

where:
- $E = V_{21} / (l_{eff,um} + dxlsat)$
- $E_{ce} = \sqrt{ecorn^2 + (2 \cdot du \cdot ecrit)^2} - 2 \cdot du \cdot ecrit$
- $du_e = du \cdot E_{ce} / ecrit$

Asymptotically approaches $(E - ecorn)/ecrit$ for large $E$. Value is 0 when $V_{21}=0$, smooth and symmetric.

#### Saturation Voltage Limiting

$$
V_{21,eff} = \frac{2 \cdot V_{21} \cdot V_{sat}}{\sqrt{(V_{21} - V_{sat})^2 + 4 \cdot ats_i} + \sqrt{(V_{21} + V_{sat})^2 + 4 \cdot ats_i}} \tag{42}
$$

$$
ats_i = \frac{ats}{1 + atsl / l_{eff,um}}
$$

$V_{sat}$ is the $V_{21}$ at which output conductance becomes zero, solved in closed form from the asymptotic velocity saturation model. The limiting function preserves symmetry.

#### Control Voltage Limiting (Pinch-off)

$$
V_{1c,eff} = V_{po} - nst \cdot \phi_t \cdot \ln\!\left(1 + \exp\!\left(\frac{V_{po} - V_{1c}}{nst \cdot \phi_t}\right)\right) \tag{43}
$$

$$
V_{po} = \frac{1}{2 \cdot df^2} - 0.5 \cdot dp, \quad \phi_t = kT/q
$$

#### Body Current

$$
I_{21} = \frac{I_{depl}}{1 + r_\mu} \tag{44}
$$

### Bias Dependence of Parasitics

#### Parasitic Diode Currents (zero if no area/perimeter saturation current)

$$
I_{p1} = I_{p2} = 0 \quad \text{(if } isa = 0 \text{ and } isp = 0\text{)} \tag{45}
$$

#### Parasitic Diode Currents (diffused resistors)

$$
I_{p1} = p_{1,um} \cdot I_{sp}(T) \cdot \bigl[\exp(V_{c1}/(np \cdot \phi_t)) - 1\bigr] + a_{1,um2} \cdot I_{sa}(T) \cdot \bigl[\exp(V_{c1}/(na \cdot \phi_t)) - 1\bigr] + g_{min} \cdot V_{c1} \tag{46}
$$

$$
I_{p2} = p_{2,um} \cdot I_{sp}(T) \cdot \bigl[\exp(V_{c2}/(np \cdot \phi_t)) - 1\bigr] + a_{2,um2} \cdot I_{sa}(T) \cdot \bigl[\exp(V_{c2}/(na \cdot \phi_t)) - 1\bigr] + g_{min} \cdot V_{c2} \tag{47}
$$

where $V_{c1} = V(nc) - V(i_1)$, $V_{c2} = V(nc) - V(i_2)$. When `sw_accpo`>0, $V_{c1}$ and $V_{c2}$ are limited to pinch-off by a smoothing equation. Each component linearized for forward bias exceeding the voltage at which component current equals `imax`.

#### Breakdown Currents

$$
I_{b1} = -ibv \cdot \Bigl[\exp\!\bigl(-(V_{c1} + V_{bv}(T)) / (n_{bv}(T) \cdot \phi_t)\bigr) - \exp\!\bigl(-V_{bv}(T) / (n_{bv}(T) \cdot \phi_t)\bigr)\Bigr] \tag{48}
$$

$$
I_{b2} = -ibv \cdot \Bigl[\exp\!\bigl(-(V_{c2} + V_{bv}(T)) / (n_{bv}(T) \cdot \phi_t)\bigr) - \exp\!\bigl(-V_{bv}(T) / (n_{bv}(T) \cdot \phi_t)\bigr)\Bigr] \tag{49}
$$

Each linearized for reverse biases exceeding the voltage at which |current| = `imax`.

#### Parasitic Capacitances

$$
C_{p1} = p_{1,um} \cdot \left(cp + \frac{C_{jp}(T)}{[1 - V_{c1}/P_p(T)]^{mp}}\right) + a_{1,um2} \cdot \left(ca + \frac{C_{ja}(T)}{[1 - V_{c1}/P_a(T)]^{ma}}\right) \tag{50}
$$

$$
C_{p2} = p_{2,um} \cdot \left(cp + \frac{C_{jp}(T)}{[1 - V_{c2}/P_p(T)]^{mp}}\right) + a_{2,um2} \cdot \left(ca + \frac{C_{ja}(T)}{[1 - V_{c2}/P_a(T)]^{ma}}\right) \tag{51}
$$

When junction voltage reaches $f_c$ times the built-in potential, capacitance becomes linear in voltage. If `aja`/`ajp` > 0, the transition is smooth.

### Noise

#### Thermal Noise (Resistor Body)

$$
\overline{i^2_{thermal,body}} = 4 \cdot k \cdot T_K \cdot G_{eff}(T) \tag{52}
$$

$k$ = Boltzmann's constant, $T_K$ = device temperature in Kelvin (including self-heating), $G_{eff}(T)$ = effective body conductance at operating point.

#### Thermal Noise (End Resistances)

$$
\overline{i^2_{thermal,end}} = 4 \cdot k \cdot T_K / R_e(T) \tag{53}
$$

#### Flicker Noise (Resistor Body)

$$
\overline{i^2_{flicker,body}} = K_{FN}(T) \cdot \frac{I_{21}^{afn}}{W} \cdot \frac{W}{L} \cdot \frac{1}{f^{bfn}} \tag{54}
$$

$W$ and $L$ are drawn geometries ($w_{um}$, $l_{um}$) if `sw_fngeo`=0, effective geometries ($w_{eff,um}$, $l_{eff,um}$) if `sw_fngeo`=1.

#### Shot Noise (Parasitic Diodes)

$$
\overline{i^2_{shot,diode}} = 2 \cdot q \cdot I_{diode} \tag{55}
$$

For each parasitic diode, where $I_{diode}$ is the DC diode current.

### Statistical Variation

#### Total Variance

$$
\sigma^2_{total} = \sigma^2_{global} + \sigma^2_{local}(\vec{g}) \tag{56}
$$

#### Mismatch Analysis Selected (sw_mman=1)

$$
w_{eff,um} = w_{eff,um,nom} + n_{\sigma,w} \cdot \sigma_w + \frac{nsmm_w \cdot smm_w}{\sqrt{m \cdot L}} \tag{57}
$$

$$
l_{eff,um} = l_{eff,um,nom} + n_{\sigma,l} \cdot \sigma_l + \frac{nsmm_l \cdot smm_l}{\sqrt{m \cdot W}} \tag{58}
$$

$$
rsh = rsh_{nom} \cdot \exp\!\left(0.01 \cdot \left(n_{\sigma,rsh} \cdot \sigma_{rsh} + \frac{nsmm_{rsh} \cdot smm_{rsh}}{\sqrt{m \cdot W \cdot L}}\right)\right) \tag{59}
$$

$m$ = multiplicity factor.

#### Mismatch Analysis Not Selected (sw_mman=0)

$$
w_{eff,um} = w_{eff,um,nom} + n_{\sigma,w} \cdot \sqrt{\sigma_w^2 + smm_w^2 / (m \cdot L)} \tag{60}
$$

$$
l_{eff,um} = l_{eff,um,nom} + n_{\sigma,l} \cdot \sqrt{\sigma_l^2 + smm_l^2 / (m \cdot W)} \tag{61}
$$

$$
rsh = rsh_{nom} \cdot \exp\!\left(0.01 \cdot n_{\sigma,rsh} \cdot \sqrt{\sigma_{rsh}^2 + smm_{rsh}^2 / (m \cdot W \cdot L)}\right) \tag{62}
$$

## Operating Point Information

| Name | Unit | Description |
|------|------|-------------|
| `v` | V | voltage across resistor body |
| `ibody` | A | current through resistor body |
| `power` | W | dissipated power |
| `leff_um` | um | effective electrical length |
| `weff_um` | um | effective electrical width |
| `r0` | Ohm | zero-bias resistance |
| `r_dc` | Ohm | DC resistance (including bias dependence) |
| `r_ac` | Ohm | AC resistance (including bias dependence) |
| `rth` | K/W | thermal resistance |
| `cth` | s*W/K | thermal capacitance |
| `dt_et` | K | self-heating temperature rise |
