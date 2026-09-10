* CMOS Inverter Chain: 256 stages — stress test
* Every stage carries a 10 fF load: the level-1 card declares no TOX/CGSO/CJ,
* so a bare chain has capacitance-free internal nodes and no simulator can
* time-step it (ngspice 44.2 aborts "Timestep too small" at mn103 too).
.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
.model pch PMOS(level=1 VTO=-0.7 KP=50u GAMMA=0.57 LAMBDA=0.05 PHI=0.65)
Vdd vdd 0 DC 1.8
Vin in 0 PULSE(0 1.8 0 0.1n 0.1n 5n 10n)
Mn1 s1 in 0 0 nch W=0.5u L=0.18u
Mp1 s1 in vdd vdd pch W=1u L=0.18u
Cl1 s1 0 10f
Mn2 s2 s1 0 0 nch W=0.5u L=0.18u
Mp2 s2 s1 vdd vdd pch W=1u L=0.18u
Cl2 s2 0 10f
Mn3 s3 s2 0 0 nch W=0.5u L=0.18u
Mp3 s3 s2 vdd vdd pch W=1u L=0.18u
Cl3 s3 0 10f
Mn4 s4 s3 0 0 nch W=0.5u L=0.18u
Mp4 s4 s3 vdd vdd pch W=1u L=0.18u
Cl4 s4 0 10f
Mn5 s5 s4 0 0 nch W=0.5u L=0.18u
Mp5 s5 s4 vdd vdd pch W=1u L=0.18u
Cl5 s5 0 10f
Mn6 s6 s5 0 0 nch W=0.5u L=0.18u
Mp6 s6 s5 vdd vdd pch W=1u L=0.18u
Cl6 s6 0 10f
Mn7 s7 s6 0 0 nch W=0.5u L=0.18u
Mp7 s7 s6 vdd vdd pch W=1u L=0.18u
Cl7 s7 0 10f
Mn8 s8 s7 0 0 nch W=0.5u L=0.18u
Mp8 s8 s7 vdd vdd pch W=1u L=0.18u
Cl8 s8 0 10f
Mn9 s9 s8 0 0 nch W=0.5u L=0.18u
Mp9 s9 s8 vdd vdd pch W=1u L=0.18u
Cl9 s9 0 10f
Mn10 s10 s9 0 0 nch W=0.5u L=0.18u
Mp10 s10 s9 vdd vdd pch W=1u L=0.18u
Cl10 s10 0 10f
Mn11 s11 s10 0 0 nch W=0.5u L=0.18u
Mp11 s11 s10 vdd vdd pch W=1u L=0.18u
Cl11 s11 0 10f
Mn12 s12 s11 0 0 nch W=0.5u L=0.18u
Mp12 s12 s11 vdd vdd pch W=1u L=0.18u
Cl12 s12 0 10f
Mn13 s13 s12 0 0 nch W=0.5u L=0.18u
Mp13 s13 s12 vdd vdd pch W=1u L=0.18u
Cl13 s13 0 10f
Mn14 s14 s13 0 0 nch W=0.5u L=0.18u
Mp14 s14 s13 vdd vdd pch W=1u L=0.18u
Cl14 s14 0 10f
Mn15 s15 s14 0 0 nch W=0.5u L=0.18u
Mp15 s15 s14 vdd vdd pch W=1u L=0.18u
Cl15 s15 0 10f
Mn16 s16 s15 0 0 nch W=0.5u L=0.18u
Mp16 s16 s15 vdd vdd pch W=1u L=0.18u
Cl16 s16 0 10f
Mn17 s17 s16 0 0 nch W=0.5u L=0.18u
Mp17 s17 s16 vdd vdd pch W=1u L=0.18u
Cl17 s17 0 10f
Mn18 s18 s17 0 0 nch W=0.5u L=0.18u
Mp18 s18 s17 vdd vdd pch W=1u L=0.18u
Cl18 s18 0 10f
Mn19 s19 s18 0 0 nch W=0.5u L=0.18u
Mp19 s19 s18 vdd vdd pch W=1u L=0.18u
Cl19 s19 0 10f
Mn20 s20 s19 0 0 nch W=0.5u L=0.18u
Mp20 s20 s19 vdd vdd pch W=1u L=0.18u
Cl20 s20 0 10f
Mn21 s21 s20 0 0 nch W=0.5u L=0.18u
Mp21 s21 s20 vdd vdd pch W=1u L=0.18u
Cl21 s21 0 10f
Mn22 s22 s21 0 0 nch W=0.5u L=0.18u
Mp22 s22 s21 vdd vdd pch W=1u L=0.18u
Cl22 s22 0 10f
Mn23 s23 s22 0 0 nch W=0.5u L=0.18u
Mp23 s23 s22 vdd vdd pch W=1u L=0.18u
Cl23 s23 0 10f
Mn24 s24 s23 0 0 nch W=0.5u L=0.18u
Mp24 s24 s23 vdd vdd pch W=1u L=0.18u
Cl24 s24 0 10f
Mn25 s25 s24 0 0 nch W=0.5u L=0.18u
Mp25 s25 s24 vdd vdd pch W=1u L=0.18u
Cl25 s25 0 10f
Mn26 s26 s25 0 0 nch W=0.5u L=0.18u
Mp26 s26 s25 vdd vdd pch W=1u L=0.18u
Cl26 s26 0 10f
Mn27 s27 s26 0 0 nch W=0.5u L=0.18u
Mp27 s27 s26 vdd vdd pch W=1u L=0.18u
Cl27 s27 0 10f
Mn28 s28 s27 0 0 nch W=0.5u L=0.18u
Mp28 s28 s27 vdd vdd pch W=1u L=0.18u
Cl28 s28 0 10f
Mn29 s29 s28 0 0 nch W=0.5u L=0.18u
Mp29 s29 s28 vdd vdd pch W=1u L=0.18u
Cl29 s29 0 10f
Mn30 s30 s29 0 0 nch W=0.5u L=0.18u
Mp30 s30 s29 vdd vdd pch W=1u L=0.18u
Cl30 s30 0 10f
Mn31 s31 s30 0 0 nch W=0.5u L=0.18u
Mp31 s31 s30 vdd vdd pch W=1u L=0.18u
Cl31 s31 0 10f
Mn32 s32 s31 0 0 nch W=0.5u L=0.18u
Mp32 s32 s31 vdd vdd pch W=1u L=0.18u
Cl32 s32 0 10f
Mn33 s33 s32 0 0 nch W=0.5u L=0.18u
Mp33 s33 s32 vdd vdd pch W=1u L=0.18u
Cl33 s33 0 10f
Mn34 s34 s33 0 0 nch W=0.5u L=0.18u
Mp34 s34 s33 vdd vdd pch W=1u L=0.18u
Cl34 s34 0 10f
Mn35 s35 s34 0 0 nch W=0.5u L=0.18u
Mp35 s35 s34 vdd vdd pch W=1u L=0.18u
Cl35 s35 0 10f
Mn36 s36 s35 0 0 nch W=0.5u L=0.18u
Mp36 s36 s35 vdd vdd pch W=1u L=0.18u
Cl36 s36 0 10f
Mn37 s37 s36 0 0 nch W=0.5u L=0.18u
Mp37 s37 s36 vdd vdd pch W=1u L=0.18u
Cl37 s37 0 10f
Mn38 s38 s37 0 0 nch W=0.5u L=0.18u
Mp38 s38 s37 vdd vdd pch W=1u L=0.18u
Cl38 s38 0 10f
Mn39 s39 s38 0 0 nch W=0.5u L=0.18u
Mp39 s39 s38 vdd vdd pch W=1u L=0.18u
Cl39 s39 0 10f
Mn40 s40 s39 0 0 nch W=0.5u L=0.18u
Mp40 s40 s39 vdd vdd pch W=1u L=0.18u
Cl40 s40 0 10f
Mn41 s41 s40 0 0 nch W=0.5u L=0.18u
Mp41 s41 s40 vdd vdd pch W=1u L=0.18u
Cl41 s41 0 10f
Mn42 s42 s41 0 0 nch W=0.5u L=0.18u
Mp42 s42 s41 vdd vdd pch W=1u L=0.18u
Cl42 s42 0 10f
Mn43 s43 s42 0 0 nch W=0.5u L=0.18u
Mp43 s43 s42 vdd vdd pch W=1u L=0.18u
Cl43 s43 0 10f
Mn44 s44 s43 0 0 nch W=0.5u L=0.18u
Mp44 s44 s43 vdd vdd pch W=1u L=0.18u
Cl44 s44 0 10f
Mn45 s45 s44 0 0 nch W=0.5u L=0.18u
Mp45 s45 s44 vdd vdd pch W=1u L=0.18u
Cl45 s45 0 10f
Mn46 s46 s45 0 0 nch W=0.5u L=0.18u
Mp46 s46 s45 vdd vdd pch W=1u L=0.18u
Cl46 s46 0 10f
Mn47 s47 s46 0 0 nch W=0.5u L=0.18u
Mp47 s47 s46 vdd vdd pch W=1u L=0.18u
Cl47 s47 0 10f
Mn48 s48 s47 0 0 nch W=0.5u L=0.18u
Mp48 s48 s47 vdd vdd pch W=1u L=0.18u
Cl48 s48 0 10f
Mn49 s49 s48 0 0 nch W=0.5u L=0.18u
Mp49 s49 s48 vdd vdd pch W=1u L=0.18u
Cl49 s49 0 10f
Mn50 s50 s49 0 0 nch W=0.5u L=0.18u
Mp50 s50 s49 vdd vdd pch W=1u L=0.18u
Cl50 s50 0 10f
Mn51 s51 s50 0 0 nch W=0.5u L=0.18u
Mp51 s51 s50 vdd vdd pch W=1u L=0.18u
Cl51 s51 0 10f
Mn52 s52 s51 0 0 nch W=0.5u L=0.18u
Mp52 s52 s51 vdd vdd pch W=1u L=0.18u
Cl52 s52 0 10f
Mn53 s53 s52 0 0 nch W=0.5u L=0.18u
Mp53 s53 s52 vdd vdd pch W=1u L=0.18u
Cl53 s53 0 10f
Mn54 s54 s53 0 0 nch W=0.5u L=0.18u
Mp54 s54 s53 vdd vdd pch W=1u L=0.18u
Cl54 s54 0 10f
Mn55 s55 s54 0 0 nch W=0.5u L=0.18u
Mp55 s55 s54 vdd vdd pch W=1u L=0.18u
Cl55 s55 0 10f
Mn56 s56 s55 0 0 nch W=0.5u L=0.18u
Mp56 s56 s55 vdd vdd pch W=1u L=0.18u
Cl56 s56 0 10f
Mn57 s57 s56 0 0 nch W=0.5u L=0.18u
Mp57 s57 s56 vdd vdd pch W=1u L=0.18u
Cl57 s57 0 10f
Mn58 s58 s57 0 0 nch W=0.5u L=0.18u
Mp58 s58 s57 vdd vdd pch W=1u L=0.18u
Cl58 s58 0 10f
Mn59 s59 s58 0 0 nch W=0.5u L=0.18u
Mp59 s59 s58 vdd vdd pch W=1u L=0.18u
Cl59 s59 0 10f
Mn60 s60 s59 0 0 nch W=0.5u L=0.18u
Mp60 s60 s59 vdd vdd pch W=1u L=0.18u
Cl60 s60 0 10f
Mn61 s61 s60 0 0 nch W=0.5u L=0.18u
Mp61 s61 s60 vdd vdd pch W=1u L=0.18u
Cl61 s61 0 10f
Mn62 s62 s61 0 0 nch W=0.5u L=0.18u
Mp62 s62 s61 vdd vdd pch W=1u L=0.18u
Cl62 s62 0 10f
Mn63 s63 s62 0 0 nch W=0.5u L=0.18u
Mp63 s63 s62 vdd vdd pch W=1u L=0.18u
Cl63 s63 0 10f
Mn64 s64 s63 0 0 nch W=0.5u L=0.18u
Mp64 s64 s63 vdd vdd pch W=1u L=0.18u
Cl64 s64 0 10f
Mn65 s65 s64 0 0 nch W=0.5u L=0.18u
Mp65 s65 s64 vdd vdd pch W=1u L=0.18u
Cl65 s65 0 10f
Mn66 s66 s65 0 0 nch W=0.5u L=0.18u
Mp66 s66 s65 vdd vdd pch W=1u L=0.18u
Cl66 s66 0 10f
Mn67 s67 s66 0 0 nch W=0.5u L=0.18u
Mp67 s67 s66 vdd vdd pch W=1u L=0.18u
Cl67 s67 0 10f
Mn68 s68 s67 0 0 nch W=0.5u L=0.18u
Mp68 s68 s67 vdd vdd pch W=1u L=0.18u
Cl68 s68 0 10f
Mn69 s69 s68 0 0 nch W=0.5u L=0.18u
Mp69 s69 s68 vdd vdd pch W=1u L=0.18u
Cl69 s69 0 10f
Mn70 s70 s69 0 0 nch W=0.5u L=0.18u
Mp70 s70 s69 vdd vdd pch W=1u L=0.18u
Cl70 s70 0 10f
Mn71 s71 s70 0 0 nch W=0.5u L=0.18u
Mp71 s71 s70 vdd vdd pch W=1u L=0.18u
Cl71 s71 0 10f
Mn72 s72 s71 0 0 nch W=0.5u L=0.18u
Mp72 s72 s71 vdd vdd pch W=1u L=0.18u
Cl72 s72 0 10f
Mn73 s73 s72 0 0 nch W=0.5u L=0.18u
Mp73 s73 s72 vdd vdd pch W=1u L=0.18u
Cl73 s73 0 10f
Mn74 s74 s73 0 0 nch W=0.5u L=0.18u
Mp74 s74 s73 vdd vdd pch W=1u L=0.18u
Cl74 s74 0 10f
Mn75 s75 s74 0 0 nch W=0.5u L=0.18u
Mp75 s75 s74 vdd vdd pch W=1u L=0.18u
Cl75 s75 0 10f
Mn76 s76 s75 0 0 nch W=0.5u L=0.18u
Mp76 s76 s75 vdd vdd pch W=1u L=0.18u
Cl76 s76 0 10f
Mn77 s77 s76 0 0 nch W=0.5u L=0.18u
Mp77 s77 s76 vdd vdd pch W=1u L=0.18u
Cl77 s77 0 10f
Mn78 s78 s77 0 0 nch W=0.5u L=0.18u
Mp78 s78 s77 vdd vdd pch W=1u L=0.18u
Cl78 s78 0 10f
Mn79 s79 s78 0 0 nch W=0.5u L=0.18u
Mp79 s79 s78 vdd vdd pch W=1u L=0.18u
Cl79 s79 0 10f
Mn80 s80 s79 0 0 nch W=0.5u L=0.18u
Mp80 s80 s79 vdd vdd pch W=1u L=0.18u
Cl80 s80 0 10f
Mn81 s81 s80 0 0 nch W=0.5u L=0.18u
Mp81 s81 s80 vdd vdd pch W=1u L=0.18u
Cl81 s81 0 10f
Mn82 s82 s81 0 0 nch W=0.5u L=0.18u
Mp82 s82 s81 vdd vdd pch W=1u L=0.18u
Cl82 s82 0 10f
Mn83 s83 s82 0 0 nch W=0.5u L=0.18u
Mp83 s83 s82 vdd vdd pch W=1u L=0.18u
Cl83 s83 0 10f
Mn84 s84 s83 0 0 nch W=0.5u L=0.18u
Mp84 s84 s83 vdd vdd pch W=1u L=0.18u
Cl84 s84 0 10f
Mn85 s85 s84 0 0 nch W=0.5u L=0.18u
Mp85 s85 s84 vdd vdd pch W=1u L=0.18u
Cl85 s85 0 10f
Mn86 s86 s85 0 0 nch W=0.5u L=0.18u
Mp86 s86 s85 vdd vdd pch W=1u L=0.18u
Cl86 s86 0 10f
Mn87 s87 s86 0 0 nch W=0.5u L=0.18u
Mp87 s87 s86 vdd vdd pch W=1u L=0.18u
Cl87 s87 0 10f
Mn88 s88 s87 0 0 nch W=0.5u L=0.18u
Mp88 s88 s87 vdd vdd pch W=1u L=0.18u
Cl88 s88 0 10f
Mn89 s89 s88 0 0 nch W=0.5u L=0.18u
Mp89 s89 s88 vdd vdd pch W=1u L=0.18u
Cl89 s89 0 10f
Mn90 s90 s89 0 0 nch W=0.5u L=0.18u
Mp90 s90 s89 vdd vdd pch W=1u L=0.18u
Cl90 s90 0 10f
Mn91 s91 s90 0 0 nch W=0.5u L=0.18u
Mp91 s91 s90 vdd vdd pch W=1u L=0.18u
Cl91 s91 0 10f
Mn92 s92 s91 0 0 nch W=0.5u L=0.18u
Mp92 s92 s91 vdd vdd pch W=1u L=0.18u
Cl92 s92 0 10f
Mn93 s93 s92 0 0 nch W=0.5u L=0.18u
Mp93 s93 s92 vdd vdd pch W=1u L=0.18u
Cl93 s93 0 10f
Mn94 s94 s93 0 0 nch W=0.5u L=0.18u
Mp94 s94 s93 vdd vdd pch W=1u L=0.18u
Cl94 s94 0 10f
Mn95 s95 s94 0 0 nch W=0.5u L=0.18u
Mp95 s95 s94 vdd vdd pch W=1u L=0.18u
Cl95 s95 0 10f
Mn96 s96 s95 0 0 nch W=0.5u L=0.18u
Mp96 s96 s95 vdd vdd pch W=1u L=0.18u
Cl96 s96 0 10f
Mn97 s97 s96 0 0 nch W=0.5u L=0.18u
Mp97 s97 s96 vdd vdd pch W=1u L=0.18u
Cl97 s97 0 10f
Mn98 s98 s97 0 0 nch W=0.5u L=0.18u
Mp98 s98 s97 vdd vdd pch W=1u L=0.18u
Cl98 s98 0 10f
Mn99 s99 s98 0 0 nch W=0.5u L=0.18u
Mp99 s99 s98 vdd vdd pch W=1u L=0.18u
Cl99 s99 0 10f
Mn100 s100 s99 0 0 nch W=0.5u L=0.18u
Mp100 s100 s99 vdd vdd pch W=1u L=0.18u
Cl100 s100 0 10f
Mn101 s101 s100 0 0 nch W=0.5u L=0.18u
Mp101 s101 s100 vdd vdd pch W=1u L=0.18u
Cl101 s101 0 10f
Mn102 s102 s101 0 0 nch W=0.5u L=0.18u
Mp102 s102 s101 vdd vdd pch W=1u L=0.18u
Cl102 s102 0 10f
Mn103 s103 s102 0 0 nch W=0.5u L=0.18u
Mp103 s103 s102 vdd vdd pch W=1u L=0.18u
Cl103 s103 0 10f
Mn104 s104 s103 0 0 nch W=0.5u L=0.18u
Mp104 s104 s103 vdd vdd pch W=1u L=0.18u
Cl104 s104 0 10f
Mn105 s105 s104 0 0 nch W=0.5u L=0.18u
Mp105 s105 s104 vdd vdd pch W=1u L=0.18u
Cl105 s105 0 10f
Mn106 s106 s105 0 0 nch W=0.5u L=0.18u
Mp106 s106 s105 vdd vdd pch W=1u L=0.18u
Cl106 s106 0 10f
Mn107 s107 s106 0 0 nch W=0.5u L=0.18u
Mp107 s107 s106 vdd vdd pch W=1u L=0.18u
Cl107 s107 0 10f
Mn108 s108 s107 0 0 nch W=0.5u L=0.18u
Mp108 s108 s107 vdd vdd pch W=1u L=0.18u
Cl108 s108 0 10f
Mn109 s109 s108 0 0 nch W=0.5u L=0.18u
Mp109 s109 s108 vdd vdd pch W=1u L=0.18u
Cl109 s109 0 10f
Mn110 s110 s109 0 0 nch W=0.5u L=0.18u
Mp110 s110 s109 vdd vdd pch W=1u L=0.18u
Cl110 s110 0 10f
Mn111 s111 s110 0 0 nch W=0.5u L=0.18u
Mp111 s111 s110 vdd vdd pch W=1u L=0.18u
Cl111 s111 0 10f
Mn112 s112 s111 0 0 nch W=0.5u L=0.18u
Mp112 s112 s111 vdd vdd pch W=1u L=0.18u
Cl112 s112 0 10f
Mn113 s113 s112 0 0 nch W=0.5u L=0.18u
Mp113 s113 s112 vdd vdd pch W=1u L=0.18u
Cl113 s113 0 10f
Mn114 s114 s113 0 0 nch W=0.5u L=0.18u
Mp114 s114 s113 vdd vdd pch W=1u L=0.18u
Cl114 s114 0 10f
Mn115 s115 s114 0 0 nch W=0.5u L=0.18u
Mp115 s115 s114 vdd vdd pch W=1u L=0.18u
Cl115 s115 0 10f
Mn116 s116 s115 0 0 nch W=0.5u L=0.18u
Mp116 s116 s115 vdd vdd pch W=1u L=0.18u
Cl116 s116 0 10f
Mn117 s117 s116 0 0 nch W=0.5u L=0.18u
Mp117 s117 s116 vdd vdd pch W=1u L=0.18u
Cl117 s117 0 10f
Mn118 s118 s117 0 0 nch W=0.5u L=0.18u
Mp118 s118 s117 vdd vdd pch W=1u L=0.18u
Cl118 s118 0 10f
Mn119 s119 s118 0 0 nch W=0.5u L=0.18u
Mp119 s119 s118 vdd vdd pch W=1u L=0.18u
Cl119 s119 0 10f
Mn120 s120 s119 0 0 nch W=0.5u L=0.18u
Mp120 s120 s119 vdd vdd pch W=1u L=0.18u
Cl120 s120 0 10f
Mn121 s121 s120 0 0 nch W=0.5u L=0.18u
Mp121 s121 s120 vdd vdd pch W=1u L=0.18u
Cl121 s121 0 10f
Mn122 s122 s121 0 0 nch W=0.5u L=0.18u
Mp122 s122 s121 vdd vdd pch W=1u L=0.18u
Cl122 s122 0 10f
Mn123 s123 s122 0 0 nch W=0.5u L=0.18u
Mp123 s123 s122 vdd vdd pch W=1u L=0.18u
Cl123 s123 0 10f
Mn124 s124 s123 0 0 nch W=0.5u L=0.18u
Mp124 s124 s123 vdd vdd pch W=1u L=0.18u
Cl124 s124 0 10f
Mn125 s125 s124 0 0 nch W=0.5u L=0.18u
Mp125 s125 s124 vdd vdd pch W=1u L=0.18u
Cl125 s125 0 10f
Mn126 s126 s125 0 0 nch W=0.5u L=0.18u
Mp126 s126 s125 vdd vdd pch W=1u L=0.18u
Cl126 s126 0 10f
Mn127 s127 s126 0 0 nch W=0.5u L=0.18u
Mp127 s127 s126 vdd vdd pch W=1u L=0.18u
Cl127 s127 0 10f
Mn128 s128 s127 0 0 nch W=0.5u L=0.18u
Mp128 s128 s127 vdd vdd pch W=1u L=0.18u
Cl128 s128 0 10f
Mn129 s129 s128 0 0 nch W=0.5u L=0.18u
Mp129 s129 s128 vdd vdd pch W=1u L=0.18u
Cl129 s129 0 10f
Mn130 s130 s129 0 0 nch W=0.5u L=0.18u
Mp130 s130 s129 vdd vdd pch W=1u L=0.18u
Cl130 s130 0 10f
Mn131 s131 s130 0 0 nch W=0.5u L=0.18u
Mp131 s131 s130 vdd vdd pch W=1u L=0.18u
Cl131 s131 0 10f
Mn132 s132 s131 0 0 nch W=0.5u L=0.18u
Mp132 s132 s131 vdd vdd pch W=1u L=0.18u
Cl132 s132 0 10f
Mn133 s133 s132 0 0 nch W=0.5u L=0.18u
Mp133 s133 s132 vdd vdd pch W=1u L=0.18u
Cl133 s133 0 10f
Mn134 s134 s133 0 0 nch W=0.5u L=0.18u
Mp134 s134 s133 vdd vdd pch W=1u L=0.18u
Cl134 s134 0 10f
Mn135 s135 s134 0 0 nch W=0.5u L=0.18u
Mp135 s135 s134 vdd vdd pch W=1u L=0.18u
Cl135 s135 0 10f
Mn136 s136 s135 0 0 nch W=0.5u L=0.18u
Mp136 s136 s135 vdd vdd pch W=1u L=0.18u
Cl136 s136 0 10f
Mn137 s137 s136 0 0 nch W=0.5u L=0.18u
Mp137 s137 s136 vdd vdd pch W=1u L=0.18u
Cl137 s137 0 10f
Mn138 s138 s137 0 0 nch W=0.5u L=0.18u
Mp138 s138 s137 vdd vdd pch W=1u L=0.18u
Cl138 s138 0 10f
Mn139 s139 s138 0 0 nch W=0.5u L=0.18u
Mp139 s139 s138 vdd vdd pch W=1u L=0.18u
Cl139 s139 0 10f
Mn140 s140 s139 0 0 nch W=0.5u L=0.18u
Mp140 s140 s139 vdd vdd pch W=1u L=0.18u
Cl140 s140 0 10f
Mn141 s141 s140 0 0 nch W=0.5u L=0.18u
Mp141 s141 s140 vdd vdd pch W=1u L=0.18u
Cl141 s141 0 10f
Mn142 s142 s141 0 0 nch W=0.5u L=0.18u
Mp142 s142 s141 vdd vdd pch W=1u L=0.18u
Cl142 s142 0 10f
Mn143 s143 s142 0 0 nch W=0.5u L=0.18u
Mp143 s143 s142 vdd vdd pch W=1u L=0.18u
Cl143 s143 0 10f
Mn144 s144 s143 0 0 nch W=0.5u L=0.18u
Mp144 s144 s143 vdd vdd pch W=1u L=0.18u
Cl144 s144 0 10f
Mn145 s145 s144 0 0 nch W=0.5u L=0.18u
Mp145 s145 s144 vdd vdd pch W=1u L=0.18u
Cl145 s145 0 10f
Mn146 s146 s145 0 0 nch W=0.5u L=0.18u
Mp146 s146 s145 vdd vdd pch W=1u L=0.18u
Cl146 s146 0 10f
Mn147 s147 s146 0 0 nch W=0.5u L=0.18u
Mp147 s147 s146 vdd vdd pch W=1u L=0.18u
Cl147 s147 0 10f
Mn148 s148 s147 0 0 nch W=0.5u L=0.18u
Mp148 s148 s147 vdd vdd pch W=1u L=0.18u
Cl148 s148 0 10f
Mn149 s149 s148 0 0 nch W=0.5u L=0.18u
Mp149 s149 s148 vdd vdd pch W=1u L=0.18u
Cl149 s149 0 10f
Mn150 s150 s149 0 0 nch W=0.5u L=0.18u
Mp150 s150 s149 vdd vdd pch W=1u L=0.18u
Cl150 s150 0 10f
Mn151 s151 s150 0 0 nch W=0.5u L=0.18u
Mp151 s151 s150 vdd vdd pch W=1u L=0.18u
Cl151 s151 0 10f
Mn152 s152 s151 0 0 nch W=0.5u L=0.18u
Mp152 s152 s151 vdd vdd pch W=1u L=0.18u
Cl152 s152 0 10f
Mn153 s153 s152 0 0 nch W=0.5u L=0.18u
Mp153 s153 s152 vdd vdd pch W=1u L=0.18u
Cl153 s153 0 10f
Mn154 s154 s153 0 0 nch W=0.5u L=0.18u
Mp154 s154 s153 vdd vdd pch W=1u L=0.18u
Cl154 s154 0 10f
Mn155 s155 s154 0 0 nch W=0.5u L=0.18u
Mp155 s155 s154 vdd vdd pch W=1u L=0.18u
Cl155 s155 0 10f
Mn156 s156 s155 0 0 nch W=0.5u L=0.18u
Mp156 s156 s155 vdd vdd pch W=1u L=0.18u
Cl156 s156 0 10f
Mn157 s157 s156 0 0 nch W=0.5u L=0.18u
Mp157 s157 s156 vdd vdd pch W=1u L=0.18u
Cl157 s157 0 10f
Mn158 s158 s157 0 0 nch W=0.5u L=0.18u
Mp158 s158 s157 vdd vdd pch W=1u L=0.18u
Cl158 s158 0 10f
Mn159 s159 s158 0 0 nch W=0.5u L=0.18u
Mp159 s159 s158 vdd vdd pch W=1u L=0.18u
Cl159 s159 0 10f
Mn160 s160 s159 0 0 nch W=0.5u L=0.18u
Mp160 s160 s159 vdd vdd pch W=1u L=0.18u
Cl160 s160 0 10f
Mn161 s161 s160 0 0 nch W=0.5u L=0.18u
Mp161 s161 s160 vdd vdd pch W=1u L=0.18u
Cl161 s161 0 10f
Mn162 s162 s161 0 0 nch W=0.5u L=0.18u
Mp162 s162 s161 vdd vdd pch W=1u L=0.18u
Cl162 s162 0 10f
Mn163 s163 s162 0 0 nch W=0.5u L=0.18u
Mp163 s163 s162 vdd vdd pch W=1u L=0.18u
Cl163 s163 0 10f
Mn164 s164 s163 0 0 nch W=0.5u L=0.18u
Mp164 s164 s163 vdd vdd pch W=1u L=0.18u
Cl164 s164 0 10f
Mn165 s165 s164 0 0 nch W=0.5u L=0.18u
Mp165 s165 s164 vdd vdd pch W=1u L=0.18u
Cl165 s165 0 10f
Mn166 s166 s165 0 0 nch W=0.5u L=0.18u
Mp166 s166 s165 vdd vdd pch W=1u L=0.18u
Cl166 s166 0 10f
Mn167 s167 s166 0 0 nch W=0.5u L=0.18u
Mp167 s167 s166 vdd vdd pch W=1u L=0.18u
Cl167 s167 0 10f
Mn168 s168 s167 0 0 nch W=0.5u L=0.18u
Mp168 s168 s167 vdd vdd pch W=1u L=0.18u
Cl168 s168 0 10f
Mn169 s169 s168 0 0 nch W=0.5u L=0.18u
Mp169 s169 s168 vdd vdd pch W=1u L=0.18u
Cl169 s169 0 10f
Mn170 s170 s169 0 0 nch W=0.5u L=0.18u
Mp170 s170 s169 vdd vdd pch W=1u L=0.18u
Cl170 s170 0 10f
Mn171 s171 s170 0 0 nch W=0.5u L=0.18u
Mp171 s171 s170 vdd vdd pch W=1u L=0.18u
Cl171 s171 0 10f
Mn172 s172 s171 0 0 nch W=0.5u L=0.18u
Mp172 s172 s171 vdd vdd pch W=1u L=0.18u
Cl172 s172 0 10f
Mn173 s173 s172 0 0 nch W=0.5u L=0.18u
Mp173 s173 s172 vdd vdd pch W=1u L=0.18u
Cl173 s173 0 10f
Mn174 s174 s173 0 0 nch W=0.5u L=0.18u
Mp174 s174 s173 vdd vdd pch W=1u L=0.18u
Cl174 s174 0 10f
Mn175 s175 s174 0 0 nch W=0.5u L=0.18u
Mp175 s175 s174 vdd vdd pch W=1u L=0.18u
Cl175 s175 0 10f
Mn176 s176 s175 0 0 nch W=0.5u L=0.18u
Mp176 s176 s175 vdd vdd pch W=1u L=0.18u
Cl176 s176 0 10f
Mn177 s177 s176 0 0 nch W=0.5u L=0.18u
Mp177 s177 s176 vdd vdd pch W=1u L=0.18u
Cl177 s177 0 10f
Mn178 s178 s177 0 0 nch W=0.5u L=0.18u
Mp178 s178 s177 vdd vdd pch W=1u L=0.18u
Cl178 s178 0 10f
Mn179 s179 s178 0 0 nch W=0.5u L=0.18u
Mp179 s179 s178 vdd vdd pch W=1u L=0.18u
Cl179 s179 0 10f
Mn180 s180 s179 0 0 nch W=0.5u L=0.18u
Mp180 s180 s179 vdd vdd pch W=1u L=0.18u
Cl180 s180 0 10f
Mn181 s181 s180 0 0 nch W=0.5u L=0.18u
Mp181 s181 s180 vdd vdd pch W=1u L=0.18u
Cl181 s181 0 10f
Mn182 s182 s181 0 0 nch W=0.5u L=0.18u
Mp182 s182 s181 vdd vdd pch W=1u L=0.18u
Cl182 s182 0 10f
Mn183 s183 s182 0 0 nch W=0.5u L=0.18u
Mp183 s183 s182 vdd vdd pch W=1u L=0.18u
Cl183 s183 0 10f
Mn184 s184 s183 0 0 nch W=0.5u L=0.18u
Mp184 s184 s183 vdd vdd pch W=1u L=0.18u
Cl184 s184 0 10f
Mn185 s185 s184 0 0 nch W=0.5u L=0.18u
Mp185 s185 s184 vdd vdd pch W=1u L=0.18u
Cl185 s185 0 10f
Mn186 s186 s185 0 0 nch W=0.5u L=0.18u
Mp186 s186 s185 vdd vdd pch W=1u L=0.18u
Cl186 s186 0 10f
Mn187 s187 s186 0 0 nch W=0.5u L=0.18u
Mp187 s187 s186 vdd vdd pch W=1u L=0.18u
Cl187 s187 0 10f
Mn188 s188 s187 0 0 nch W=0.5u L=0.18u
Mp188 s188 s187 vdd vdd pch W=1u L=0.18u
Cl188 s188 0 10f
Mn189 s189 s188 0 0 nch W=0.5u L=0.18u
Mp189 s189 s188 vdd vdd pch W=1u L=0.18u
Cl189 s189 0 10f
Mn190 s190 s189 0 0 nch W=0.5u L=0.18u
Mp190 s190 s189 vdd vdd pch W=1u L=0.18u
Cl190 s190 0 10f
Mn191 s191 s190 0 0 nch W=0.5u L=0.18u
Mp191 s191 s190 vdd vdd pch W=1u L=0.18u
Cl191 s191 0 10f
Mn192 s192 s191 0 0 nch W=0.5u L=0.18u
Mp192 s192 s191 vdd vdd pch W=1u L=0.18u
Cl192 s192 0 10f
Mn193 s193 s192 0 0 nch W=0.5u L=0.18u
Mp193 s193 s192 vdd vdd pch W=1u L=0.18u
Cl193 s193 0 10f
Mn194 s194 s193 0 0 nch W=0.5u L=0.18u
Mp194 s194 s193 vdd vdd pch W=1u L=0.18u
Cl194 s194 0 10f
Mn195 s195 s194 0 0 nch W=0.5u L=0.18u
Mp195 s195 s194 vdd vdd pch W=1u L=0.18u
Cl195 s195 0 10f
Mn196 s196 s195 0 0 nch W=0.5u L=0.18u
Mp196 s196 s195 vdd vdd pch W=1u L=0.18u
Cl196 s196 0 10f
Mn197 s197 s196 0 0 nch W=0.5u L=0.18u
Mp197 s197 s196 vdd vdd pch W=1u L=0.18u
Cl197 s197 0 10f
Mn198 s198 s197 0 0 nch W=0.5u L=0.18u
Mp198 s198 s197 vdd vdd pch W=1u L=0.18u
Cl198 s198 0 10f
Mn199 s199 s198 0 0 nch W=0.5u L=0.18u
Mp199 s199 s198 vdd vdd pch W=1u L=0.18u
Cl199 s199 0 10f
Mn200 s200 s199 0 0 nch W=0.5u L=0.18u
Mp200 s200 s199 vdd vdd pch W=1u L=0.18u
Cl200 s200 0 10f
Mn201 s201 s200 0 0 nch W=0.5u L=0.18u
Mp201 s201 s200 vdd vdd pch W=1u L=0.18u
Cl201 s201 0 10f
Mn202 s202 s201 0 0 nch W=0.5u L=0.18u
Mp202 s202 s201 vdd vdd pch W=1u L=0.18u
Cl202 s202 0 10f
Mn203 s203 s202 0 0 nch W=0.5u L=0.18u
Mp203 s203 s202 vdd vdd pch W=1u L=0.18u
Cl203 s203 0 10f
Mn204 s204 s203 0 0 nch W=0.5u L=0.18u
Mp204 s204 s203 vdd vdd pch W=1u L=0.18u
Cl204 s204 0 10f
Mn205 s205 s204 0 0 nch W=0.5u L=0.18u
Mp205 s205 s204 vdd vdd pch W=1u L=0.18u
Cl205 s205 0 10f
Mn206 s206 s205 0 0 nch W=0.5u L=0.18u
Mp206 s206 s205 vdd vdd pch W=1u L=0.18u
Cl206 s206 0 10f
Mn207 s207 s206 0 0 nch W=0.5u L=0.18u
Mp207 s207 s206 vdd vdd pch W=1u L=0.18u
Cl207 s207 0 10f
Mn208 s208 s207 0 0 nch W=0.5u L=0.18u
Mp208 s208 s207 vdd vdd pch W=1u L=0.18u
Cl208 s208 0 10f
Mn209 s209 s208 0 0 nch W=0.5u L=0.18u
Mp209 s209 s208 vdd vdd pch W=1u L=0.18u
Cl209 s209 0 10f
Mn210 s210 s209 0 0 nch W=0.5u L=0.18u
Mp210 s210 s209 vdd vdd pch W=1u L=0.18u
Cl210 s210 0 10f
Mn211 s211 s210 0 0 nch W=0.5u L=0.18u
Mp211 s211 s210 vdd vdd pch W=1u L=0.18u
Cl211 s211 0 10f
Mn212 s212 s211 0 0 nch W=0.5u L=0.18u
Mp212 s212 s211 vdd vdd pch W=1u L=0.18u
Cl212 s212 0 10f
Mn213 s213 s212 0 0 nch W=0.5u L=0.18u
Mp213 s213 s212 vdd vdd pch W=1u L=0.18u
Cl213 s213 0 10f
Mn214 s214 s213 0 0 nch W=0.5u L=0.18u
Mp214 s214 s213 vdd vdd pch W=1u L=0.18u
Cl214 s214 0 10f
Mn215 s215 s214 0 0 nch W=0.5u L=0.18u
Mp215 s215 s214 vdd vdd pch W=1u L=0.18u
Cl215 s215 0 10f
Mn216 s216 s215 0 0 nch W=0.5u L=0.18u
Mp216 s216 s215 vdd vdd pch W=1u L=0.18u
Cl216 s216 0 10f
Mn217 s217 s216 0 0 nch W=0.5u L=0.18u
Mp217 s217 s216 vdd vdd pch W=1u L=0.18u
Cl217 s217 0 10f
Mn218 s218 s217 0 0 nch W=0.5u L=0.18u
Mp218 s218 s217 vdd vdd pch W=1u L=0.18u
Cl218 s218 0 10f
Mn219 s219 s218 0 0 nch W=0.5u L=0.18u
Mp219 s219 s218 vdd vdd pch W=1u L=0.18u
Cl219 s219 0 10f
Mn220 s220 s219 0 0 nch W=0.5u L=0.18u
Mp220 s220 s219 vdd vdd pch W=1u L=0.18u
Cl220 s220 0 10f
Mn221 s221 s220 0 0 nch W=0.5u L=0.18u
Mp221 s221 s220 vdd vdd pch W=1u L=0.18u
Cl221 s221 0 10f
Mn222 s222 s221 0 0 nch W=0.5u L=0.18u
Mp222 s222 s221 vdd vdd pch W=1u L=0.18u
Cl222 s222 0 10f
Mn223 s223 s222 0 0 nch W=0.5u L=0.18u
Mp223 s223 s222 vdd vdd pch W=1u L=0.18u
Cl223 s223 0 10f
Mn224 s224 s223 0 0 nch W=0.5u L=0.18u
Mp224 s224 s223 vdd vdd pch W=1u L=0.18u
Cl224 s224 0 10f
Mn225 s225 s224 0 0 nch W=0.5u L=0.18u
Mp225 s225 s224 vdd vdd pch W=1u L=0.18u
Cl225 s225 0 10f
Mn226 s226 s225 0 0 nch W=0.5u L=0.18u
Mp226 s226 s225 vdd vdd pch W=1u L=0.18u
Cl226 s226 0 10f
Mn227 s227 s226 0 0 nch W=0.5u L=0.18u
Mp227 s227 s226 vdd vdd pch W=1u L=0.18u
Cl227 s227 0 10f
Mn228 s228 s227 0 0 nch W=0.5u L=0.18u
Mp228 s228 s227 vdd vdd pch W=1u L=0.18u
Cl228 s228 0 10f
Mn229 s229 s228 0 0 nch W=0.5u L=0.18u
Mp229 s229 s228 vdd vdd pch W=1u L=0.18u
Cl229 s229 0 10f
Mn230 s230 s229 0 0 nch W=0.5u L=0.18u
Mp230 s230 s229 vdd vdd pch W=1u L=0.18u
Cl230 s230 0 10f
Mn231 s231 s230 0 0 nch W=0.5u L=0.18u
Mp231 s231 s230 vdd vdd pch W=1u L=0.18u
Cl231 s231 0 10f
Mn232 s232 s231 0 0 nch W=0.5u L=0.18u
Mp232 s232 s231 vdd vdd pch W=1u L=0.18u
Cl232 s232 0 10f
Mn233 s233 s232 0 0 nch W=0.5u L=0.18u
Mp233 s233 s232 vdd vdd pch W=1u L=0.18u
Cl233 s233 0 10f
Mn234 s234 s233 0 0 nch W=0.5u L=0.18u
Mp234 s234 s233 vdd vdd pch W=1u L=0.18u
Cl234 s234 0 10f
Mn235 s235 s234 0 0 nch W=0.5u L=0.18u
Mp235 s235 s234 vdd vdd pch W=1u L=0.18u
Cl235 s235 0 10f
Mn236 s236 s235 0 0 nch W=0.5u L=0.18u
Mp236 s236 s235 vdd vdd pch W=1u L=0.18u
Cl236 s236 0 10f
Mn237 s237 s236 0 0 nch W=0.5u L=0.18u
Mp237 s237 s236 vdd vdd pch W=1u L=0.18u
Cl237 s237 0 10f
Mn238 s238 s237 0 0 nch W=0.5u L=0.18u
Mp238 s238 s237 vdd vdd pch W=1u L=0.18u
Cl238 s238 0 10f
Mn239 s239 s238 0 0 nch W=0.5u L=0.18u
Mp239 s239 s238 vdd vdd pch W=1u L=0.18u
Cl239 s239 0 10f
Mn240 s240 s239 0 0 nch W=0.5u L=0.18u
Mp240 s240 s239 vdd vdd pch W=1u L=0.18u
Cl240 s240 0 10f
Mn241 s241 s240 0 0 nch W=0.5u L=0.18u
Mp241 s241 s240 vdd vdd pch W=1u L=0.18u
Cl241 s241 0 10f
Mn242 s242 s241 0 0 nch W=0.5u L=0.18u
Mp242 s242 s241 vdd vdd pch W=1u L=0.18u
Cl242 s242 0 10f
Mn243 s243 s242 0 0 nch W=0.5u L=0.18u
Mp243 s243 s242 vdd vdd pch W=1u L=0.18u
Cl243 s243 0 10f
Mn244 s244 s243 0 0 nch W=0.5u L=0.18u
Mp244 s244 s243 vdd vdd pch W=1u L=0.18u
Cl244 s244 0 10f
Mn245 s245 s244 0 0 nch W=0.5u L=0.18u
Mp245 s245 s244 vdd vdd pch W=1u L=0.18u
Cl245 s245 0 10f
Mn246 s246 s245 0 0 nch W=0.5u L=0.18u
Mp246 s246 s245 vdd vdd pch W=1u L=0.18u
Cl246 s246 0 10f
Mn247 s247 s246 0 0 nch W=0.5u L=0.18u
Mp247 s247 s246 vdd vdd pch W=1u L=0.18u
Cl247 s247 0 10f
Mn248 s248 s247 0 0 nch W=0.5u L=0.18u
Mp248 s248 s247 vdd vdd pch W=1u L=0.18u
Cl248 s248 0 10f
Mn249 s249 s248 0 0 nch W=0.5u L=0.18u
Mp249 s249 s248 vdd vdd pch W=1u L=0.18u
Cl249 s249 0 10f
Mn250 s250 s249 0 0 nch W=0.5u L=0.18u
Mp250 s250 s249 vdd vdd pch W=1u L=0.18u
Cl250 s250 0 10f
Mn251 s251 s250 0 0 nch W=0.5u L=0.18u
Mp251 s251 s250 vdd vdd pch W=1u L=0.18u
Cl251 s251 0 10f
Mn252 s252 s251 0 0 nch W=0.5u L=0.18u
Mp252 s252 s251 vdd vdd pch W=1u L=0.18u
Cl252 s252 0 10f
Mn253 s253 s252 0 0 nch W=0.5u L=0.18u
Mp253 s253 s252 vdd vdd pch W=1u L=0.18u
Cl253 s253 0 10f
Mn254 s254 s253 0 0 nch W=0.5u L=0.18u
Mp254 s254 s253 vdd vdd pch W=1u L=0.18u
Cl254 s254 0 10f
Mn255 s255 s254 0 0 nch W=0.5u L=0.18u
Mp255 s255 s254 vdd vdd pch W=1u L=0.18u
Cl255 s255 0 10f
Mn256 s256 s255 0 0 nch W=0.5u L=0.18u
Mp256 s256 s255 vdd vdd pch W=1u L=0.18u
Cload s256 0 10f
.tran 0.1n 50n
.end
