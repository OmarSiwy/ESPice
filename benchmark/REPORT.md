note: xyce not found — comparison disabled

fixture                                  zp-cpu       zp-gpu      ngspice         xyce  cpu/ng  gpu/ng     zp-MB    ng-MB    xy-MB     cpu-max    cpu-rms   cpu     gpu-max    gpu-rms   gpu
---------------------------------- ------------ ------------ ------------ ------------ ------- -------  -------- -------- --------  ---------- ---------- -----  ---------- ---------- -----
ac/rc_lowpass                           3.71 ms    219.15 ms     12.06 ms            -    3.2x    0.1x      7.6    12.3        -           -          -     -           -          -     -

adversarial/extreme_values              4.98 ms    261.66 ms     12.30 ms            -    2.5x    0.0x      7.6    12.2        -           -          -     -           -          -     -
adversarial/near_singular               6.04 ms    224.18 ms     11.10 ms            -    1.8x    0.0x      7.6    12.3        -     1.67e-1    1.67e-1  FAIL     1.67e-1    1.67e-1  FAIL
adversarial/tiny_resistor               5.82 ms    227.22 ms     13.55 ms            -    2.3x    0.1x      7.4    12.1        -     9.99e-7    9.99e-7  PASS     9.99e-7    9.99e-7  PASS

analog/current_mirror                   6.14 ms    237.45 ms     12.19 ms            -    2.0x    0.1x      8.6    12.2        -     2.63e-7    2.63e-7  PASS     2.63e-7    2.63e-7  PASS
analog/diff_pair                       11.52 ms    276.88 ms     14.47 ms            -    1.3x    0.1x      8.7    12.3        -     1.29e-7    1.29e-7  PASS     1.29e-7    1.29e-7  PASS
analog/opamp_inverting                  3.66 ms    240.78 ms      9.58 ms            -    2.6x    0.0x      7.9    11.8        -     8.77e-8    8.77e-8  PASS     8.77e-8    8.77e-8  PASS

basic/rc_transient                      6.40 ms    269.90 ms     17.57 ms            -    2.7x    0.1x      7.1    12.3        -    9.49e-10   9.49e-10  PASS    9.49e-10   9.49e-10  PASS
basic/voltage_divider                   8.26 ms    299.69 ms      9.36 ms            -    1.1x    0.0x      7.6    11.6        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS

bjt/cascode                             7.03 ms    262.86 ms      7.20 ms            -    1.0x    0.0x      8.9    12.3        -     8.82e-6    8.82e-6  PASS     8.80e-6    8.80e-6  PASS
bjt/common_emitter                      5.43 ms    243.05 ms     14.51 ms            -    2.7x    0.1x      8.5    12.3        -           -          -     -           -          -     -
bjt/diff_amp                           10.56 ms    275.40 ms      7.58 ms            -    0.7x    0.0x      8.6    12.2        -     1.10e-6    6.45e-7  PASS     1.10e-6    6.45e-7  PASS

bypass/burst_clock                     18.19 ms    240.05 ms     18.72 ms            -    1.0x    0.1x      8.3    11.8        -     3.50e-4    1.04e-5  PASS     3.50e-4    1.04e-5  PASS
bypass/gated_branch                    75.32 ms    418.70 ms     21.27 ms            -    0.3x    0.1x      8.8    12.3        -     1.05e-2    1.05e-2  FAIL     1.05e-2    1.05e-2  FAIL
bypass/idle_ladder                     68.50 ms    323.17 ms     18.23 ms            -    0.3x    0.1x      8.8    12.3        -     1.29e-3    9.99e-5  PASS     1.29e-3    9.98e-5  PASS

convergence/diode_bridge                5.31 ms    256.33 ms     14.29 ms            -    2.7x    0.1x      8.3    12.2        -     8.32e-1    8.32e-1  FAIL     8.32e-1    8.32e-1  FAIL
convergence/high_gain_fb                5.80 ms    234.90 ms     13.45 ms            -    2.3x    0.1x      7.9    11.9        -    1.11e-15   1.11e-15  PASS    8.88e-16   8.88e-16  PASS
convergence/schmitt                     5.01 ms    246.13 ms     15.88 ms            -    3.2x    0.1x      7.7    12.0        -     5.00e-9    5.00e-9  PASS     5.00e-9    5.00e-9  PASS

dc_sweep/nested_sweep                   8.06 ms    257.55 ms     20.89 ms            -    2.6x    0.1x      8.1    12.1        -           -          -     -           -          -     -
dc_sweep/param_sweep                    3.92 ms    220.47 ms     10.48 ms            -    2.7x    0.0x      8.3    11.9        -     3.28e-5    6.25e-6  PASS     3.28e-5    6.25e-6  PASS
dc_sweep/vin_sweep                      5.49 ms    217.19 ms     13.31 ms            -    2.4x    0.1x      7.3    12.1        -     1.38e-8    8.07e-9  PASS     1.38e-8    8.07e-9  PASS

devices/b3soidd                         5.83 ms    244.34 ms         skip            -       -       -      8.8        -        -           -          -     -           -          -     -
devices/b3soidd_output                 14.13 ms    266.96 ms         skip            -       -       -      8.3        -        -           -          -     -           -          -     -
devices/b3soifd                         8.23 ms    258.26 ms         skip            -       -       -      9.1        -        -           -          -     -           -          -     -
devices/b3soifd_output                 12.25 ms    247.88 ms         skip            -       -       -      8.6        -        -           -          -     -           -          -     -
devices/b3soipd                         8.41 ms    235.85 ms     14.84 ms            -    1.8x    0.1x      9.2    12.5        -     7.48e-3    7.48e-3  FAIL     7.48e-3    7.48e-3  FAIL
devices/b3soipd_output                 22.13 ms    242.58 ms     39.04 ms            -    1.8x    0.2x      8.7    12.0        -           -          -     -           -          -     -
devices/b4soi                           5.21 ms    258.24 ms     19.98 ms            -    3.8x    0.1x      9.2    12.5        -     3.19e-1    3.19e-1  FAIL     3.19e-1    3.19e-1  FAIL
devices/b4soi_output                   14.28 ms    253.43 ms     25.44 ms            -    1.8x    0.1x      8.7    12.3        -           -          -     -           -          -     -
devices/bjt_npn                         3.31 ms    238.21 ms      8.96 ms            -    2.7x    0.0x      8.7    11.8        -     7.98e-8    7.98e-8  PASS     7.98e-8    7.98e-8  PASS
devices/bjt_npn_early                  12.46 ms    230.41 ms     12.04 ms            -    1.0x    0.1x      7.8    12.0        -           -          -     -           -          -     -
devices/bjt_npn_gummel                 12.31 ms    237.20 ms     10.36 ms            -    0.8x    0.0x      7.8    11.8        -     2.86e-8    1.39e-8  PASS     2.86e-8    1.39e-8  PASS
devices/bjt_npn_high_injection          8.49 ms    269.28 ms      9.64 ms            -    1.1x    0.0x      7.8    12.1        -           -          -     -           -          -     -
devices/bjt_npn_output                  6.04 ms    222.51 ms     14.47 ms            -    2.4x    0.1x      7.8    12.1        -           -          -     -           -          -     -
devices/bjt_npn_saturation              8.01 ms    273.82 ms     11.02 ms            -    1.4x    0.0x      7.8    11.9        -           -          -     -           -          -     -
devices/bjt_npn_temp                    6.01 ms    227.83 ms     14.70 ms            -    2.4x    0.1x      7.5    11.7        -           -          -     -           -          -     -
devices/bjt_pnp                         7.13 ms    246.11 ms     11.59 ms            -    1.6x    0.0x      8.7    11.9        -     7.59e-8    7.59e-8  PASS     7.59e-8    7.59e-8  PASS
devices/bjt_pnp_output                  7.36 ms    242.75 ms     16.56 ms            -    2.3x    0.1x      7.8    12.1        -           -          -     -           -          -     -
devices/bsim1                           5.18 ms    263.72 ms     14.09 ms            -    2.7x    0.1x      8.2    12.1        -           -          -     -           -          -     -
devices/bsim2                           7.75 ms    273.86 ms     17.17 ms            -    2.2x    0.1x      8.3    12.1        -           -          -     -           -          -     -
devices/bsim2_ngspice                  34.74 ms    324.62 ms      7.99 ms            -    0.2x    0.0x      8.5    11.6        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/bsim3                           3.12 ms    278.91 ms      9.88 ms            -    3.2x    0.0x      9.0    12.4        -     4.97e-6    4.97e-6  PASS     4.97e-6    4.97e-6  PASS
devices/bsim3_body_effect              10.20 ms    283.24 ms     37.92 ms            -    3.7x    0.1x      8.5    11.8        -           -          -     -           -          -     -
devices/bsim3_output                    6.26 ms    242.04 ms     33.92 ms            -    5.4x    0.1x      8.2    12.1        -           -          -     -           -          -     -
devices/bsim3_pmos                      6.79 ms    260.28 ms     33.52 ms            -    4.9x    0.1x      8.5    12.1        -           -          -     -           -          -     -
devices/bsim3_temp                     10.85 ms    247.15 ms     35.10 ms            -    3.2x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/bsim3_transfer                  8.40 ms    276.46 ms     13.95 ms            -    1.7x    0.1x      8.2    12.1        -     3.18e-8    2.38e-8  PASS     3.18e-8    2.38e-8  PASS
devices/bsim4                           4.01 ms    261.21 ms      8.74 ms            -    2.2x    0.0x      9.6    12.4        -     1.35e-4    1.35e-4  PASS     1.34e-4    1.34e-4  PASS
devices/bsim4_output                   12.39 ms    236.92 ms     21.45 ms            -    1.7x    0.1x      8.9    12.4        -           -          -     -           -          -     -
devices/bsim4_pmos                     11.77 ms    232.49 ms     21.39 ms            -    1.8x    0.1x      9.1    12.2        -           -          -     -           -          -     -
devices/bsim4_transfer                 14.76 ms    234.67 ms     10.97 ms            -    0.7x    0.0x      8.9    12.4        -     5.20e-8    1.53e-8  PASS     5.20e-8    1.53e-8  PASS
devices/bsource                         3.33 ms    211.96 ms      7.56 ms            -    2.3x    0.0x      7.6    12.1        -     5.82e-8    2.12e-8  PASS     5.82e-8    2.12e-8  PASS
devices/capacitor                       5.34 ms    246.12 ms      9.78 ms            -    1.8x    0.0x      7.3    12.3        -     1.00e-9    1.00e-9  PASS     1.00e-9    1.00e-9  PASS
devices/capacitor_ac                    3.85 ms    213.47 ms      7.29 ms            -    1.9x    0.0x      7.6    12.3        -           -          -     -           -          -     -
devices/cccs                            3.12 ms    257.24 ms      8.26 ms            -    2.7x    0.0x      8.0    11.8        -    5.00e-10   5.00e-10  PASS    5.00e-10   5.00e-10  PASS
devices/ccvs                            3.53 ms    202.80 ms      8.71 ms            -    2.5x    0.0x      8.3    12.1        -     4.75e-8    4.75e-8  PASS     4.75e-8    4.75e-8  PASS
devices/coupled_tlines                 17.87 ms    242.62 ms     10.34 ms            -    0.6x    0.0x      7.9    12.4        -     6.45e-1    2.19e-1  FAIL     6.45e-1    2.19e-1  FAIL
devices/cswitch                         4.12 ms    225.27 ms      8.90 ms            -    2.2x    0.0x      7.7    11.9        -    4.84e-11   4.84e-11  PASS    4.84e-11   4.84e-11  PASS
devices/diode                           3.52 ms    209.66 ms      7.86 ms            -    2.2x    0.0x      8.3    12.3        -     1.34e-7    1.34e-7  PASS     1.34e-7    1.34e-7  PASS
devices/diode_breakdown                 5.92 ms    224.85 ms      9.10 ms            -    1.5x    0.0x      8.1    12.1        -     1.98e-5    1.03e-6  PASS     1.98e-5    1.03e-6  PASS
devices/diode_capacitance               3.70 ms    255.59 ms      8.02 ms            -    2.2x    0.0x      7.8    11.8        -           -          -     -           -          -     -
devices/diode_high_injection            6.30 ms    245.60 ms      6.97 ms            -    1.1x    0.0x      7.6    11.8        -     2.86e-8    1.30e-8  PASS     2.86e-8    1.30e-8  PASS
devices/diode_iv_sweep                 10.12 ms    238.43 ms      9.45 ms            -    0.9x    0.0x      7.6    12.1        -     3.81e-8    1.18e-8  PASS     3.81e-8    1.18e-8  PASS
devices/diode_recombination             5.70 ms    269.11 ms      8.70 ms            -    1.5x    0.0x      7.8    12.1        -     2.96e-8    1.17e-8  PASS     2.96e-8    1.17e-8  PASS
devices/diode_temp                      5.03 ms    231.94 ms     10.33 ms            -    2.1x    0.0x      7.4    12.1        -           -          -     -           -          -     -
devices/hfet1                           3.74 ms    224.00 ms      8.69 ms            -    2.3x    0.0x      8.2    12.1        -    5.00e-10   5.00e-10  PASS    5.00e-10   5.00e-10  PASS
devices/hfet1_output                    4.49 ms    221.40 ms     10.06 ms            -    2.2x    0.0x      7.6    12.1        -           -          -     -           -          -     -
devices/hfet2                           3.42 ms    223.50 ms      8.15 ms            -    2.4x    0.0x      8.7    12.1        -    7.60e-10   7.60e-10  PASS    7.60e-10   7.60e-10  PASS
devices/hfet2_output                    7.08 ms    235.28 ms     10.07 ms            -    1.4x    0.0x      8.2    11.7        -           -          -     -           -          -     -
devices/hfet_id_vgs                     4.05 ms    226.41 ms      8.73 ms            -    2.2x    0.0x      7.8    12.1        -     2.86e-8    1.29e-8  PASS     2.86e-8    1.29e-8  PASS
devices/hfet_inverter                  18.10 ms    275.23 ms     13.71 ms            -    0.8x    0.0x      7.5    11.8        -      1.28e0     1.28e0  FAIL      1.28e0     1.28e0  FAIL
devices/hicum2                          4.94 ms    219.54 ms      6.72 ms            -    1.4x    0.0x      9.2    12.1        -     4.74e-7    4.74e-7  PASS     4.74e-7    4.74e-7  PASS
devices/hicum2_gummel                  12.01 ms    262.82 ms      9.68 ms            -    0.8x    0.0x      8.7    12.4        -           -          -     -           -          -     -
devices/hicum2_output                  17.15 ms    283.72 ms     16.59 ms            -    1.0x    0.1x      8.7    12.1        -           -          -     -           -          -     -
devices/hisim2                          4.43 ms    232.58 ms     26.02 ms            -    5.9x    0.1x      8.4    12.4        -           -          -     -           -          -     -
devices/hisimhv                         5.60 ms    223.91 ms         skip            -       -       -      8.4        -        -           -          -     -           -          -     -
devices/inductor                        5.72 ms    220.93 ms      9.29 ms            -    1.6x    0.0x      7.6    12.3        -    1.01e-13   1.01e-13  PASS    1.01e-13   1.01e-13  PASS
devices/inductor_ac                     4.17 ms    226.13 ms      9.83 ms            -    2.4x    0.0x      7.5    12.3        -           -          -     -           -          -     -
devices/isource                         3.11 ms    212.67 ms      9.82 ms            -    3.2x    0.0x      7.9    12.2        -    2.50e-10   2.50e-10  PASS    2.50e-10   2.50e-10  PASS
devices/jfet                            3.32 ms    244.86 ms      7.80 ms            -    2.4x    0.0x      8.6    11.6        -     2.18e-9    2.18e-9  PASS     2.18e-9    2.18e-9  PASS
devices/jfet2                           6.48 ms    218.23 ms     12.80 ms            -    2.0x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/jfet_output                     5.28 ms    228.10 ms     12.20 ms            -    2.3x    0.1x      7.8    12.1        -           -          -     -           -          -     -
devices/jfet_transfer                   6.35 ms    257.97 ms      9.50 ms            -    1.5x    0.0x      7.8    12.0        -     3.27e-8    1.19e-8  PASS     3.27e-8    1.19e-8  PASS
devices/jfet_vds_vgs                    3.49 ms    275.42 ms      8.77 ms            -    2.5x    0.0x      8.1    12.0        -           -          -     -           -          -     -
devices/kinduc                          7.24 ms    218.07 ms     10.70 ms            -    1.5x    0.0x      8.0    11.7        -     2.13e-4    1.28e-4  PASS     2.13e-4    1.28e-4  PASS
devices/lossy_tline                    20.58 ms    273.29 ms     15.68 ms            -    0.8x    0.1x      8.0    12.1        -     6.22e-4    3.95e-4  PASS     6.22e-4    3.95e-4  PASS
devices/mesa                            3.48 ms    247.18 ms      9.10 ms            -    2.6x    0.0x      8.7    12.1        -     2.07e-8    2.07e-8  PASS     2.07e-8    2.07e-8  PASS
devices/mesa_inverter                  15.09 ms    278.57 ms      9.48 ms            -    0.6x    0.0x      9.4    11.6        -      1.00e0    6.57e-1  FAIL      1.00e0    6.57e-1  FAIL
devices/mesa_oscillator                78.75 ms    366.99 ms     24.83 ms            -    0.3x    0.1x      9.4    12.1        -     5.66e-1    4.22e-1  FAIL     5.66e-1    4.22e-1  FAIL
devices/mesa_output                    13.97 ms    240.96 ms     11.23 ms            -    0.8x    0.0x      8.2    11.7        -           -          -     -           -          -     -
devices/mesfet                          3.52 ms    229.00 ms      9.38 ms            -    2.7x    0.0x      8.2    12.1        -     3.32e-9    3.32e-9  PASS     3.32e-9    3.32e-9  PASS
devices/mesfet_output                   4.71 ms    239.80 ms     10.88 ms            -    2.3x    0.0x      7.6    12.1        -           -          -     -           -          -     -
devices/mesfet_subthreshold             3.54 ms    250.91 ms      8.55 ms            -    2.4x    0.0x      7.6    12.1        -     3.18e-8    1.46e-8  PASS     3.18e-8    1.46e-8  PASS
devices/mesfet_transfer                 5.16 ms    217.67 ms      7.54 ms            -    1.5x    0.0x      7.6    12.1        -     2.29e-8    9.35e-9  PASS     2.29e-8    9.35e-9  PASS
devices/mos1_body_effect               11.11 ms    212.66 ms     12.50 ms            -    1.1x    0.1x      8.4    11.7        -           -          -     -           -          -     -
devices/mos1_large_signal                  skip    241.18 ms     10.77 ms            -       -    0.0x         -    12.1        -           -          -     -     8.58e-4    7.48e-5  PASS
    zp-cpu: TimestepTooSmall
devices/mos1_output                     5.99 ms    241.14 ms     13.28 ms            -    2.2x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/mos1_pmos                       5.99 ms    215.33 ms     10.48 ms            -    1.7x    0.0x      8.0    11.8        -           -          -     -           -          -     -
devices/mos1_subthreshold              10.31 ms    229.39 ms      9.98 ms            -    1.0x    0.0x      8.1    11.8        -     3.94e-8    1.50e-8  PASS     3.94e-8    1.50e-8  PASS
devices/mos1_temp                       8.59 ms    217.21 ms     13.18 ms            -    1.5x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/mos1_transfer                   9.69 ms    233.47 ms      9.87 ms            -    1.0x    0.0x      8.4    11.8        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos2                            6.22 ms    223.76 ms     12.17 ms            -    2.0x    0.1x      8.1    11.8        -           -          -     -           -          -     -
devices/mos2_transfer                   8.19 ms    232.09 ms      7.28 ms            -    0.9x    0.0x      8.1    12.1        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos3                            5.91 ms    215.29 ms     13.44 ms            -    2.3x    0.1x      8.2    11.8        -           -          -     -           -          -     -
devices/mos3_transfer                  11.15 ms    244.98 ms      8.90 ms            -    0.8x    0.0x      8.2    12.1        -     4.58e-8    1.54e-8  PASS     4.58e-8    1.54e-8  PASS
devices/mos6                            5.96 ms    208.72 ms     12.64 ms            -    2.1x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/mos6_inverter                 330.28 ms     1.275 s      18.86 ms            -    0.1x    0.0x      8.7    12.6        -     1.09e-1    1.67e-2  FAIL     1.09e-1    1.67e-2  FAIL
devices/mos6_simpleinv                 14.29 ms    254.88 ms      9.63 ms            -    0.7x    0.0x      8.1    12.1        -     1.13e-2    8.43e-4  FAIL     1.13e-2    8.43e-4  FAIL
devices/mos9                            5.73 ms    233.11 ms     12.97 ms            -    2.3x    0.1x      8.1    12.1        -           -          -     -           -          -     -
devices/mosfet_l1                       3.30 ms    222.43 ms      7.15 ms            -    2.2x    0.0x      8.9    12.1        -     1.86e-8    1.86e-8  PASS     1.86e-8    1.86e-8  PASS
devices/resistor                        3.09 ms    217.20 ms      7.16 ms            -    2.3x    0.0x      7.7    12.1        -    5.33e-16   5.33e-16  PASS    5.33e-16   5.33e-16  PASS
devices/resistor_sweep                  4.13 ms    245.98 ms      8.39 ms            -    2.0x    0.0x      7.3    12.1        -     1.91e-8    7.54e-9  PASS     1.91e-8    7.54e-9  PASS
devices/resistor_temp                   3.69 ms    202.66 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
devices/switch                          5.11 ms    245.98 ms      9.59 ms            -    1.9x    0.0x      8.1    12.1        -    4.84e-11   4.84e-11  PASS    4.84e-11   4.84e-11  PASS
devices/switch_hysteresis               6.72 ms    233.48 ms      9.86 ms            -    1.5x    0.0x      8.1    12.1        -    4.84e-11   4.84e-11  PASS    4.84e-11   4.84e-11  PASS
devices/tline                           8.21 ms    228.98 ms      8.32 ms            -    1.0x    0.0x      8.2    12.1        -     1.47e-6    9.84e-8  PASS     1.47e-6    9.84e-8  PASS
devices/urc                            13.04 ms    265.60 ms     12.06 ms            -    0.9x    0.0x      8.5    12.3        -     4.66e-9   5.69e-10  PASS     4.66e-9   5.69e-10  PASS
devices/urc_ac                         11.51 ms    220.20 ms      9.33 ms            -    0.8x    0.0x      8.4    12.3        -           -          -     -           -          -     -
devices/vbic                            9.39 ms    312.70 ms      7.74 ms            -    0.8x    0.0x      9.7    12.4        -     1.87e-4    1.87e-4  PASS     1.87e-4    1.87e-4  PASS
devices/vbic_ce_amp                    25.67 ms    291.00 ms     10.73 ms            -    0.4x    0.0x      9.8    12.4        -           -          -     -           -          -     -
devices/vbic_diffamp                       skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge
devices/vbic_forced_output             13.73 ms    308.15 ms     14.76 ms            -    1.1x    0.0x      8.8    11.9        -           -          -     -           -          -     -
devices/vbic_forward_gummel            51.15 ms         skip         skip            -       -       -      8.8        -        -           -          -     -           -          -     -
    zp-gpu: OpDidNotConverge
devices/vbic_gummel                    78.53 ms    252.55 ms      8.47 ms            -    0.1x    0.0x      8.9    12.4        -     2.86e-8    1.39e-8  PASS     2.86e-8    1.39e-8  PASS
devices/vbic_noise_scale               10.32 ms    246.34 ms      6.82 ms            -    0.7x    0.0x      9.9    12.4        -           -          -     -           -          -     -
devices/vbic_output                    18.86 ms    281.25 ms     13.64 ms            -    0.7x    0.0x      8.9    11.9        -           -          -     -           -          -     -
devices/vbic_temp                      28.16 ms    256.05 ms      7.35 ms            -    0.3x    0.0x      8.8    12.4        -     4.77e-8    1.73e-8  PASS     4.77e-8    1.73e-8  PASS
devices/vccs                            3.35 ms    275.07 ms      8.25 ms            -    2.5x    0.0x      8.0    11.8        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS
devices/vcvs                            3.15 ms    230.23 ms      7.29 ms            -    2.3x    0.0x      7.7    12.1        -    6.67e-10   6.67e-10  PASS    6.67e-10   6.67e-10  PASS
devices/vdmos                           3.21 ms    229.30 ms         skip            -       -       -      8.9        -        -           -          -     -           -          -     -
devices/vdmos_output                    6.38 ms    234.69 ms         skip            -       -       -      8.4        -        -           -          -     -           -          -     -
devices/vsource                         4.61 ms    266.05 ms      8.44 ms            -    1.8x    0.0x      7.4    11.9        -    1.43e-15   7.58e-16  PASS    1.95e-15   7.63e-16  PASS

digital/buffer_rc                       4.96 ms    235.14 ms      9.42 ms            -    1.9x    0.0x      6.9    12.3        -     3.06e-4    2.84e-5  PASS     3.06e-4    2.84e-5  PASS
digital/clamp                           5.51 ms    236.53 ms      6.95 ms            -    1.3x    0.0x      8.3    12.2        -     1.88e-2    1.56e-3  FAIL     1.88e-2    1.56e-3  FAIL
digital/rc_filter_chain                 4.89 ms    227.71 ms      7.31 ms            -    1.5x    0.0x      7.3    12.0        -     1.16e-3    9.25e-5  PASS     1.16e-3    9.25e-5  PASS

disto/bjt_ce                            3.50 ms    262.66 ms      7.19 ms            -    2.1x    0.0x      8.6    12.3        -           -          -     -           -          -     -
disto/diode_clipper                     3.12 ms    221.23 ms      7.03 ms            -    2.3x    0.0x      8.3    11.9        -           -          -     -           -          -     -
disto/mos_cs                            3.17 ms    244.19 ms      8.80 ms            -    2.8x    0.0x      8.9    12.1        -           -          -     -           -          -     -

ensemble/corner_pathological            3.45 ms    261.57 ms      9.00 ms            -    2.6x    0.0x      8.3    11.9        -     2.58e-7    2.58e-7  PASS     2.58e-7    2.58e-7  PASS
ensemble/opamp_mc                      31.60 ms    269.26 ms     11.67 ms            -    0.4x    0.0x      8.6    12.1        -     4.61e-6    2.73e-7  PASS     4.61e-6    2.73e-7  PASS
ensemble/pvt_corners                  105.47 ms    384.75 ms     16.20 ms            -    0.2x    0.0x      8.8    11.8        -     8.01e-1    2.30e-2  FAIL     8.01e-1    2.30e-2  FAIL
ensemble/sweep_lanes                    4.26 ms    262.35 ms      8.77 ms            -    2.1x    0.0x      8.3    12.3        -     4.66e-5    7.78e-6  PASS     4.66e-5    7.78e-6  PASS

fourier/clipped_sine                   16.76 ms    339.93 ms      8.83 ms            -    0.5x    0.0x      8.3    12.3        -     2.59e-4    6.16e-5  PASS     2.59e-4    6.16e-5  PASS
fourier/sine_1k                         3.86 ms    296.70 ms      9.64 ms            -    2.5x    0.0x      7.4    12.1        -     1.69e-4    1.19e-4  PASS     1.69e-4    1.19e-4  PASS
fourier/square_harmonics                8.73 ms    320.13 ms     13.68 ms            -    1.6x    0.0x      7.1    12.1        -     2.70e-4    1.80e-5  PASS     2.70e-4    1.80e-5  PASS

golden/ac                               2.59 ms    314.15 ms      8.57 ms            -    3.3x    0.0x      7.6    12.3        -           -          -     -           -          -     -
golden/dc                               3.05 ms    283.14 ms      8.45 ms            -    2.8x    0.0x      7.3    12.1        -     1.38e-8    8.17e-9  PASS     1.38e-8    8.17e-9  PASS
golden/disto                            3.34 ms    261.18 ms      6.89 ms            -    2.1x    0.0x      8.3    12.3        -           -          -     -           -          -     -
golden/four                             5.96 ms    291.85 ms      9.40 ms            -    1.6x    0.0x      8.3    12.1        -     1.85e-3    3.36e-4  PASS     1.85e-3    3.36e-4  PASS
golden/hb                               4.73 ms    313.93 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
golden/noise                            3.25 ms    285.57 ms      8.94 ms            -    2.8x    0.0x      7.4    12.1        -           -          -     -           -          -     -
golden/op                               3.12 ms    252.75 ms      8.68 ms            -    2.8x    0.0x      7.1    12.1        -     1.38e-8    1.38e-8  PASS     1.38e-8    1.38e-8  PASS
golden/pss                             10.28 ms    274.82 ms         skip            -       -       -      7.3        -        -           -          -     -           -          -     -
golden/pz                               3.65 ms    255.14 ms      9.61 ms            -    2.6x    0.0x      7.6    12.1        -           -          -     -           -          -     -
golden/sens                             3.54 ms    259.86 ms      8.51 ms            -    2.4x    0.0x      7.4    11.9        -           -          -     -           -          -     -
golden/sp                               3.31 ms    251.15 ms      8.36 ms            -    2.5x    0.0x      7.6    11.8        -           -          -     -           -          -     -
golden/stb                              3.59 ms    221.90 ms         skip            -       -       -      7.9        -        -           -          -     -           -          -     -
golden/tf                               4.39 ms    213.19 ms      8.06 ms            -    1.8x    0.0x      7.6    12.1        -           -          -     -           -          -     -
golden/tran                             3.99 ms    252.67 ms      7.15 ms            -    1.8x    0.0x      7.3    12.1        -     1.01e-3    2.32e-4  PASS     1.01e-3    2.32e-4  PASS

hb/diode_clipper                        3.97 ms    228.18 ms         skip            -       -       -      8.3        -        -           -          -     -           -          -     -
hb/rc_single_tone                       4.22 ms    216.52 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
hb/tline_guard                         12.90 ms    235.56 ms         skip            -       -       -      8.2        -        -           -          -     -           -          -     -

medium/ladder_filter                    6.80 ms    245.81 ms      9.01 ms            -    1.3x    0.0x      7.7    12.3        -           -          -     -           -          -     -
medium/rc_ladder_50                    19.11 ms    263.88 ms     10.97 ms            -    0.6x    0.0x      7.9    12.3        -     5.93e-4    8.55e-5  PASS     5.93e-4    8.55e-5  PASS
medium/resistor_mesh                    5.91 ms    233.75 ms      8.39 ms            -    1.4x    0.0x      7.8    12.3        -     4.24e-9    4.24e-9  PASS     4.24e-9    4.24e-9  PASS

mosfet/cmos_inverter                    6.58 ms    214.82 ms      8.62 ms            -    1.3x    0.0x      8.1    12.1        -     6.45e-4    8.37e-5  PASS     6.45e-4    8.37e-5  PASS
mosfet/nand2                            4.52 ms    207.93 ms      6.68 ms            -    1.5x    0.0x      8.6    12.0        -    1.74e-16   1.74e-16  PASS    1.74e-16   1.74e-16  PASS
mosfet/nmos_cs                          5.84 ms    210.65 ms      9.11 ms            -    1.6x    0.0x      8.6    12.0        -     3.35e-4    5.50e-5  PASS     3.35e-4    5.50e-5  PASS

ngspice/behavioral_bsrc                 3.59 ms    226.30 ms      6.65 ms            -    1.9x    0.0x      7.9    12.1        -     6.05e-8    2.24e-8  PASS     6.05e-8    2.24e-8  PASS
ngspice/diffpair                        5.07 ms    218.99 ms      9.25 ms            -    1.8x    0.0x      8.8    12.4        -           -          -     -           -          -     -
ngspice/fourbitadder                   3.875 s      8.538 s      30.31 ms            -    0.0x    0.0x     10.9    13.3        -     6.18e-4    2.00e-4  PASS     6.18e-4    2.00e-4  PASS
ngspice/lowpass_filter                  3.53 ms    230.11 ms      7.73 ms            -    2.2x    0.0x      7.6    12.3        -           -          -     -           -          -     -
ngspice/mosamp                             skip         skip    450.09 ms            -       -       -         -    12.3        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: TimestepTooSmall
ngspice/mosmem                             skip    317.32 ms      7.46 ms            -       -    0.0x         -    11.9        -           -          -     -     1.30e-3    1.92e-4  PASS
    zp-cpu: TimestepTooSmall
ngspice/rc                              3.78 ms    228.43 ms      8.56 ms            -    2.3x    0.0x      7.4    12.3        -     2.13e-3    3.56e-4  PASS     2.13e-3    3.56e-4  PASS
ngspice/rca3040                        52.37 ms    311.00 ms      8.92 ms            -    0.2x    0.0x      8.6    12.3        -           -          -     -           -          -     -
ngspice/res_array                      12.76 ms    218.59 ms      8.13 ms            -    0.6x    0.0x      7.6    12.1        -           -          -     -           -          -     -
ngspice/res_partition                   3.52 ms    221.70 ms      6.99 ms            -    2.0x    0.0x      7.6    12.1        -           -          -     -           -          -     -
ngspice/res_simple                      3.07 ms    240.21 ms      8.56 ms            -    2.8x    0.0x      7.4    12.0        -      0.00e0     0.00e0  PASS      0.00e0     0.00e0  PASS
ngspice/rtlinv                         18.63 ms    248.29 ms      9.37 ms            -    0.5x    0.0x      8.6    12.3        -      1.00e0    7.13e-1  FAIL      1.00e0    7.13e-1  FAIL
ngspice/schmitt                        22.09 ms    244.00 ms      9.13 ms            -    0.4x    0.0x      8.6    12.1        -     5.62e-1    4.79e-2  FAIL     5.62e-1    4.79e-2  FAIL
ngspice/sin_source                      4.49 ms    218.19 ms      7.83 ms            -    1.7x    0.0x      7.3    12.1        -     1.82e-4    1.19e-4  PASS     1.82e-4    1.19e-4  PASS
ngspice/tran_pulse                      5.19 ms    211.56 ms      8.42 ms            -    1.6x    0.0x      7.3    12.1        -     1.20e-3    8.09e-5  PASS     1.20e-3    8.09e-5  PASS

noise/amp_noise                         3.99 ms    229.15 ms      8.75 ms            -    2.2x    0.0x      8.0    12.3        -           -          -     -           -          -     -
noise/rc_noise                          4.66 ms    224.60 ms      7.89 ms            -    1.7x    0.0x      7.6    11.8        -           -          -     -           -          -     -
noise/resistor_noise                    3.68 ms    217.08 ms      8.83 ms            -    2.4x    0.0x      7.4    11.5        -           -          -     -           -          -     -

op/voltage_divider                      3.17 ms    199.86 ms      8.17 ms            -    2.6x    0.0x      7.6    12.0        -     2.50e-9    2.50e-9  PASS     2.50e-9    2.50e-9  PASS

parser/hspice_suffix                    3.84 ms    212.61 ms      8.48 ms            -    2.2x    0.0x      7.3    12.3        -     1.90e-9    1.90e-9  PASS     1.90e-9    1.90e-9  PASS
parser/ngspice_syntax                   3.50 ms    224.67 ms      8.43 ms            -    2.4x    0.0x      7.3    12.3        -           -          -     -           -          -     -
parser/subckt_params                    5.41 ms    220.95 ms      9.72 ms            -    1.8x    0.0x      7.3    12.1        -     1.83e-7    7.43e-8  PASS     5.14e-7    2.91e-7  PASS

power/buck_open                        20.78 ms    252.52 ms     14.61 ms            -    0.7x    0.1x      8.2    12.1        -     1.61e-7    2.16e-8  PASS     1.16e-6    3.87e-7  PASS
power/rectifier                         7.85 ms    238.11 ms     10.30 ms            -    1.3x    0.0x      8.4    11.9        -     5.11e-4    1.67e-4  PASS     5.11e-4    1.67e-4  PASS
power/zener_reg                         3.63 ms    206.53 ms      7.84 ms            -    2.2x    0.0x      8.3    12.3        -     9.93e-5    2.16e-5  PASS     9.93e-5    2.18e-5  PASS

promote/dense_sweep                    17.60 ms    263.27 ms     10.76 ms            -    0.6x    0.0x      8.0    12.0        -     2.04e-7    1.57e-7  PASS     2.04e-7    1.57e-7  PASS
promote/long_tran                      72.69 ms    353.83 ms     46.07 ms            -    0.6x    0.1x      8.3    12.3        -     6.18e-6    2.45e-6  PASS     6.18e-6    2.45e-6  PASS
promote/mc_small                        3.46 ms    238.36 ms      6.76 ms            -    2.0x    0.0x      8.0    12.0        -     3.06e-7    3.06e-7  PASS     3.06e-7    3.06e-7  PASS

pss/diode_rect_driven                  49.74 ms    348.47 ms         skip            -       -       -      8.4        -        -           -          -     -           -          -     -
pss/rc_driven                          10.48 ms    241.30 ms         skip            -       -       -      7.3        -        -           -          -     -           -          -     -
pss/rlc_driven                          6.28 ms    225.90 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -

pz/filt_bridge_t                        3.99 ms    292.77 ms      8.14 ms            -    2.0x    0.0x      7.6    12.3        -     1.00e-9    1.00e-9  PASS     1.00e-9    1.00e-9  PASS
pz/filt_multistage                      5.29 ms    239.15 ms      8.52 ms            -    1.6x    0.0x      8.0    12.3        -           -          -     -           -          -     -
pz/filt_rc                              3.38 ms    213.52 ms      7.48 ms            -    2.2x    0.0x      7.6    12.3        -           -          -     -           -          -     -
pz/pz2                                  4.16 ms    236.95 ms      8.56 ms            -    2.1x    0.0x      8.5    12.3        -           -          -     -           -          -     -
pz/pzt                                  3.70 ms    254.83 ms      8.71 ms            -    2.4x    0.0x      8.2    12.3        -           -          -     -           -          -     -
pz/rc_lowpass                           3.57 ms    243.20 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
pz/rlc_series                           4.11 ms    217.76 ms      7.85 ms            -    1.9x    0.0x      7.4    12.3        -           -          -     -           -          -     -
pz/simplepz                             3.02 ms    222.91 ms      7.37 ms            -    2.4x    0.0x      7.1    12.0        -           -          -     -           -          -     -
pz/two_pole                             3.32 ms    240.23 ms      8.53 ms            -    2.6x    0.0x      7.6    12.1        -           -          -     -           -          -     -

scaling/divider_chain                   8.31 ms    224.82 ms     10.20 ms            -    1.2x    0.0x      8.3    12.6        -     6.00e-5    6.00e-5  PASS     6.00e-5    6.00e-5  PASS
scaling/inverter_chain_1k                  skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: preflight failed
scaling/inverter_chain_256                 skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
scaling/inverter_chain_4k                  skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: preflight failed
scaling/parallel_inverters_100        311.08 ms    582.53 ms     48.95 ms            -    0.2x    0.1x     10.2    12.5        -     5.32e-2    5.73e-3  FAIL     2.05e-2    2.14e-3  FAIL
scaling/parallel_inverters_2000        5.990 s      7.275 s     884.89 ms            -    0.1x    0.1x     45.0    24.3        -     5.32e-2    5.73e-3  FAIL     2.05e-2    2.14e-3  FAIL
scaling/parallel_inverters_500         1.431 s      1.825 s     185.20 ms            -    0.1x    0.1x     17.2    15.1        -     5.32e-2    5.73e-3  FAIL     2.05e-2    2.14e-3  FAIL
scaling/rc_chain_500                   91.06 ms    425.14 ms     26.35 ms            -    0.3x    0.1x     12.3    13.2        -     6.05e-4    1.14e-4  PASS     6.05e-4    1.14e-4  PASS
scaling/rc_ladder_100k                15.684 s          skip     5.094 s             -    0.3x       -    866.5   220.1        -     2.69e-3    3.10e-4  PASS           -          -     -
    zp-gpu: preflight failed
scaling/rc_ladder_10k                  1.468 s      3.573 s     387.02 ms            -    0.3x    0.1x     93.8    32.5        -     2.69e-3    3.10e-4  PASS     2.69e-3    3.10e-4  PASS
scaling/rc_ladder_1k                  160.22 ms    599.52 ms     45.82 ms            -    0.3x    0.1x     15.8    14.1        -     2.69e-3    3.10e-4  PASS     2.69e-3    3.10e-4  PASS
scaling/resistor_grid                  14.36 ms    246.34 ms     17.60 ms            -    1.2x    0.1x      8.8    13.4        -     3.28e-8    3.28e-8  PASS     3.28e-8    3.28e-8  PASS
scaling/resistor_grid_100x100         191.55 ms    456.22 ms     1.718 s             -    9.0x    3.8x     37.8    49.1        -     1.45e-5    1.45e-5  PASS     1.45e-5    1.45e-5  PASS
scaling/resistor_grid_32x32            21.65 ms    268.74 ms     31.41 ms            -    1.5x    0.1x      9.8    15.1        -     1.11e-6    1.11e-6  PASS     1.11e-6    1.11e-6  PASS

sens/bridge                             3.22 ms    234.88 ms      8.74 ms            -    2.7x    0.0x      7.4    12.1        -           -          -     -           -          -     -
sens/diffpair                           4.66 ms    207.39 ms      7.97 ms            -    1.7x    0.0x      8.8    12.6        -           -          -     -           -          -     -
sens/rc_lowpass                         3.46 ms    221.27 ms      7.51 ms            -    2.2x    0.0x      7.6    12.3        -           -          -     -           -          -     -
sens/voltage_divider                    3.30 ms    223.96 ms      7.75 ms            -    2.3x    0.0x      7.4    12.1        -           -          -     -           -          -     -

sp/lc_lowpass                           3.06 ms    243.67 ms      8.59 ms            -    2.8x    0.0x      7.9    11.9        -           -          -     -           -          -     -
sp/pi_attenuator                        3.86 ms    254.28 ms      8.36 ms            -    2.2x    0.0x      7.6    12.1        -           -          -     -           -          -     -
sp/rc_twoport                           3.33 ms    228.55 ms      8.86 ms            -    2.7x    0.0x      7.6    11.8        -           -          -     -           -          -     -

stb/bjt_shunt_fb                        3.36 ms    223.23 ms         skip            -       -       -      8.4        -        -           -          -     -           -          -     -
stb/vcvs_onepole                        5.01 ms    206.18 ms         skip            -       -       -      8.0        -        -           -          -     -           -          -     -
stb/vcvs_twopole                        3.22 ms    217.35 ms         skip            -       -       -      8.0        -        -           -          -     -           -          -     -

sweep/amp_bias_sweep                    7.03 ms    255.39 ms      8.72 ms            -    1.2x    0.0x      8.7    12.1        -     2.08e-5    1.67e-6  PASS     2.08e-5    1.67e-6  PASS
sweep/cmos_inv_sizing                  12.05 ms    272.21 ms      9.22 ms            -    0.8x    0.0x      8.3    11.8        -     5.08e-4    2.75e-5  PASS     5.08e-4    2.75e-5  PASS
sweep/nmos_wl_opt                      10.28 ms    237.03 ms      9.79 ms            -    1.0x    0.0x      8.9    12.4        -     5.20e-8    2.17e-8  PASS     5.20e-8    2.17e-8  PASS
sweep/opamp_wl_1000                   512.45 ms     1.108 s     245.21 ms            -    0.5x    0.2x     34.0    24.8        -           -          -     -           -          -     -
sweep/opamp_wl_200                    113.85 ms    391.20 ms     26.62 ms            -    0.2x    0.1x     13.2    14.6        -           -          -     -           -          -     -
sweep/opamp_wl_5000                    2.546 s      4.889 s      4.132 s             -    1.6x    0.8x    135.3    76.6        -           -          -     -           -          -     -
sweep/pmos_wl_opt                       8.65 ms    245.96 ms     11.82 ms            -    1.4x    0.0x      9.1    12.4        -     5.20e-8    2.17e-8  PASS     5.20e-8    2.17e-8  PASS

tf/diode_bias                           3.34 ms    285.07 ms      8.61 ms            -    2.6x    0.0x      8.3    12.3        -           -          -     -           -          -     -
tf/r_ladder                             3.46 ms    269.50 ms      8.44 ms            -    2.4x    0.0x      7.6    12.1        -           -          -     -           -          -     -
tf/voltage_divider                      2.99 ms    252.01 ms      8.37 ms            -    2.8x    0.0x      7.6    12.1        -           -          -     -           -          -     -

tline/cpl3_4_line                      22.98 ms    331.77 ms     23.50 ms            -    1.0x    0.1x      8.3    12.6        -     7.52e34    5.36e33  FAIL     7.52e34    5.36e33  FAIL
tline/cpl_ibm2                          7.52 ms    217.83 ms      8.27 ms            -    1.1x    0.0x      7.9    12.1        -      1.42e0    7.24e-1  FAIL      1.42e0    7.24e-1  FAIL
tline/delay_line                        8.36 ms    234.74 ms     10.22 ms            -    1.2x    0.0x      8.1    11.9        -     5.00e-2    2.00e-3  FAIL     5.00e-2    2.00e-3  FAIL
tline/ideal_tline                       9.13 ms    235.66 ms     11.87 ms            -    1.3x    0.1x      7.9    11.7        -     1.41e-5    4.94e-7  PASS     1.41e-5    4.94e-7  PASS
tline/ltra1_1_line                         skip     1.517 s      16.07 ms            -       -    0.0x         -    12.1        -           -          -     -     7.35e-3    1.65e-3  FAIL
    zp-cpu: TimestepTooSmall
tline/ltra2_2_line                         skip     2.971 s      17.69 ms            -       -    0.0x         -    12.2        -           -          -     -     7.07e-3    2.52e-3  FAIL
    zp-cpu: TimestepTooSmall
tline/terminated                       10.80 ms    231.62 ms     10.59 ms            -    1.0x    0.0x      7.9    11.8        -     1.00e-4    5.13e-6  PASS     1.00e-4    5.13e-6  PASS
tline/txl1_1_line                          skip    238.66 ms      8.96 ms            -       -    0.0x         -    11.9        -           -          -     -     2.04e-1    4.91e-2  FAIL
    zp-cpu: TimestepTooSmall
tline/txl2_3_line                          skip    287.48 ms     10.35 ms            -       -    0.0x         -    12.2        -           -          -     -     3.26e-1    1.12e-1  FAIL
    zp-cpu: TimestepTooSmall

topology/current_cutset                 3.56 ms    214.43 ms      8.25 ms            -    2.3x    0.0x      7.4    12.1        -      1.00e9     1.00e9  FAIL      1.00e9     1.00e9  FAIL
topology/floating_node                  3.37 ms    229.46 ms      8.77 ms            -    2.6x    0.0x      7.6    12.3        -      1.00e0     1.00e0  FAIL      1.00e0     1.00e0  FAIL
topology/voltage_loop                   3.48 ms    277.88 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -

tran/fourbitadder                      4.045 s      8.204 s      21.62 ms            -    0.0x    0.0x     11.1    13.3        -     6.18e-4    2.00e-4  PASS     6.18e-4    2.00e-4  PASS
tran/rc_pulse                           5.54 ms    247.69 ms      9.64 ms            -    1.7x    0.0x      7.1    12.3        -     1.20e-3    8.09e-5  PASS     1.20e-3    8.09e-5  PASS

vacask/c6288                               skip         skip         skip            -       -       -         -        -        -           -          -     -           -          -     -
    zp-cpu: preflight failed
    zp-gpu: preflight failed
vacask/graetz                              skip         skip     2.702 s             -       -       -         -    12.1        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
vacask/mul                             8.038 s      7.571 s      1.456 s             -    0.2x    0.2x     61.4    12.4        -      1.00e0    9.92e-1  FAIL      1.00e0    9.92e-1  FAIL
vacask/rc                                  skip         skip     1.498 s             -       -       -         -    12.1        -           -          -     -           -          -     -
    zp-cpu: TimestepTooSmall
    zp-gpu: TimestepTooSmall
vacask/ring                                skip         skip    144.46 ms            -       -       -         -    12.1        -           -          -     -           -          -     -
    zp-cpu: OpDidNotConverge
    zp-gpu: OpDidNotConverge

verilog/inverter                       56.31 ms    309.23 ms         skip            -       -       -     12.8        -        -           -          -     -           -          -     -

verilogA/diode_clamp                    5.09 ms    234.86 ms         skip            -       -       -      7.6        -        -           -          -     -           -          -     -
verilogA/res_divider                    6.15 ms    280.67 ms         skip            -       -       -      8.1        -        -           -          -     -           -          -     -

ratio = ngspice / zpicey (higher = zpicey faster).
accuracy: per-variable RMS/max relative error against ngspice.
