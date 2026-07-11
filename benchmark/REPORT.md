note: xyce not found — comparison disabled

fixture                                  zp-cpu       zp-gpu      ngspice         xyce  cpu/ng  gpu/ng     zp-MB    ng-MB    xy-MB     cpu-max    cpu-rms   cpu     gpu-max    gpu-rms   gpu
---------------------------------- ------------ ------------ ------------ ------------ ------- -------  -------- -------- --------  ---------- ---------- -----  ---------- ---------- -----
ac/rc_lowpass                           3.74 ms    271.11 ms      8.38 ms            -    2.2x    0.0x      7.7    12.0        -           -          -     -           -          -     -

adversarial/extreme_values              3.36 ms    275.30 ms      8.54 ms            -    2.5x    0.0x      7.7    11.5        -           -          -     -           -          -     -
adversarial/near_singular               3.63 ms    214.16 ms      9.27 ms            -    2.6x    0.0x      7.7    11.7        -     1.67e-1    1.67e-1  FAIL     1.67e-1    1.67e-1  FAIL
adversarial/tiny_resistor               3.71 ms    236.93 ms      8.37 ms            -    2.3x    0.0x      7.7    11.7        -     9.99e-7    9.99e-7  PASS     9.99e-7    9.99e-7  PASS

analog/current_mirror                   3.83 ms    239.30 ms      7.14 ms            -    1.9x    0.0x      8.9    12.0        -     2.08e-6    2.08e-6  PASS     5.52e-6    5.52e-6  PASS
analog/diff_pair                        4.36 ms    234.79 ms      8.44 ms            -    1.9x    0.0x      9.0    11.9        -     3.50e-5    3.50e-5  PASS     3.25e-5    3.25e-5  PASS
analog/opamp_inverting                  3.48 ms    231.12 ms      9.11 ms            -    2.6x    0.0x      8.2    10.9        -     8.77e-8    8.77e-8  PASS     8.77e-8    8.77e-8  PASS

basic/rc_transient                      3.99 ms    227.15 ms      9.55 ms            -    2.4x    0.0x      7.7    11.7        -    9.49e-10   9.49e-10  PASS    9.49e-10   9.49e-10  PASS
basic/voltage_divider                   3.31 ms    224.52 ms      6.81 ms            -    2.1x    0.0x      7.7    11.7        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS

bjt/cascode                             6.97 ms    269.37 ms      8.31 ms            -    1.2x    0.0x      8.8    11.7        -     1.60e-5    1.60e-5  PASS     1.60e-5    1.60e-5  PASS
bjt/common_emitter                      4.95 ms    212.79 ms      9.60 ms            -    1.9x    0.0x      9.0    11.8        -           -          -     -           -          -     -
bjt/diff_amp                            7.43 ms    273.24 ms      9.48 ms            -    1.3x    0.0x      9.0    11.7        -     1.19e-4    2.82e-5  PASS     1.18e-4    2.93e-5  PASS

bypass/burst_clock                     22.45 ms    287.89 ms     10.62 ms            -    0.5x    0.0x      8.3    12.0        -     3.50e-4    1.04e-5  PASS     3.50e-4    1.04e-5  PASS
bypass/gated_branch                        skip         skip     18.90 ms            -       -       -         -    12.0        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
bypass/idle_ladder                    234.23 ms    426.28 ms     13.78 ms            -    0.1x    0.0x      8.8    12.0        -     6.50e-4    1.16e-4  PASS     1.31e-3    1.01e-4  PASS

convergence/diode_bridge                4.44 ms    250.01 ms      9.01 ms            -    2.0x    0.0x      8.6    11.8        -      5.89e0     5.89e0  FAIL     8.32e-1    8.32e-1  FAIL
convergence/high_gain_fb                4.21 ms    238.49 ms      8.82 ms            -    2.1x    0.0x      8.2    11.7        -    1.11e-15   1.11e-15  PASS    8.88e-16   8.88e-16  PASS
convergence/schmitt                     3.62 ms    235.77 ms      8.68 ms            -    2.4x    0.0x      8.2    11.6        -     5.00e-9    5.00e-9  PASS     5.00e-9    5.00e-9  PASS

dc_sweep/nested_sweep                   3.82 ms    247.93 ms      8.84 ms            -    2.3x    0.0x      8.5    11.8        -           -          -     -           -          -     -
dc_sweep/param_sweep                    4.27 ms    224.93 ms      7.19 ms            -    1.7x    0.0x      8.6    11.4        -     3.28e-5    6.25e-6  PASS     3.28e-5    6.25e-6  PASS
dc_sweep/vin_sweep                      3.60 ms    223.60 ms      6.98 ms            -    1.9x    0.0x      7.4    11.7        -     1.38e-8    8.07e-9  PASS     1.38e-8    8.07e-9  PASS

devices/b3soidd                         3.48 ms    224.62 ms         skip            -       -       -      8.9        -        -           -          -     -           -          -     -
devices/b3soidd_output                  6.22 ms    260.42 ms         skip            -       -       -      8.5        -        -           -          -     -           -          -     -
devices/b3soifd                         4.50 ms    267.47 ms         skip            -       -       -      9.1        -        -           -          -     -           -          -     -
devices/b3soifd_output                  9.16 ms    249.22 ms         skip            -       -       -      8.8        -        -           -          -     -           -          -     -
devices/b3soipd                         5.03 ms    252.40 ms      9.87 ms            -    2.0x    0.0x     10.1    12.2        -      1.75e0     1.75e0  FAIL      1.75e0     1.75e0  FAIL
devices/b3soipd_output                 16.07 ms    262.92 ms     34.97 ms            -    2.2x    0.1x      9.6    12.0        -           -          -     -           -          -     -
devices/b4soi                           3.24 ms    270.94 ms      9.73 ms            -    3.0x    0.0x      8.9    12.3        -     3.31e-1    3.31e-1  FAIL     3.31e-1    3.31e-1  FAIL
devices/b4soi_output                    5.10 ms    257.86 ms     25.28 ms            -    5.0x    0.1x      8.5    12.0        -           -          -     -           -          -     -
devices/bjt_npn                         3.53 ms    270.86 ms      8.75 ms            -    2.5x    0.0x      8.4    12.0        -     5.00e-8    5.00e-8  PASS     2.48e-7    2.48e-7  PASS
devices/bjt_npn_early                  12.43 ms    268.94 ms     10.21 ms            -    0.8x    0.0x      7.8    11.7        -           -          -     -           -          -     -
devices/bjt_npn_gummel                  6.58 ms    255.31 ms      8.33 ms            -    1.3x    0.0x      8.2    11.8        -     2.86e-8    1.39e-8  PASS     2.86e-8    1.39e-8  PASS
devices/bjt_npn_high_injection          7.77 ms    273.01 ms      8.28 ms            -    1.1x    0.0x      8.2    11.8        -           -          -     -           -          -     -
devices/bjt_npn_output                  5.82 ms    253.88 ms     13.87 ms            -    2.4x    0.1x      8.2    11.5        -           -          -     -           -          -     -
devices/bjt_npn_saturation              7.50 ms    253.33 ms     10.45 ms            -    1.4x    0.0x      7.9    11.3        -           -          -     -           -          -     -
devices/bjt_npn_temp                    5.80 ms    259.79 ms     10.68 ms            -    1.8x    0.0x      8.2    11.8        -           -          -     -           -          -     -
devices/bjt_pnp                         4.21 ms    259.22 ms      6.39 ms            -    1.5x    0.0x      8.7    12.0        -     7.59e-8    7.59e-8  PASS     7.59e-8    7.59e-8  PASS
devices/bjt_pnp_output                  6.37 ms    227.19 ms     22.06 ms            -    3.5x    0.1x      8.2    11.3        -           -          -     -           -          -     -
devices/bsim1                           7.01 ms    220.62 ms     10.15 ms            -    1.4x    0.0x      8.4    11.7        -           -          -     -           -          -     -
devices/bsim2                           6.88 ms    258.54 ms     14.26 ms            -    2.1x    0.1x      8.4    11.8        -           -          -     -           -          -     -
devices/bsim2_ngspice                      skip         skip      8.18 ms            -       -       -         -    11.8        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/bsim3                           2.97 ms    268.26 ms      8.30 ms            -    2.8x    0.0x      8.7    12.0        -     8.67e-1    8.67e-1  FAIL     8.67e-1    8.67e-1  FAIL
devices/bsim3_body_effect              10.96 ms    296.96 ms     42.27 ms            -    3.9x    0.1x      8.5    11.9        -           -          -     -           -          -     -
devices/bsim3_output                    7.28 ms    266.12 ms     37.23 ms            -    5.1x    0.1x      8.8    11.9        -           -          -     -           -          -     -
devices/bsim3_pmos                      9.26 ms    264.44 ms     34.13 ms            -    3.7x    0.1x      8.8    11.7        -           -          -     -           -          -     -
devices/bsim3_temp                      9.46 ms    277.10 ms     42.76 ms            -    4.5x    0.2x      8.5    11.5        -           -          -     -           -          -     -
devices/bsim3_transfer                  9.27 ms    255.39 ms     14.26 ms            -    1.5x    0.1x      8.5    11.9        -     3.18e-8    2.38e-8  PASS     3.18e-8    2.38e-8  PASS
devices/bsim4                              skip         skip      9.17 ms            -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/bsim4_output                   12.47 ms    270.61 ms     20.31 ms            -    1.6x    0.1x      9.4    12.2        -           -          -     -           -          -     -
devices/bsim4_pmos                     11.41 ms    240.24 ms     19.76 ms            -    1.7x    0.1x      9.4    12.2        -           -          -     -           -          -     -
devices/bsim4_transfer                 16.16 ms    658.37 ms     12.88 ms            -    0.8x    0.0x      9.1    12.2        -     5.20e-8    1.53e-8  PASS     5.20e-8    1.53e-8  PASS
devices/bsource                         3.21 ms    256.20 ms      7.76 ms            -    2.4x    0.0x      8.1    11.9        -     5.82e-8    2.12e-8  PASS     5.82e-8    2.12e-8  PASS
devices/capacitor                       4.25 ms    257.18 ms      8.82 ms            -    2.1x    0.0x      7.7    12.2        -     1.00e-9    1.00e-9  PASS     1.00e-9    1.00e-9  PASS
devices/capacitor_ac                    4.19 ms    269.41 ms      8.09 ms            -    1.9x    0.0x      7.7    12.2        -           -          -     -           -          -     -
devices/cccs                            3.40 ms    256.26 ms      7.96 ms            -    2.3x    0.0x      8.3    11.9        -    5.00e-10   5.00e-10  PASS    5.00e-10   5.00e-10  PASS
devices/ccvs                            3.17 ms    266.02 ms      9.00 ms            -    2.8x    0.0x      8.4    11.7        -     4.75e-8    4.75e-8  PASS     4.75e-8    4.75e-8  PASS
devices/coupled_tlines                  9.37 ms    277.46 ms     11.54 ms            -    1.2x    0.0x      8.2    12.2        -     6.45e-1    2.18e-1  FAIL     6.45e-1    2.18e-1  FAIL
devices/cswitch                         5.16 ms    245.21 ms      9.49 ms            -    1.8x    0.0x      8.1    11.9        -     4.99e-1    3.44e-2  FAIL     2.20e-1    1.51e-2  FAIL
devices/diode                           3.43 ms    241.30 ms      8.66 ms            -    2.5x    0.0x      8.6    11.6        -     1.34e-7    1.34e-7  PASS     1.34e-7    1.34e-7  PASS
devices/diode_breakdown               676.20 ms    885.70 ms      9.89 ms            -    0.0x    0.0x      8.3    11.7        -         inf        inf  FAIL         inf        inf  FAIL
devices/diode_capacitance               4.10 ms    252.07 ms      9.08 ms            -    2.2x    0.0x      8.1    11.9        -           -          -     -           -          -     -
devices/diode_high_injection            6.81 ms    274.01 ms      8.37 ms            -    1.2x    0.0x      7.8    11.8        -     2.86e-8    1.30e-8  PASS     2.86e-8    1.30e-8  PASS
devices/diode_iv_sweep                 11.71 ms    259.90 ms     11.82 ms            -    1.0x    0.0x      8.1    11.9        -     3.81e-8    1.18e-8  PASS     3.81e-8    1.18e-8  PASS
devices/diode_recombination             6.88 ms    252.15 ms      9.05 ms            -    1.3x    0.0x      8.1    11.9        -     2.96e-8    1.17e-8  PASS     2.96e-8    1.17e-8  PASS
devices/diode_temp                      5.52 ms    238.46 ms     10.50 ms            -    1.9x    0.0x      7.8    11.9        -           -          -     -           -          -     -
devices/hfet1                           3.41 ms    263.07 ms      8.64 ms            -    2.5x    0.0x      8.2    11.7        -    5.00e-10   5.00e-10  PASS    5.00e-10   5.00e-10  PASS
devices/hfet1_output                    4.56 ms    235.23 ms     13.37 ms            -    2.9x    0.1x      7.2    11.9        -           -          -     -           -          -     -
devices/hfet2                           3.44 ms    268.36 ms      9.24 ms            -    2.7x    0.0x      8.2    11.9        -     1.04e-3    1.04e-3  FAIL     1.04e-3    1.04e-3  FAIL
devices/hfet2_output                    4.67 ms    276.84 ms     13.36 ms            -    2.9x    0.0x      7.5    11.9        -           -          -     -           -          -     -
devices/hfet_id_vgs                     4.35 ms    284.75 ms      8.87 ms            -    2.0x    0.0x      7.5    12.0        -     2.86e-8    1.29e-8  PASS     2.86e-8    1.29e-8  PASS
devices/hfet_inverter                  12.67 ms    263.32 ms     15.79 ms            -    1.2x    0.1x      7.5    11.9        -     9.47e-1    8.79e-1  FAIL     9.47e-1    8.79e-1  FAIL
devices/hicum2                         17.52 ms    294.96 ms      9.26 ms            -    0.5x    0.0x      8.7    12.0        -     9.91e-1    9.91e-1  FAIL     9.91e-1    9.91e-1  FAIL
devices/hicum2_gummel                   6.48 ms    247.29 ms     10.22 ms            -    1.6x    0.0x      7.9    12.2        -           -          -     -           -          -     -
devices/hicum2_output                   6.23 ms    226.55 ms     22.71 ms            -    3.6x    0.1x      7.8    11.8        -           -          -     -           -          -     -
devices/hisim2                          4.46 ms    276.97 ms     26.09 ms            -    5.9x    0.1x      8.5    12.0        -           -          -     -           -          -     -
devices/hisimhv                         5.33 ms    246.70 ms         skip            -       -       -      8.1        -        -           -          -     -           -          -     -
devices/inductor                        6.51 ms    240.11 ms     10.86 ms            -    1.7x    0.0x      7.7    12.1        -    1.01e-13   1.01e-13  PASS    1.01e-13   1.01e-13  PASS
devices/inductor_ac                     4.57 ms    231.23 ms      8.16 ms            -    1.8x    0.0x      7.7    12.0        -           -          -     -           -          -     -
devices/isource                         3.86 ms    253.05 ms      8.39 ms            -    2.2x    0.0x      7.8    12.2        -    2.50e-10   2.50e-10  PASS    2.50e-10   2.50e-10  PASS
devices/jfet                            4.14 ms    261.26 ms      8.46 ms            -    2.0x    0.0x      8.6    12.0        -     1.02e-1    1.02e-1  FAIL     1.02e-1    1.02e-1  FAIL
devices/jfet2                           6.54 ms    222.28 ms     10.24 ms            -    1.6x    0.0x      8.1    12.0        -           -          -     -           -          -     -
devices/jfet_output                     6.24 ms    214.78 ms     13.79 ms            -    2.2x    0.1x      8.2    12.0        -           -          -     -           -          -     -
devices/jfet_transfer                   7.73 ms    275.58 ms      8.35 ms            -    1.1x    0.0x      8.2    12.0        -     3.27e-8    1.19e-8  PASS     3.27e-8    1.19e-8  PASS
devices/jfet_vds_vgs                    4.61 ms    269.14 ms      6.74 ms            -    1.5x    0.0x      8.1    11.5        -           -          -     -           -          -     -
devices/kinduc                             skip    312.98 ms     11.42 ms            -       -    0.0x         -    11.9        -           -          -     -         inf        inf  FAIL
    zp-cpu: TimestepTooSmall
devices/lossy_tline                     7.84 ms    330.87 ms     17.52 ms            -    2.2x    0.1x      8.3    12.0        -      4.55e0     1.63e0  FAIL      4.55e0     1.63e0  FAIL
devices/mesa                            3.78 ms    276.31 ms      9.12 ms            -    2.4x    0.0x      8.2    11.7        -     1.28e-2    1.28e-2  FAIL     1.28e-2    1.28e-2  FAIL
devices/mesa_inverter                   9.07 ms    258.01 ms      9.74 ms            -    1.1x    0.0x      8.6    11.5        -     9.76e-1    6.49e-1  FAIL     9.76e-1    6.49e-1  FAIL
devices/mesa_oscillator                25.23 ms    241.86 ms     29.48 ms            -    1.2x    0.1x      8.7    12.0        -     5.66e-1    4.22e-1  FAIL     5.66e-1    4.22e-1  FAIL
devices/mesa_output                     4.49 ms    243.72 ms     14.61 ms            -    3.3x    0.1x      7.5    11.7        -           -          -     -           -          -     -
devices/mesfet                          3.24 ms    234.03 ms      8.92 ms            -    2.8x    0.0x      8.2    11.9        -     3.32e-9    3.32e-9  PASS     3.32e-9    3.32e-9  PASS
devices/mesfet_output                   4.61 ms    228.15 ms     11.10 ms            -    2.4x    0.0x      7.5    12.0        -           -          -     -           -          -     -
devices/mesfet_subthreshold             4.20 ms    256.21 ms      9.02 ms            -    2.1x    0.0x      7.5    11.5        -     3.18e-8    1.46e-8  PASS     3.18e-8    1.46e-8  PASS
devices/mesfet_transfer                 5.36 ms    245.83 ms      8.21 ms            -    1.5x    0.0x      7.5    11.7        -     2.29e-8    9.35e-9  PASS     2.29e-8    9.35e-9  PASS
devices/mos1_body_effect               11.66 ms    242.53 ms     11.44 ms            -    1.0x    0.0x      8.5    11.8        -           -          -     -           -          -     -
devices/mos1_large_signal              19.84 ms    254.16 ms     13.44 ms            -    0.7x    0.1x      8.3    11.7        -     1.05e-2    2.07e-3  FAIL     1.05e-2    2.07e-3  FAIL
devices/mos1_output                     6.60 ms    254.69 ms     13.44 ms            -    2.0x    0.1x      8.5    12.0        -           -          -     -           -          -     -
devices/mos1_pmos                       5.55 ms    230.88 ms     14.37 ms            -    2.6x    0.1x      8.5    11.6        -           -          -     -           -          -     -
devices/mos1_subthreshold              11.19 ms    233.16 ms     10.79 ms            -    1.0x    0.0x      8.5    11.9        -     3.94e-8    1.50e-8  PASS     3.94e-8    1.50e-8  PASS
devices/mos1_temp                      10.80 ms    240.60 ms     10.28 ms            -    1.0x    0.0x      8.2    11.7        -           -          -     -           -          -     -
devices/mos1_transfer                   7.95 ms    244.53 ms     11.15 ms            -    1.4x    0.0x      8.5    12.0        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos2                            7.05 ms    243.29 ms     12.80 ms            -    1.8x    0.1x      8.4    12.0        -           -          -     -           -          -     -
devices/mos2_transfer                  10.95 ms    251.14 ms      7.58 ms            -    0.7x    0.0x      8.2    11.9        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos3                            7.90 ms    248.92 ms     15.73 ms            -    2.0x    0.1x      8.1    12.0        -           -          -     -           -          -     -
devices/mos3_transfer                  14.27 ms    268.52 ms     10.33 ms            -    0.7x    0.0x      8.4    12.0        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos6                            6.58 ms    274.90 ms     14.88 ms            -    2.3x    0.1x      8.4    11.7        -           -          -     -           -          -     -
devices/mos6_inverter                      skip         skip     20.33 ms            -       -       -         -    12.0        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/mos6_simpleinv                 49.27 ms    311.84 ms      9.97 ms            -    0.2x    0.0x      8.4    11.8        -     4.58e-1    9.43e-2  FAIL     4.58e-1    9.43e-2  FAIL
devices/mos9                            6.42 ms    259.84 ms     14.99 ms            -    2.3x    0.1x      8.4    12.0        -           -          -     -           -          -     -
devices/mosfet_l1                       3.49 ms    230.06 ms      8.24 ms            -    2.4x    0.0x      8.9    11.7        -     1.63e-6    1.63e-6  PASS     1.86e-8    1.86e-8  PASS
devices/resistor                        3.65 ms    230.49 ms      8.73 ms            -    2.4x    0.0x      7.7    11.8        -    5.33e-16   5.33e-16  PASS    5.33e-16   5.33e-16  PASS
devices/resistor_sweep                  3.87 ms    242.26 ms      9.23 ms            -    2.4x    0.0x      7.4    12.0        -     1.91e-8    7.54e-9  PASS     1.91e-8    7.54e-9  PASS
devices/resistor_temp                   3.35 ms    234.07 ms         skip            -       -       -      7.7        -        -           -          -     -           -          -     -
devices/switch                          5.47 ms    236.15 ms      9.44 ms            -    1.7x    0.0x      8.2    11.9        -     4.99e-1    3.44e-2  FAIL     2.20e-1    1.51e-2  FAIL
devices/switch_hysteresis               5.79 ms    221.77 ms      7.39 ms            -    1.3x    0.0x      8.2    12.0        -     4.99e-1    2.45e-2  FAIL     2.20e-1    1.08e-2  FAIL
devices/tline                          11.34 ms    237.25 ms     11.17 ms            -    1.0x    0.0x      8.2    11.5        -     5.00e-1    2.27e-1  FAIL     5.00e-1    2.27e-1  FAIL
devices/urc                            13.28 ms    229.95 ms     11.90 ms            -    0.9x    0.1x      8.9    12.3        -     4.66e-9   5.69e-10  PASS     4.66e-9   5.69e-10  PASS
devices/urc_ac                         10.55 ms    230.42 ms      9.83 ms            -    0.9x    0.0x      8.6    12.3        -           -          -     -           -          -     -
devices/vbic                            5.45 ms    227.89 ms      6.88 ms            -    1.3x    0.0x      9.7    12.3        -      2.36e0     2.36e0  FAIL      2.36e0     2.36e0  FAIL
devices/vbic_ce_amp                        skip    265.30 ms     11.02 ms            -       -    0.0x         -    12.2        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
devices/vbic_diffamp                       skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/vbic_forced_output             14.62 ms    258.26 ms     15.60 ms            -    1.1x    0.1x      9.2    12.3        -           -          -     -           -          -     -
devices/vbic_forward_gummel                skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/vbic_gummel                     5.90 ms    242.30 ms      9.58 ms            -    1.6x    0.0x      8.2    12.3        -     2.86e-8    1.39e-8  PASS     2.86e-8    1.39e-8  PASS
devices/vbic_noise_scale               39.76 ms    257.14 ms      8.81 ms            -    0.2x    0.0x     10.0    12.0        -           -          -     -           -          -     -
devices/vbic_output                     6.97 ms    239.42 ms     17.48 ms            -    2.5x    0.1x      7.9    11.8        -           -          -     -           -          -     -
devices/vbic_temp                      26.29 ms         skip      7.24 ms            -    0.3x       -      8.9    12.3        -     4.77e-8    1.73e-8  PASS           -          -     -
    zp-gpu: OpDidNotConverge
devices/vccs                            3.21 ms    244.76 ms      8.87 ms            -    2.8x    0.0x      8.2    12.0        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS
devices/vcvs                            3.46 ms    232.87 ms      8.77 ms            -    2.5x    0.0x      8.2    11.6        -    6.67e-10   6.67e-10  PASS    6.67e-10   6.67e-10  PASS
devices/vdmos                           3.98 ms    218.51 ms         skip            -       -       -      8.9        -        -           -          -     -           -          -     -
devices/vdmos_output                    6.89 ms    213.78 ms         skip            -       -       -      8.2        -        -           -          -     -           -          -     -
devices/vsource                         4.72 ms    213.11 ms      8.75 ms            -    1.9x    0.0x      7.6    12.0        -    1.43e-15   7.58e-16  PASS    1.95e-15   7.63e-16  PASS

digital/buffer_rc                       5.63 ms    208.66 ms     10.74 ms            -    1.9x    0.1x      7.6    12.2        -     3.06e-4    2.84e-5  PASS     3.06e-4    2.84e-5  PASS
digital/clamp                           5.08 ms    244.47 ms      9.90 ms            -    2.0x    0.0x      8.6    12.3        -     1.88e-2    1.67e-3  FAIL     1.88e-2    1.71e-3  FAIL
digital/rc_filter_chain                 5.81 ms    247.90 ms     10.62 ms            -    1.8x    0.0x      7.6    12.3        -     1.16e-3    9.25e-5  PASS     1.16e-3    9.25e-5  PASS

disto/bjt_ce                            4.09 ms    254.18 ms      7.89 ms            -    1.9x    0.0x      8.7    12.0        -           -          -     -           -          -     -
disto/diode_clipper                     3.11 ms    220.87 ms     10.59 ms            -    3.4x    0.0x      8.6    12.3        -           -          -     -           -          -     -
disto/mos_cs                            4.05 ms    226.23 ms      6.53 ms            -    1.6x    0.0x      8.9    12.0        -           -          -     -           -          -     -

ensemble/corner_pathological            3.42 ms    225.80 ms      9.51 ms            -    2.8x    0.0x      8.6    12.3        -     2.79e-7    2.79e-7  PASS     2.46e-7    2.46e-7  PASS
ensemble/opamp_mc                      36.66 ms    328.68 ms     11.67 ms            -    0.3x    0.0x      8.7    12.2        -     4.61e-6    2.73e-7  PASS     4.61e-6    2.73e-7  PASS
ensemble/pvt_corners                       skip         skip     17.97 ms            -       -       -         -    12.0        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
ensemble/sweep_lanes                    4.21 ms    220.67 ms      8.66 ms            -    2.1x    0.0x      8.6    12.3        -     4.66e-5    7.78e-6  PASS     4.66e-5    7.78e-6  PASS

fourier/clipped_sine                   25.45 ms    301.81 ms      9.65 ms            -    0.4x    0.0x      8.2    12.2        -     2.59e-4    6.16e-5  PASS     2.59e-4    6.16e-5  PASS
fourier/sine_1k                         4.87 ms    252.00 ms      9.49 ms            -    1.9x    0.0x      7.6    11.8        -     1.69e-4    1.19e-4  PASS     1.69e-4    1.19e-4  PASS
fourier/square_harmonics               14.51 ms    274.49 ms     12.00 ms            -    0.8x    0.0x      7.6    12.0        -     2.70e-4    1.80e-5  PASS     2.70e-4    1.80e-5  PASS

golden/ac                               3.26 ms    232.26 ms      8.60 ms            -    2.6x    0.0x      7.7    12.3        -           -          -     -           -          -     -
golden/dc                               3.43 ms    249.26 ms      7.22 ms            -    2.1x    0.0x      7.1    12.0        -     1.38e-8    8.17e-9  PASS     1.38e-8    8.17e-9  PASS
golden/disto                            2.67 ms    226.89 ms      7.66 ms            -    2.9x    0.0x      8.6    12.1        -           -          -     -           -          -     -
golden/four                            11.59 ms    234.23 ms     10.39 ms            -    0.9x    0.0x      8.2    11.9        -     1.85e-3    3.36e-4  PASS     1.85e-3    3.36e-4  PASS
golden/hb                               4.46 ms    236.34 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
golden/noise                            3.68 ms    209.93 ms      8.39 ms            -    2.3x    0.0x      7.7    11.5        -           -          -     -           -          -     -
golden/op                               3.88 ms    227.33 ms      8.94 ms            -    2.3x    0.0x      7.7    11.8        -     1.38e-8    1.38e-8  PASS     1.38e-8    1.38e-8  PASS
golden/pss                             10.62 ms    259.31 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
golden/pz                               4.09 ms    271.05 ms      8.51 ms            -    2.1x    0.0x      7.7    12.3        -           -          -     -           -          -     -
golden/sens                             3.15 ms    280.38 ms      9.01 ms            -    2.9x    0.0x      7.7    12.3        -           -          -     -           -          -     -
golden/sp                               3.91 ms    278.09 ms      9.75 ms            -    2.5x    0.0x      7.7    11.7        -           -          -     -           -          -     -
golden/stb                              3.64 ms    277.53 ms         skip            -       -       -      8.2        -        -           -          -     -           -          -     -
golden/tf                               3.46 ms    266.16 ms      7.12 ms            -    2.1x    0.0x      7.5    11.8        -           -          -     -           -          -     -
golden/tran                             4.08 ms    259.25 ms      9.28 ms            -    2.3x    0.0x      7.6    12.3        -     1.01e-3    2.32e-4  PASS     1.01e-3    2.32e-4  PASS

hb/diode_clipper                        4.33 ms    271.17 ms         skip            -       -       -      8.5        -        -           -          -     -           -          -     -
hb/rc_single_tone                       4.79 ms    239.98 ms         skip            -       -       -      7.8        -        -           -          -     -           -          -     -
hb/tline_guard                         10.85 ms    261.29 ms         skip            -       -       -      8.4        -        -           -          -     -           -          -     -

medium/ladder_filter                  107.42 ms    337.87 ms      8.72 ms            -    0.1x    0.0x      7.9    12.1        -           -          -     -           -          -     -
medium/rc_ladder_50                    22.26 ms    277.40 ms     12.32 ms            -    0.6x    0.0x      8.3    12.1        -     5.93e-4    8.55e-5  PASS     5.93e-4    8.55e-5  PASS
medium/resistor_mesh                    6.07 ms    257.34 ms     10.07 ms            -    1.7x    0.0x      8.0    12.0        -     4.24e-9    4.24e-9  PASS     4.24e-9    4.24e-9  PASS

mosfet/cmos_inverter                   26.00 ms    281.65 ms      8.28 ms            -    0.3x    0.0x      8.2    12.1        -         inf        inf  FAIL         inf        inf  FAIL
mosfet/nand2                            4.87 ms    236.56 ms      9.19 ms            -    1.9x    0.0x      8.7    12.1        -    1.02e-13   1.02e-13  PASS     2.10e-9    2.10e-9  PASS
mosfet/nmos_cs                          6.58 ms    244.87 ms     11.13 ms            -    1.7x    0.0x      8.7    11.9        -     3.35e-4    5.62e-5  PASS     3.34e-4    5.47e-5  PASS

ngspice/behavioral_bsrc                 4.20 ms    258.44 ms      9.58 ms            -    2.3x    0.0x      7.8    12.0        -     6.05e-8    2.24e-8  PASS     6.05e-8    2.24e-8  PASS
ngspice/diffpair                           skip         skip      9.15 ms            -       -       -         -    12.2        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
ngspice/fourbitadder                       skip         skip     20.15 ms            -       -       -         -    13.3        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: preflight failed
ngspice/lowpass_filter                  4.17 ms    270.53 ms      6.47 ms            -    1.5x    0.0x      8.0    12.3        -           -          -     -           -          -     -
ngspice/mosamp                             skip         skip    445.50 ms            -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
ngspice/mosmem                             skip         skip     11.70 ms            -       -       -         -    12.1        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
ngspice/rc                              3.87 ms    249.08 ms      9.23 ms            -    2.4x    0.0x      7.6    12.3        -     2.13e-3    3.56e-4  PASS     2.13e-3    3.56e-4  PASS
ngspice/rca3040                       164.35 ms     1.025 s      11.20 ms            -    0.1x    0.0x      8.6    12.0        -           -          -     -           -          -     -
ngspice/res_array                      15.25 ms    252.43 ms     10.36 ms            -    0.7x    0.0x      8.0    12.0        -           -          -     -           -          -     -
ngspice/res_partition                   3.77 ms    244.05 ms      8.57 ms            -    2.3x    0.0x      7.7    11.8        -           -          -     -           -          -     -
ngspice/res_simple                      3.81 ms    231.84 ms      8.81 ms            -    2.3x    0.0x      7.4    12.0        -      0.00e0     0.00e0  PASS      0.00e0     0.00e0  PASS
ngspice/rtlinv                         14.37 ms    260.45 ms      8.48 ms            -    0.6x    0.0x      8.9    12.0        -      1.00e0    7.13e-1  FAIL      1.00e0    7.13e-1  FAIL
ngspice/schmitt                        20.06 ms    287.46 ms      8.34 ms            -    0.4x    0.0x      8.7    12.0        -     5.62e-1    4.79e-2  FAIL     5.62e-1    4.79e-2  FAIL
ngspice/sin_source                      5.66 ms    239.32 ms     10.44 ms            -    1.8x    0.0x      7.6    12.3        -     1.82e-4    1.19e-4  PASS     1.82e-4    1.19e-4  PASS
ngspice/tran_pulse                      5.72 ms    265.94 ms      9.80 ms            -    1.7x    0.0x      7.6    12.0        -     1.20e-3    8.09e-5  PASS     1.20e-3    8.09e-5  PASS

noise/amp_noise                         5.00 ms    237.07 ms      9.36 ms            -    1.9x    0.0x      8.8    12.3        -           -          -     -           -          -     -
noise/rc_noise                          4.92 ms    259.01 ms      9.50 ms            -    1.9x    0.0x      7.7    12.0        -           -          -     -           -          -     -
noise/resistor_noise                    3.86 ms    254.95 ms      7.85 ms            -    2.0x    0.0x      7.2    12.0        -           -          -     -           -          -     -

op/voltage_divider                      3.68 ms    229.27 ms      7.63 ms            -    2.1x    0.0x      7.5    11.8        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS

parser/hspice_suffix                    3.65 ms    213.56 ms      9.00 ms            -    2.5x    0.0x      7.7    12.2        -     1.90e-9    1.90e-9  PASS     1.90e-9    1.90e-9  PASS
parser/ngspice_syntax                   3.51 ms    249.78 ms      7.30 ms            -    2.1x    0.0x      7.7    12.2        -           -          -     -           -          -     -
parser/subckt_params                    5.57 ms    239.24 ms      7.54 ms            -    1.4x    0.0x      7.6    12.3        -     1.83e-7    7.43e-8  PASS     5.14e-7    2.91e-7  PASS

power/buck_open                        21.43 ms    279.09 ms     13.27 ms            -    0.6x    0.0x      8.7    12.3        -      5.18e0     2.18e0  FAIL      5.18e0     2.18e0  FAIL
power/rectifier                         7.94 ms    251.71 ms      7.41 ms            -    0.9x    0.0x      8.2    12.3        -     9.13e-4    1.67e-4  PASS     5.11e-4    1.67e-4  PASS
power/zener_reg                         3.93 ms    234.37 ms      9.16 ms            -    2.3x    0.0x      8.6    12.3        -     9.94e-5    2.16e-5  PASS     9.93e-5    2.18e-5  PASS

promote/dense_sweep                    20.45 ms    284.84 ms     14.00 ms            -    0.7x    0.0x      8.3    12.3        -     6.50e-7    1.61e-7  PASS     2.03e-7    1.57e-7  PASS
promote/long_tran                      71.38 ms    377.15 ms     43.17 ms            -    0.6x    0.1x      8.6    12.0        -     6.18e-6    2.45e-6  PASS     6.18e-6    2.45e-6  PASS
promote/mc_small                        3.79 ms    256.41 ms      7.21 ms            -    1.9x    0.0x      8.3    12.3        -     3.17e-7    3.17e-7  PASS     3.91e-7    3.91e-7  PASS

pss/diode_rect_driven                   3.72 ms    242.61 ms         skip            -       -       -      8.8        -        -           -          -     -           -          -     -
pss/rc_driven                           9.73 ms    268.11 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
pss/rlc_driven                          6.37 ms    256.11 ms         skip            -       -       -      8.1        -        -           -          -     -           -          -     -

pz/filt_bridge_t                        4.24 ms    230.24 ms      9.04 ms            -    2.1x    0.0x      8.0    12.3        -     1.00e-9    1.00e-9  PASS     1.00e-9    1.00e-9  PASS
pz/filt_multistage                      5.39 ms    232.57 ms      9.16 ms            -    1.7x    0.0x      8.0    12.3        -           -          -     -           -          -     -
pz/filt_rc                              3.85 ms    265.49 ms      8.78 ms            -    2.3x    0.0x      7.7    12.3        -           -          -     -           -          -     -
pz/pz2                                  4.74 ms    256.32 ms      9.35 ms            -    2.0x    0.0x      8.6    11.8        -           -          -     -           -          -     -
pz/pzt                                  4.32 ms    280.31 ms      7.77 ms            -    1.8x    0.0x      8.6    12.3        -           -          -     -           -          -     -
pz/rc_lowpass                           3.34 ms    267.33 ms         skip            -       -       -      7.7        -        -           -          -     -           -          -     -
pz/rlc_series                           3.07 ms    250.78 ms      7.56 ms            -    2.5x    0.0x      7.9    12.3        -           -          -     -           -          -     -
pz/simplepz                             3.42 ms    254.92 ms      8.59 ms            -    2.5x    0.0x      7.4    12.1        -           -          -     -           -          -     -
pz/two_pole                             3.68 ms    268.00 ms      9.15 ms            -    2.5x    0.0x      7.7    12.3        -           -          -     -           -          -     -

scaling/divider_chain                  14.79 ms    288.17 ms     12.19 ms            -    0.8x    0.0x      8.5    12.8        -     6.00e-5    6.00e-5  PASS     6.00e-5    6.00e-5  PASS
scaling/inverter_chain_1k                  skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: preflight failed
scaling/inverter_chain_256                 skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: preflight failed
scaling/inverter_chain_4k                  skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
scaling/parallel_inverters_100        289.35 ms    728.63 ms     44.91 ms            -    0.2x    0.1x     10.2    12.5        -     2.05e-2    2.15e-3  FAIL     2.05e-2    2.12e-3  FAIL
scaling/parallel_inverters_2000        5.351 s     10.421 s     990.66 ms            -    0.2x    0.1x     44.7    24.6        -     2.05e-2    2.15e-3  FAIL     2.05e-2    2.13e-3  FAIL
scaling/parallel_inverters_500         1.227 s      2.354 s     215.62 ms            -    0.2x    0.1x     17.7    15.3        -     2.05e-2    2.15e-3  FAIL     2.05e-2    2.12e-3  FAIL
scaling/rc_chain_500                   90.92 ms    447.13 ms     28.06 ms            -    0.3x    0.1x     12.3    13.0        -     6.05e-4    1.14e-4  PASS     6.05e-4    1.14e-4  PASS
scaling/rc_ladder_100k                     skip         skip     4.964 s             -       -       -         -   219.8        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
scaling/rc_ladder_10k                  3.499 s      3.724 s     444.50 ms            -    0.1x    0.1x     94.9    32.4        -     2.69e-3    3.10e-4  PASS     2.69e-3    3.10e-4  PASS
scaling/rc_ladder_1k                  168.39 ms    620.90 ms     38.81 ms            -    0.2x    0.1x     16.3    14.0        -     2.69e-3    3.10e-4  PASS     2.69e-3    3.10e-4  PASS
scaling/resistor_grid                  13.86 ms    225.52 ms     14.44 ms            -    1.0x    0.1x      8.7    13.5        -     3.28e-8    3.28e-8  PASS     3.28e-8    3.28e-8  PASS
scaling/resistor_grid_100x100         263.14 ms    487.04 ms     1.694 s             -    6.4x    3.5x     40.0    48.9        -     1.45e-5    1.45e-5  PASS     1.45e-5    1.45e-5  PASS
scaling/resistor_grid_32x32            16.31 ms    254.02 ms     28.66 ms            -    1.8x    0.1x     10.0    14.8        -     1.11e-6    1.11e-6  PASS     1.11e-6    1.11e-6  PASS

sens/bridge                             3.63 ms    214.35 ms      6.32 ms            -    1.7x    0.0x      7.2    12.0        -           -          -     -           -          -     -
sens/diffpair                              skip         skip      9.37 ms            -       -       -         -    12.5        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
sens/rc_lowpass                         3.00 ms    219.23 ms      7.70 ms            -    2.6x    0.0x      7.7    12.3        -           -          -     -           -          -     -
sens/voltage_divider                    3.51 ms    228.27 ms      7.17 ms            -    2.0x    0.0x      7.4    12.0        -           -          -     -           -          -     -

sp/lc_lowpass                           3.38 ms    226.22 ms      8.01 ms            -    2.4x    0.0x      7.9    12.3        -           -          -     -           -          -     -
sp/pi_attenuator                        3.02 ms    228.84 ms      7.47 ms            -    2.5x    0.0x      7.7    12.0        -           -          -     -           -          -     -
sp/rc_twoport                           3.36 ms    212.78 ms      7.69 ms            -    2.3x    0.0x      7.4    12.3        -           -          -     -           -          -     -

stb/bjt_shunt_fb                        3.87 ms    222.81 ms         skip            -       -       -      8.2        -        -           -          -     -           -          -     -
stb/vcvs_onepole                        3.72 ms    266.98 ms         skip            -       -       -      8.0        -        -           -          -     -           -          -     -
stb/vcvs_twopole                        3.29 ms    216.26 ms         skip            -       -       -      8.0        -        -           -          -     -           -          -     -

sweep/amp_bias_sweep                    9.14 ms    220.79 ms      7.66 ms            -    0.8x    0.0x      9.0    12.3        -     5.52e-5    1.37e-5  PASS     8.13e-5    7.26e-6  PASS
sweep/cmos_inv_sizing                      skip         skip      8.22 ms            -       -       -         -    12.1        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
sweep/nmos_wl_opt                          skip         skip     10.21 ms            -       -       -         -    12.4        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
sweep/opamp_wl_1000                        skip         skip    238.74 ms            -       -       -         -    24.6        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
sweep/opamp_wl_200                         skip         skip     27.38 ms            -       -       -         -    14.5        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: preflight failed
sweep/opamp_wl_5000                        skip         skip     4.220 s             -       -       -         -    76.8        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
sweep/pmos_wl_opt                          skip         skip     14.41 ms            -       -       -         -    12.4        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge

tf/diode_bias                           5.53 ms    232.64 ms     12.24 ms            -    2.2x    0.1x      8.3    12.2        -           -          -     -           -          -     -
tf/r_ladder                             5.90 ms    226.85 ms     13.23 ms            -    2.2x    0.1x      7.7    11.7        -           -          -     -           -          -     -
tf/voltage_divider                      5.69 ms    223.50 ms     11.05 ms            -    1.9x    0.0x      7.7    11.6        -           -          -     -           -          -     -

tline/cpl3_4_line                      17.13 ms    303.68 ms     27.41 ms            -    1.6x    0.1x      8.0    12.1        -     9.44e34    6.73e33  FAIL     9.43e34    6.73e33  FAIL
tline/cpl_ibm2                          6.45 ms    272.41 ms      7.13 ms            -    1.1x    0.0x      8.0    12.3        -      1.42e0    7.24e-1  FAIL      1.42e0    7.24e-1  FAIL
tline/delay_line                        6.22 ms    226.66 ms     14.72 ms            -    2.4x    0.1x      7.9    12.0        -      1.20e0    7.12e-1  FAIL      1.20e0    7.12e-1  FAIL
tline/ideal_tline                      14.27 ms    237.40 ms     15.80 ms            -    1.1x    0.1x      7.7    11.9        -     5.00e-1    2.14e-1  FAIL     5.00e-1    2.14e-1  FAIL
tline/ltra1_1_line                         skip         skip     24.29 ms            -       -       -         -    11.9        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
tline/ltra2_2_line                         skip         skip     23.73 ms            -       -       -         -    12.0        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
tline/terminated                       12.90 ms    255.14 ms     17.43 ms            -    1.4x    0.1x      7.9    11.8        -     9.36e-1    4.05e-1  FAIL     9.36e-1    4.05e-1  FAIL
tline/txl1_1_line                          skip         skip     13.77 ms            -       -       -         -    11.8        -           -          -     -           -          -     -
    zp-cpu: UnsupportedDevice
    zp-gpu: UnsupportedDevice
tline/txl2_3_line                          skip         skip     18.92 ms            -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: UnsupportedDevice
    zp-gpu: UnsupportedDevice

topology/current_cutset                    skip         skip     16.38 ms            -       -       -         -    11.7        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
topology/floating_node                  5.96 ms    282.16 ms     11.81 ms            -    2.0x    0.0x      7.7    11.9        -      1.00e0     1.00e0  FAIL      1.00e0     1.00e0  FAIL
topology/voltage_loop                      skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge

tran/fourbitadder                          skip         skip     18.41 ms            -       -       -         -    13.3        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: preflight failed
tran/rc_pulse                           7.77 ms    235.89 ms      7.80 ms            -    1.0x    0.0x      7.6    12.3        -     1.20e-3    8.09e-5  PASS     1.20e-3    8.09e-5  PASS

vacask/c6288                               skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
vacask/graetz                              skip         skip     2.717 s             -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
vacask/mul                             8.298 s      8.401 s      1.456 s             -    0.2x    0.2x     61.4    12.0        -      1.00e0    9.92e-1  FAIL      1.00e0    9.92e-1  FAIL
vacask/rc                                  skip         skip     1.508 s             -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
vacask/ring                                skip         skip    139.07 ms            -       -       -         -    12.6        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge

verilog/inverter                           skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: UnsupportedDevice
    zp-gpu: UnsupportedDevice

verilogA/diode_clamp                       skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: UnsupportedDevice
    zp-gpu: UnsupportedDevice
verilogA/res_divider                       skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: UnsupportedDevice
    zp-gpu: UnsupportedDevice

ratio = ngspice / zpicey (higher = zpicey faster).
accuracy: per-variable RMS/max relative error against ngspice.
