* CMOS Inverter Chain: 4000 stages — stress test
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
Cl256 s256 0 10f
Mn257 s257 s256 0 0 nch W=0.5u L=0.18u
Mp257 s257 s256 vdd vdd pch W=1u L=0.18u
Cl257 s257 0 10f
Mn258 s258 s257 0 0 nch W=0.5u L=0.18u
Mp258 s258 s257 vdd vdd pch W=1u L=0.18u
Cl258 s258 0 10f
Mn259 s259 s258 0 0 nch W=0.5u L=0.18u
Mp259 s259 s258 vdd vdd pch W=1u L=0.18u
Cl259 s259 0 10f
Mn260 s260 s259 0 0 nch W=0.5u L=0.18u
Mp260 s260 s259 vdd vdd pch W=1u L=0.18u
Cl260 s260 0 10f
Mn261 s261 s260 0 0 nch W=0.5u L=0.18u
Mp261 s261 s260 vdd vdd pch W=1u L=0.18u
Cl261 s261 0 10f
Mn262 s262 s261 0 0 nch W=0.5u L=0.18u
Mp262 s262 s261 vdd vdd pch W=1u L=0.18u
Cl262 s262 0 10f
Mn263 s263 s262 0 0 nch W=0.5u L=0.18u
Mp263 s263 s262 vdd vdd pch W=1u L=0.18u
Cl263 s263 0 10f
Mn264 s264 s263 0 0 nch W=0.5u L=0.18u
Mp264 s264 s263 vdd vdd pch W=1u L=0.18u
Cl264 s264 0 10f
Mn265 s265 s264 0 0 nch W=0.5u L=0.18u
Mp265 s265 s264 vdd vdd pch W=1u L=0.18u
Cl265 s265 0 10f
Mn266 s266 s265 0 0 nch W=0.5u L=0.18u
Mp266 s266 s265 vdd vdd pch W=1u L=0.18u
Cl266 s266 0 10f
Mn267 s267 s266 0 0 nch W=0.5u L=0.18u
Mp267 s267 s266 vdd vdd pch W=1u L=0.18u
Cl267 s267 0 10f
Mn268 s268 s267 0 0 nch W=0.5u L=0.18u
Mp268 s268 s267 vdd vdd pch W=1u L=0.18u
Cl268 s268 0 10f
Mn269 s269 s268 0 0 nch W=0.5u L=0.18u
Mp269 s269 s268 vdd vdd pch W=1u L=0.18u
Cl269 s269 0 10f
Mn270 s270 s269 0 0 nch W=0.5u L=0.18u
Mp270 s270 s269 vdd vdd pch W=1u L=0.18u
Cl270 s270 0 10f
Mn271 s271 s270 0 0 nch W=0.5u L=0.18u
Mp271 s271 s270 vdd vdd pch W=1u L=0.18u
Cl271 s271 0 10f
Mn272 s272 s271 0 0 nch W=0.5u L=0.18u
Mp272 s272 s271 vdd vdd pch W=1u L=0.18u
Cl272 s272 0 10f
Mn273 s273 s272 0 0 nch W=0.5u L=0.18u
Mp273 s273 s272 vdd vdd pch W=1u L=0.18u
Cl273 s273 0 10f
Mn274 s274 s273 0 0 nch W=0.5u L=0.18u
Mp274 s274 s273 vdd vdd pch W=1u L=0.18u
Cl274 s274 0 10f
Mn275 s275 s274 0 0 nch W=0.5u L=0.18u
Mp275 s275 s274 vdd vdd pch W=1u L=0.18u
Cl275 s275 0 10f
Mn276 s276 s275 0 0 nch W=0.5u L=0.18u
Mp276 s276 s275 vdd vdd pch W=1u L=0.18u
Cl276 s276 0 10f
Mn277 s277 s276 0 0 nch W=0.5u L=0.18u
Mp277 s277 s276 vdd vdd pch W=1u L=0.18u
Cl277 s277 0 10f
Mn278 s278 s277 0 0 nch W=0.5u L=0.18u
Mp278 s278 s277 vdd vdd pch W=1u L=0.18u
Cl278 s278 0 10f
Mn279 s279 s278 0 0 nch W=0.5u L=0.18u
Mp279 s279 s278 vdd vdd pch W=1u L=0.18u
Cl279 s279 0 10f
Mn280 s280 s279 0 0 nch W=0.5u L=0.18u
Mp280 s280 s279 vdd vdd pch W=1u L=0.18u
Cl280 s280 0 10f
Mn281 s281 s280 0 0 nch W=0.5u L=0.18u
Mp281 s281 s280 vdd vdd pch W=1u L=0.18u
Cl281 s281 0 10f
Mn282 s282 s281 0 0 nch W=0.5u L=0.18u
Mp282 s282 s281 vdd vdd pch W=1u L=0.18u
Cl282 s282 0 10f
Mn283 s283 s282 0 0 nch W=0.5u L=0.18u
Mp283 s283 s282 vdd vdd pch W=1u L=0.18u
Cl283 s283 0 10f
Mn284 s284 s283 0 0 nch W=0.5u L=0.18u
Mp284 s284 s283 vdd vdd pch W=1u L=0.18u
Cl284 s284 0 10f
Mn285 s285 s284 0 0 nch W=0.5u L=0.18u
Mp285 s285 s284 vdd vdd pch W=1u L=0.18u
Cl285 s285 0 10f
Mn286 s286 s285 0 0 nch W=0.5u L=0.18u
Mp286 s286 s285 vdd vdd pch W=1u L=0.18u
Cl286 s286 0 10f
Mn287 s287 s286 0 0 nch W=0.5u L=0.18u
Mp287 s287 s286 vdd vdd pch W=1u L=0.18u
Cl287 s287 0 10f
Mn288 s288 s287 0 0 nch W=0.5u L=0.18u
Mp288 s288 s287 vdd vdd pch W=1u L=0.18u
Cl288 s288 0 10f
Mn289 s289 s288 0 0 nch W=0.5u L=0.18u
Mp289 s289 s288 vdd vdd pch W=1u L=0.18u
Cl289 s289 0 10f
Mn290 s290 s289 0 0 nch W=0.5u L=0.18u
Mp290 s290 s289 vdd vdd pch W=1u L=0.18u
Cl290 s290 0 10f
Mn291 s291 s290 0 0 nch W=0.5u L=0.18u
Mp291 s291 s290 vdd vdd pch W=1u L=0.18u
Cl291 s291 0 10f
Mn292 s292 s291 0 0 nch W=0.5u L=0.18u
Mp292 s292 s291 vdd vdd pch W=1u L=0.18u
Cl292 s292 0 10f
Mn293 s293 s292 0 0 nch W=0.5u L=0.18u
Mp293 s293 s292 vdd vdd pch W=1u L=0.18u
Cl293 s293 0 10f
Mn294 s294 s293 0 0 nch W=0.5u L=0.18u
Mp294 s294 s293 vdd vdd pch W=1u L=0.18u
Cl294 s294 0 10f
Mn295 s295 s294 0 0 nch W=0.5u L=0.18u
Mp295 s295 s294 vdd vdd pch W=1u L=0.18u
Cl295 s295 0 10f
Mn296 s296 s295 0 0 nch W=0.5u L=0.18u
Mp296 s296 s295 vdd vdd pch W=1u L=0.18u
Cl296 s296 0 10f
Mn297 s297 s296 0 0 nch W=0.5u L=0.18u
Mp297 s297 s296 vdd vdd pch W=1u L=0.18u
Cl297 s297 0 10f
Mn298 s298 s297 0 0 nch W=0.5u L=0.18u
Mp298 s298 s297 vdd vdd pch W=1u L=0.18u
Cl298 s298 0 10f
Mn299 s299 s298 0 0 nch W=0.5u L=0.18u
Mp299 s299 s298 vdd vdd pch W=1u L=0.18u
Cl299 s299 0 10f
Mn300 s300 s299 0 0 nch W=0.5u L=0.18u
Mp300 s300 s299 vdd vdd pch W=1u L=0.18u
Cl300 s300 0 10f
Mn301 s301 s300 0 0 nch W=0.5u L=0.18u
Mp301 s301 s300 vdd vdd pch W=1u L=0.18u
Cl301 s301 0 10f
Mn302 s302 s301 0 0 nch W=0.5u L=0.18u
Mp302 s302 s301 vdd vdd pch W=1u L=0.18u
Cl302 s302 0 10f
Mn303 s303 s302 0 0 nch W=0.5u L=0.18u
Mp303 s303 s302 vdd vdd pch W=1u L=0.18u
Cl303 s303 0 10f
Mn304 s304 s303 0 0 nch W=0.5u L=0.18u
Mp304 s304 s303 vdd vdd pch W=1u L=0.18u
Cl304 s304 0 10f
Mn305 s305 s304 0 0 nch W=0.5u L=0.18u
Mp305 s305 s304 vdd vdd pch W=1u L=0.18u
Cl305 s305 0 10f
Mn306 s306 s305 0 0 nch W=0.5u L=0.18u
Mp306 s306 s305 vdd vdd pch W=1u L=0.18u
Cl306 s306 0 10f
Mn307 s307 s306 0 0 nch W=0.5u L=0.18u
Mp307 s307 s306 vdd vdd pch W=1u L=0.18u
Cl307 s307 0 10f
Mn308 s308 s307 0 0 nch W=0.5u L=0.18u
Mp308 s308 s307 vdd vdd pch W=1u L=0.18u
Cl308 s308 0 10f
Mn309 s309 s308 0 0 nch W=0.5u L=0.18u
Mp309 s309 s308 vdd vdd pch W=1u L=0.18u
Cl309 s309 0 10f
Mn310 s310 s309 0 0 nch W=0.5u L=0.18u
Mp310 s310 s309 vdd vdd pch W=1u L=0.18u
Cl310 s310 0 10f
Mn311 s311 s310 0 0 nch W=0.5u L=0.18u
Mp311 s311 s310 vdd vdd pch W=1u L=0.18u
Cl311 s311 0 10f
Mn312 s312 s311 0 0 nch W=0.5u L=0.18u
Mp312 s312 s311 vdd vdd pch W=1u L=0.18u
Cl312 s312 0 10f
Mn313 s313 s312 0 0 nch W=0.5u L=0.18u
Mp313 s313 s312 vdd vdd pch W=1u L=0.18u
Cl313 s313 0 10f
Mn314 s314 s313 0 0 nch W=0.5u L=0.18u
Mp314 s314 s313 vdd vdd pch W=1u L=0.18u
Cl314 s314 0 10f
Mn315 s315 s314 0 0 nch W=0.5u L=0.18u
Mp315 s315 s314 vdd vdd pch W=1u L=0.18u
Cl315 s315 0 10f
Mn316 s316 s315 0 0 nch W=0.5u L=0.18u
Mp316 s316 s315 vdd vdd pch W=1u L=0.18u
Cl316 s316 0 10f
Mn317 s317 s316 0 0 nch W=0.5u L=0.18u
Mp317 s317 s316 vdd vdd pch W=1u L=0.18u
Cl317 s317 0 10f
Mn318 s318 s317 0 0 nch W=0.5u L=0.18u
Mp318 s318 s317 vdd vdd pch W=1u L=0.18u
Cl318 s318 0 10f
Mn319 s319 s318 0 0 nch W=0.5u L=0.18u
Mp319 s319 s318 vdd vdd pch W=1u L=0.18u
Cl319 s319 0 10f
Mn320 s320 s319 0 0 nch W=0.5u L=0.18u
Mp320 s320 s319 vdd vdd pch W=1u L=0.18u
Cl320 s320 0 10f
Mn321 s321 s320 0 0 nch W=0.5u L=0.18u
Mp321 s321 s320 vdd vdd pch W=1u L=0.18u
Cl321 s321 0 10f
Mn322 s322 s321 0 0 nch W=0.5u L=0.18u
Mp322 s322 s321 vdd vdd pch W=1u L=0.18u
Cl322 s322 0 10f
Mn323 s323 s322 0 0 nch W=0.5u L=0.18u
Mp323 s323 s322 vdd vdd pch W=1u L=0.18u
Cl323 s323 0 10f
Mn324 s324 s323 0 0 nch W=0.5u L=0.18u
Mp324 s324 s323 vdd vdd pch W=1u L=0.18u
Cl324 s324 0 10f
Mn325 s325 s324 0 0 nch W=0.5u L=0.18u
Mp325 s325 s324 vdd vdd pch W=1u L=0.18u
Cl325 s325 0 10f
Mn326 s326 s325 0 0 nch W=0.5u L=0.18u
Mp326 s326 s325 vdd vdd pch W=1u L=0.18u
Cl326 s326 0 10f
Mn327 s327 s326 0 0 nch W=0.5u L=0.18u
Mp327 s327 s326 vdd vdd pch W=1u L=0.18u
Cl327 s327 0 10f
Mn328 s328 s327 0 0 nch W=0.5u L=0.18u
Mp328 s328 s327 vdd vdd pch W=1u L=0.18u
Cl328 s328 0 10f
Mn329 s329 s328 0 0 nch W=0.5u L=0.18u
Mp329 s329 s328 vdd vdd pch W=1u L=0.18u
Cl329 s329 0 10f
Mn330 s330 s329 0 0 nch W=0.5u L=0.18u
Mp330 s330 s329 vdd vdd pch W=1u L=0.18u
Cl330 s330 0 10f
Mn331 s331 s330 0 0 nch W=0.5u L=0.18u
Mp331 s331 s330 vdd vdd pch W=1u L=0.18u
Cl331 s331 0 10f
Mn332 s332 s331 0 0 nch W=0.5u L=0.18u
Mp332 s332 s331 vdd vdd pch W=1u L=0.18u
Cl332 s332 0 10f
Mn333 s333 s332 0 0 nch W=0.5u L=0.18u
Mp333 s333 s332 vdd vdd pch W=1u L=0.18u
Cl333 s333 0 10f
Mn334 s334 s333 0 0 nch W=0.5u L=0.18u
Mp334 s334 s333 vdd vdd pch W=1u L=0.18u
Cl334 s334 0 10f
Mn335 s335 s334 0 0 nch W=0.5u L=0.18u
Mp335 s335 s334 vdd vdd pch W=1u L=0.18u
Cl335 s335 0 10f
Mn336 s336 s335 0 0 nch W=0.5u L=0.18u
Mp336 s336 s335 vdd vdd pch W=1u L=0.18u
Cl336 s336 0 10f
Mn337 s337 s336 0 0 nch W=0.5u L=0.18u
Mp337 s337 s336 vdd vdd pch W=1u L=0.18u
Cl337 s337 0 10f
Mn338 s338 s337 0 0 nch W=0.5u L=0.18u
Mp338 s338 s337 vdd vdd pch W=1u L=0.18u
Cl338 s338 0 10f
Mn339 s339 s338 0 0 nch W=0.5u L=0.18u
Mp339 s339 s338 vdd vdd pch W=1u L=0.18u
Cl339 s339 0 10f
Mn340 s340 s339 0 0 nch W=0.5u L=0.18u
Mp340 s340 s339 vdd vdd pch W=1u L=0.18u
Cl340 s340 0 10f
Mn341 s341 s340 0 0 nch W=0.5u L=0.18u
Mp341 s341 s340 vdd vdd pch W=1u L=0.18u
Cl341 s341 0 10f
Mn342 s342 s341 0 0 nch W=0.5u L=0.18u
Mp342 s342 s341 vdd vdd pch W=1u L=0.18u
Cl342 s342 0 10f
Mn343 s343 s342 0 0 nch W=0.5u L=0.18u
Mp343 s343 s342 vdd vdd pch W=1u L=0.18u
Cl343 s343 0 10f
Mn344 s344 s343 0 0 nch W=0.5u L=0.18u
Mp344 s344 s343 vdd vdd pch W=1u L=0.18u
Cl344 s344 0 10f
Mn345 s345 s344 0 0 nch W=0.5u L=0.18u
Mp345 s345 s344 vdd vdd pch W=1u L=0.18u
Cl345 s345 0 10f
Mn346 s346 s345 0 0 nch W=0.5u L=0.18u
Mp346 s346 s345 vdd vdd pch W=1u L=0.18u
Cl346 s346 0 10f
Mn347 s347 s346 0 0 nch W=0.5u L=0.18u
Mp347 s347 s346 vdd vdd pch W=1u L=0.18u
Cl347 s347 0 10f
Mn348 s348 s347 0 0 nch W=0.5u L=0.18u
Mp348 s348 s347 vdd vdd pch W=1u L=0.18u
Cl348 s348 0 10f
Mn349 s349 s348 0 0 nch W=0.5u L=0.18u
Mp349 s349 s348 vdd vdd pch W=1u L=0.18u
Cl349 s349 0 10f
Mn350 s350 s349 0 0 nch W=0.5u L=0.18u
Mp350 s350 s349 vdd vdd pch W=1u L=0.18u
Cl350 s350 0 10f
Mn351 s351 s350 0 0 nch W=0.5u L=0.18u
Mp351 s351 s350 vdd vdd pch W=1u L=0.18u
Cl351 s351 0 10f
Mn352 s352 s351 0 0 nch W=0.5u L=0.18u
Mp352 s352 s351 vdd vdd pch W=1u L=0.18u
Cl352 s352 0 10f
Mn353 s353 s352 0 0 nch W=0.5u L=0.18u
Mp353 s353 s352 vdd vdd pch W=1u L=0.18u
Cl353 s353 0 10f
Mn354 s354 s353 0 0 nch W=0.5u L=0.18u
Mp354 s354 s353 vdd vdd pch W=1u L=0.18u
Cl354 s354 0 10f
Mn355 s355 s354 0 0 nch W=0.5u L=0.18u
Mp355 s355 s354 vdd vdd pch W=1u L=0.18u
Cl355 s355 0 10f
Mn356 s356 s355 0 0 nch W=0.5u L=0.18u
Mp356 s356 s355 vdd vdd pch W=1u L=0.18u
Cl356 s356 0 10f
Mn357 s357 s356 0 0 nch W=0.5u L=0.18u
Mp357 s357 s356 vdd vdd pch W=1u L=0.18u
Cl357 s357 0 10f
Mn358 s358 s357 0 0 nch W=0.5u L=0.18u
Mp358 s358 s357 vdd vdd pch W=1u L=0.18u
Cl358 s358 0 10f
Mn359 s359 s358 0 0 nch W=0.5u L=0.18u
Mp359 s359 s358 vdd vdd pch W=1u L=0.18u
Cl359 s359 0 10f
Mn360 s360 s359 0 0 nch W=0.5u L=0.18u
Mp360 s360 s359 vdd vdd pch W=1u L=0.18u
Cl360 s360 0 10f
Mn361 s361 s360 0 0 nch W=0.5u L=0.18u
Mp361 s361 s360 vdd vdd pch W=1u L=0.18u
Cl361 s361 0 10f
Mn362 s362 s361 0 0 nch W=0.5u L=0.18u
Mp362 s362 s361 vdd vdd pch W=1u L=0.18u
Cl362 s362 0 10f
Mn363 s363 s362 0 0 nch W=0.5u L=0.18u
Mp363 s363 s362 vdd vdd pch W=1u L=0.18u
Cl363 s363 0 10f
Mn364 s364 s363 0 0 nch W=0.5u L=0.18u
Mp364 s364 s363 vdd vdd pch W=1u L=0.18u
Cl364 s364 0 10f
Mn365 s365 s364 0 0 nch W=0.5u L=0.18u
Mp365 s365 s364 vdd vdd pch W=1u L=0.18u
Cl365 s365 0 10f
Mn366 s366 s365 0 0 nch W=0.5u L=0.18u
Mp366 s366 s365 vdd vdd pch W=1u L=0.18u
Cl366 s366 0 10f
Mn367 s367 s366 0 0 nch W=0.5u L=0.18u
Mp367 s367 s366 vdd vdd pch W=1u L=0.18u
Cl367 s367 0 10f
Mn368 s368 s367 0 0 nch W=0.5u L=0.18u
Mp368 s368 s367 vdd vdd pch W=1u L=0.18u
Cl368 s368 0 10f
Mn369 s369 s368 0 0 nch W=0.5u L=0.18u
Mp369 s369 s368 vdd vdd pch W=1u L=0.18u
Cl369 s369 0 10f
Mn370 s370 s369 0 0 nch W=0.5u L=0.18u
Mp370 s370 s369 vdd vdd pch W=1u L=0.18u
Cl370 s370 0 10f
Mn371 s371 s370 0 0 nch W=0.5u L=0.18u
Mp371 s371 s370 vdd vdd pch W=1u L=0.18u
Cl371 s371 0 10f
Mn372 s372 s371 0 0 nch W=0.5u L=0.18u
Mp372 s372 s371 vdd vdd pch W=1u L=0.18u
Cl372 s372 0 10f
Mn373 s373 s372 0 0 nch W=0.5u L=0.18u
Mp373 s373 s372 vdd vdd pch W=1u L=0.18u
Cl373 s373 0 10f
Mn374 s374 s373 0 0 nch W=0.5u L=0.18u
Mp374 s374 s373 vdd vdd pch W=1u L=0.18u
Cl374 s374 0 10f
Mn375 s375 s374 0 0 nch W=0.5u L=0.18u
Mp375 s375 s374 vdd vdd pch W=1u L=0.18u
Cl375 s375 0 10f
Mn376 s376 s375 0 0 nch W=0.5u L=0.18u
Mp376 s376 s375 vdd vdd pch W=1u L=0.18u
Cl376 s376 0 10f
Mn377 s377 s376 0 0 nch W=0.5u L=0.18u
Mp377 s377 s376 vdd vdd pch W=1u L=0.18u
Cl377 s377 0 10f
Mn378 s378 s377 0 0 nch W=0.5u L=0.18u
Mp378 s378 s377 vdd vdd pch W=1u L=0.18u
Cl378 s378 0 10f
Mn379 s379 s378 0 0 nch W=0.5u L=0.18u
Mp379 s379 s378 vdd vdd pch W=1u L=0.18u
Cl379 s379 0 10f
Mn380 s380 s379 0 0 nch W=0.5u L=0.18u
Mp380 s380 s379 vdd vdd pch W=1u L=0.18u
Cl380 s380 0 10f
Mn381 s381 s380 0 0 nch W=0.5u L=0.18u
Mp381 s381 s380 vdd vdd pch W=1u L=0.18u
Cl381 s381 0 10f
Mn382 s382 s381 0 0 nch W=0.5u L=0.18u
Mp382 s382 s381 vdd vdd pch W=1u L=0.18u
Cl382 s382 0 10f
Mn383 s383 s382 0 0 nch W=0.5u L=0.18u
Mp383 s383 s382 vdd vdd pch W=1u L=0.18u
Cl383 s383 0 10f
Mn384 s384 s383 0 0 nch W=0.5u L=0.18u
Mp384 s384 s383 vdd vdd pch W=1u L=0.18u
Cl384 s384 0 10f
Mn385 s385 s384 0 0 nch W=0.5u L=0.18u
Mp385 s385 s384 vdd vdd pch W=1u L=0.18u
Cl385 s385 0 10f
Mn386 s386 s385 0 0 nch W=0.5u L=0.18u
Mp386 s386 s385 vdd vdd pch W=1u L=0.18u
Cl386 s386 0 10f
Mn387 s387 s386 0 0 nch W=0.5u L=0.18u
Mp387 s387 s386 vdd vdd pch W=1u L=0.18u
Cl387 s387 0 10f
Mn388 s388 s387 0 0 nch W=0.5u L=0.18u
Mp388 s388 s387 vdd vdd pch W=1u L=0.18u
Cl388 s388 0 10f
Mn389 s389 s388 0 0 nch W=0.5u L=0.18u
Mp389 s389 s388 vdd vdd pch W=1u L=0.18u
Cl389 s389 0 10f
Mn390 s390 s389 0 0 nch W=0.5u L=0.18u
Mp390 s390 s389 vdd vdd pch W=1u L=0.18u
Cl390 s390 0 10f
Mn391 s391 s390 0 0 nch W=0.5u L=0.18u
Mp391 s391 s390 vdd vdd pch W=1u L=0.18u
Cl391 s391 0 10f
Mn392 s392 s391 0 0 nch W=0.5u L=0.18u
Mp392 s392 s391 vdd vdd pch W=1u L=0.18u
Cl392 s392 0 10f
Mn393 s393 s392 0 0 nch W=0.5u L=0.18u
Mp393 s393 s392 vdd vdd pch W=1u L=0.18u
Cl393 s393 0 10f
Mn394 s394 s393 0 0 nch W=0.5u L=0.18u
Mp394 s394 s393 vdd vdd pch W=1u L=0.18u
Cl394 s394 0 10f
Mn395 s395 s394 0 0 nch W=0.5u L=0.18u
Mp395 s395 s394 vdd vdd pch W=1u L=0.18u
Cl395 s395 0 10f
Mn396 s396 s395 0 0 nch W=0.5u L=0.18u
Mp396 s396 s395 vdd vdd pch W=1u L=0.18u
Cl396 s396 0 10f
Mn397 s397 s396 0 0 nch W=0.5u L=0.18u
Mp397 s397 s396 vdd vdd pch W=1u L=0.18u
Cl397 s397 0 10f
Mn398 s398 s397 0 0 nch W=0.5u L=0.18u
Mp398 s398 s397 vdd vdd pch W=1u L=0.18u
Cl398 s398 0 10f
Mn399 s399 s398 0 0 nch W=0.5u L=0.18u
Mp399 s399 s398 vdd vdd pch W=1u L=0.18u
Cl399 s399 0 10f
Mn400 s400 s399 0 0 nch W=0.5u L=0.18u
Mp400 s400 s399 vdd vdd pch W=1u L=0.18u
Cl400 s400 0 10f
Mn401 s401 s400 0 0 nch W=0.5u L=0.18u
Mp401 s401 s400 vdd vdd pch W=1u L=0.18u
Cl401 s401 0 10f
Mn402 s402 s401 0 0 nch W=0.5u L=0.18u
Mp402 s402 s401 vdd vdd pch W=1u L=0.18u
Cl402 s402 0 10f
Mn403 s403 s402 0 0 nch W=0.5u L=0.18u
Mp403 s403 s402 vdd vdd pch W=1u L=0.18u
Cl403 s403 0 10f
Mn404 s404 s403 0 0 nch W=0.5u L=0.18u
Mp404 s404 s403 vdd vdd pch W=1u L=0.18u
Cl404 s404 0 10f
Mn405 s405 s404 0 0 nch W=0.5u L=0.18u
Mp405 s405 s404 vdd vdd pch W=1u L=0.18u
Cl405 s405 0 10f
Mn406 s406 s405 0 0 nch W=0.5u L=0.18u
Mp406 s406 s405 vdd vdd pch W=1u L=0.18u
Cl406 s406 0 10f
Mn407 s407 s406 0 0 nch W=0.5u L=0.18u
Mp407 s407 s406 vdd vdd pch W=1u L=0.18u
Cl407 s407 0 10f
Mn408 s408 s407 0 0 nch W=0.5u L=0.18u
Mp408 s408 s407 vdd vdd pch W=1u L=0.18u
Cl408 s408 0 10f
Mn409 s409 s408 0 0 nch W=0.5u L=0.18u
Mp409 s409 s408 vdd vdd pch W=1u L=0.18u
Cl409 s409 0 10f
Mn410 s410 s409 0 0 nch W=0.5u L=0.18u
Mp410 s410 s409 vdd vdd pch W=1u L=0.18u
Cl410 s410 0 10f
Mn411 s411 s410 0 0 nch W=0.5u L=0.18u
Mp411 s411 s410 vdd vdd pch W=1u L=0.18u
Cl411 s411 0 10f
Mn412 s412 s411 0 0 nch W=0.5u L=0.18u
Mp412 s412 s411 vdd vdd pch W=1u L=0.18u
Cl412 s412 0 10f
Mn413 s413 s412 0 0 nch W=0.5u L=0.18u
Mp413 s413 s412 vdd vdd pch W=1u L=0.18u
Cl413 s413 0 10f
Mn414 s414 s413 0 0 nch W=0.5u L=0.18u
Mp414 s414 s413 vdd vdd pch W=1u L=0.18u
Cl414 s414 0 10f
Mn415 s415 s414 0 0 nch W=0.5u L=0.18u
Mp415 s415 s414 vdd vdd pch W=1u L=0.18u
Cl415 s415 0 10f
Mn416 s416 s415 0 0 nch W=0.5u L=0.18u
Mp416 s416 s415 vdd vdd pch W=1u L=0.18u
Cl416 s416 0 10f
Mn417 s417 s416 0 0 nch W=0.5u L=0.18u
Mp417 s417 s416 vdd vdd pch W=1u L=0.18u
Cl417 s417 0 10f
Mn418 s418 s417 0 0 nch W=0.5u L=0.18u
Mp418 s418 s417 vdd vdd pch W=1u L=0.18u
Cl418 s418 0 10f
Mn419 s419 s418 0 0 nch W=0.5u L=0.18u
Mp419 s419 s418 vdd vdd pch W=1u L=0.18u
Cl419 s419 0 10f
Mn420 s420 s419 0 0 nch W=0.5u L=0.18u
Mp420 s420 s419 vdd vdd pch W=1u L=0.18u
Cl420 s420 0 10f
Mn421 s421 s420 0 0 nch W=0.5u L=0.18u
Mp421 s421 s420 vdd vdd pch W=1u L=0.18u
Cl421 s421 0 10f
Mn422 s422 s421 0 0 nch W=0.5u L=0.18u
Mp422 s422 s421 vdd vdd pch W=1u L=0.18u
Cl422 s422 0 10f
Mn423 s423 s422 0 0 nch W=0.5u L=0.18u
Mp423 s423 s422 vdd vdd pch W=1u L=0.18u
Cl423 s423 0 10f
Mn424 s424 s423 0 0 nch W=0.5u L=0.18u
Mp424 s424 s423 vdd vdd pch W=1u L=0.18u
Cl424 s424 0 10f
Mn425 s425 s424 0 0 nch W=0.5u L=0.18u
Mp425 s425 s424 vdd vdd pch W=1u L=0.18u
Cl425 s425 0 10f
Mn426 s426 s425 0 0 nch W=0.5u L=0.18u
Mp426 s426 s425 vdd vdd pch W=1u L=0.18u
Cl426 s426 0 10f
Mn427 s427 s426 0 0 nch W=0.5u L=0.18u
Mp427 s427 s426 vdd vdd pch W=1u L=0.18u
Cl427 s427 0 10f
Mn428 s428 s427 0 0 nch W=0.5u L=0.18u
Mp428 s428 s427 vdd vdd pch W=1u L=0.18u
Cl428 s428 0 10f
Mn429 s429 s428 0 0 nch W=0.5u L=0.18u
Mp429 s429 s428 vdd vdd pch W=1u L=0.18u
Cl429 s429 0 10f
Mn430 s430 s429 0 0 nch W=0.5u L=0.18u
Mp430 s430 s429 vdd vdd pch W=1u L=0.18u
Cl430 s430 0 10f
Mn431 s431 s430 0 0 nch W=0.5u L=0.18u
Mp431 s431 s430 vdd vdd pch W=1u L=0.18u
Cl431 s431 0 10f
Mn432 s432 s431 0 0 nch W=0.5u L=0.18u
Mp432 s432 s431 vdd vdd pch W=1u L=0.18u
Cl432 s432 0 10f
Mn433 s433 s432 0 0 nch W=0.5u L=0.18u
Mp433 s433 s432 vdd vdd pch W=1u L=0.18u
Cl433 s433 0 10f
Mn434 s434 s433 0 0 nch W=0.5u L=0.18u
Mp434 s434 s433 vdd vdd pch W=1u L=0.18u
Cl434 s434 0 10f
Mn435 s435 s434 0 0 nch W=0.5u L=0.18u
Mp435 s435 s434 vdd vdd pch W=1u L=0.18u
Cl435 s435 0 10f
Mn436 s436 s435 0 0 nch W=0.5u L=0.18u
Mp436 s436 s435 vdd vdd pch W=1u L=0.18u
Cl436 s436 0 10f
Mn437 s437 s436 0 0 nch W=0.5u L=0.18u
Mp437 s437 s436 vdd vdd pch W=1u L=0.18u
Cl437 s437 0 10f
Mn438 s438 s437 0 0 nch W=0.5u L=0.18u
Mp438 s438 s437 vdd vdd pch W=1u L=0.18u
Cl438 s438 0 10f
Mn439 s439 s438 0 0 nch W=0.5u L=0.18u
Mp439 s439 s438 vdd vdd pch W=1u L=0.18u
Cl439 s439 0 10f
Mn440 s440 s439 0 0 nch W=0.5u L=0.18u
Mp440 s440 s439 vdd vdd pch W=1u L=0.18u
Cl440 s440 0 10f
Mn441 s441 s440 0 0 nch W=0.5u L=0.18u
Mp441 s441 s440 vdd vdd pch W=1u L=0.18u
Cl441 s441 0 10f
Mn442 s442 s441 0 0 nch W=0.5u L=0.18u
Mp442 s442 s441 vdd vdd pch W=1u L=0.18u
Cl442 s442 0 10f
Mn443 s443 s442 0 0 nch W=0.5u L=0.18u
Mp443 s443 s442 vdd vdd pch W=1u L=0.18u
Cl443 s443 0 10f
Mn444 s444 s443 0 0 nch W=0.5u L=0.18u
Mp444 s444 s443 vdd vdd pch W=1u L=0.18u
Cl444 s444 0 10f
Mn445 s445 s444 0 0 nch W=0.5u L=0.18u
Mp445 s445 s444 vdd vdd pch W=1u L=0.18u
Cl445 s445 0 10f
Mn446 s446 s445 0 0 nch W=0.5u L=0.18u
Mp446 s446 s445 vdd vdd pch W=1u L=0.18u
Cl446 s446 0 10f
Mn447 s447 s446 0 0 nch W=0.5u L=0.18u
Mp447 s447 s446 vdd vdd pch W=1u L=0.18u
Cl447 s447 0 10f
Mn448 s448 s447 0 0 nch W=0.5u L=0.18u
Mp448 s448 s447 vdd vdd pch W=1u L=0.18u
Cl448 s448 0 10f
Mn449 s449 s448 0 0 nch W=0.5u L=0.18u
Mp449 s449 s448 vdd vdd pch W=1u L=0.18u
Cl449 s449 0 10f
Mn450 s450 s449 0 0 nch W=0.5u L=0.18u
Mp450 s450 s449 vdd vdd pch W=1u L=0.18u
Cl450 s450 0 10f
Mn451 s451 s450 0 0 nch W=0.5u L=0.18u
Mp451 s451 s450 vdd vdd pch W=1u L=0.18u
Cl451 s451 0 10f
Mn452 s452 s451 0 0 nch W=0.5u L=0.18u
Mp452 s452 s451 vdd vdd pch W=1u L=0.18u
Cl452 s452 0 10f
Mn453 s453 s452 0 0 nch W=0.5u L=0.18u
Mp453 s453 s452 vdd vdd pch W=1u L=0.18u
Cl453 s453 0 10f
Mn454 s454 s453 0 0 nch W=0.5u L=0.18u
Mp454 s454 s453 vdd vdd pch W=1u L=0.18u
Cl454 s454 0 10f
Mn455 s455 s454 0 0 nch W=0.5u L=0.18u
Mp455 s455 s454 vdd vdd pch W=1u L=0.18u
Cl455 s455 0 10f
Mn456 s456 s455 0 0 nch W=0.5u L=0.18u
Mp456 s456 s455 vdd vdd pch W=1u L=0.18u
Cl456 s456 0 10f
Mn457 s457 s456 0 0 nch W=0.5u L=0.18u
Mp457 s457 s456 vdd vdd pch W=1u L=0.18u
Cl457 s457 0 10f
Mn458 s458 s457 0 0 nch W=0.5u L=0.18u
Mp458 s458 s457 vdd vdd pch W=1u L=0.18u
Cl458 s458 0 10f
Mn459 s459 s458 0 0 nch W=0.5u L=0.18u
Mp459 s459 s458 vdd vdd pch W=1u L=0.18u
Cl459 s459 0 10f
Mn460 s460 s459 0 0 nch W=0.5u L=0.18u
Mp460 s460 s459 vdd vdd pch W=1u L=0.18u
Cl460 s460 0 10f
Mn461 s461 s460 0 0 nch W=0.5u L=0.18u
Mp461 s461 s460 vdd vdd pch W=1u L=0.18u
Cl461 s461 0 10f
Mn462 s462 s461 0 0 nch W=0.5u L=0.18u
Mp462 s462 s461 vdd vdd pch W=1u L=0.18u
Cl462 s462 0 10f
Mn463 s463 s462 0 0 nch W=0.5u L=0.18u
Mp463 s463 s462 vdd vdd pch W=1u L=0.18u
Cl463 s463 0 10f
Mn464 s464 s463 0 0 nch W=0.5u L=0.18u
Mp464 s464 s463 vdd vdd pch W=1u L=0.18u
Cl464 s464 0 10f
Mn465 s465 s464 0 0 nch W=0.5u L=0.18u
Mp465 s465 s464 vdd vdd pch W=1u L=0.18u
Cl465 s465 0 10f
Mn466 s466 s465 0 0 nch W=0.5u L=0.18u
Mp466 s466 s465 vdd vdd pch W=1u L=0.18u
Cl466 s466 0 10f
Mn467 s467 s466 0 0 nch W=0.5u L=0.18u
Mp467 s467 s466 vdd vdd pch W=1u L=0.18u
Cl467 s467 0 10f
Mn468 s468 s467 0 0 nch W=0.5u L=0.18u
Mp468 s468 s467 vdd vdd pch W=1u L=0.18u
Cl468 s468 0 10f
Mn469 s469 s468 0 0 nch W=0.5u L=0.18u
Mp469 s469 s468 vdd vdd pch W=1u L=0.18u
Cl469 s469 0 10f
Mn470 s470 s469 0 0 nch W=0.5u L=0.18u
Mp470 s470 s469 vdd vdd pch W=1u L=0.18u
Cl470 s470 0 10f
Mn471 s471 s470 0 0 nch W=0.5u L=0.18u
Mp471 s471 s470 vdd vdd pch W=1u L=0.18u
Cl471 s471 0 10f
Mn472 s472 s471 0 0 nch W=0.5u L=0.18u
Mp472 s472 s471 vdd vdd pch W=1u L=0.18u
Cl472 s472 0 10f
Mn473 s473 s472 0 0 nch W=0.5u L=0.18u
Mp473 s473 s472 vdd vdd pch W=1u L=0.18u
Cl473 s473 0 10f
Mn474 s474 s473 0 0 nch W=0.5u L=0.18u
Mp474 s474 s473 vdd vdd pch W=1u L=0.18u
Cl474 s474 0 10f
Mn475 s475 s474 0 0 nch W=0.5u L=0.18u
Mp475 s475 s474 vdd vdd pch W=1u L=0.18u
Cl475 s475 0 10f
Mn476 s476 s475 0 0 nch W=0.5u L=0.18u
Mp476 s476 s475 vdd vdd pch W=1u L=0.18u
Cl476 s476 0 10f
Mn477 s477 s476 0 0 nch W=0.5u L=0.18u
Mp477 s477 s476 vdd vdd pch W=1u L=0.18u
Cl477 s477 0 10f
Mn478 s478 s477 0 0 nch W=0.5u L=0.18u
Mp478 s478 s477 vdd vdd pch W=1u L=0.18u
Cl478 s478 0 10f
Mn479 s479 s478 0 0 nch W=0.5u L=0.18u
Mp479 s479 s478 vdd vdd pch W=1u L=0.18u
Cl479 s479 0 10f
Mn480 s480 s479 0 0 nch W=0.5u L=0.18u
Mp480 s480 s479 vdd vdd pch W=1u L=0.18u
Cl480 s480 0 10f
Mn481 s481 s480 0 0 nch W=0.5u L=0.18u
Mp481 s481 s480 vdd vdd pch W=1u L=0.18u
Cl481 s481 0 10f
Mn482 s482 s481 0 0 nch W=0.5u L=0.18u
Mp482 s482 s481 vdd vdd pch W=1u L=0.18u
Cl482 s482 0 10f
Mn483 s483 s482 0 0 nch W=0.5u L=0.18u
Mp483 s483 s482 vdd vdd pch W=1u L=0.18u
Cl483 s483 0 10f
Mn484 s484 s483 0 0 nch W=0.5u L=0.18u
Mp484 s484 s483 vdd vdd pch W=1u L=0.18u
Cl484 s484 0 10f
Mn485 s485 s484 0 0 nch W=0.5u L=0.18u
Mp485 s485 s484 vdd vdd pch W=1u L=0.18u
Cl485 s485 0 10f
Mn486 s486 s485 0 0 nch W=0.5u L=0.18u
Mp486 s486 s485 vdd vdd pch W=1u L=0.18u
Cl486 s486 0 10f
Mn487 s487 s486 0 0 nch W=0.5u L=0.18u
Mp487 s487 s486 vdd vdd pch W=1u L=0.18u
Cl487 s487 0 10f
Mn488 s488 s487 0 0 nch W=0.5u L=0.18u
Mp488 s488 s487 vdd vdd pch W=1u L=0.18u
Cl488 s488 0 10f
Mn489 s489 s488 0 0 nch W=0.5u L=0.18u
Mp489 s489 s488 vdd vdd pch W=1u L=0.18u
Cl489 s489 0 10f
Mn490 s490 s489 0 0 nch W=0.5u L=0.18u
Mp490 s490 s489 vdd vdd pch W=1u L=0.18u
Cl490 s490 0 10f
Mn491 s491 s490 0 0 nch W=0.5u L=0.18u
Mp491 s491 s490 vdd vdd pch W=1u L=0.18u
Cl491 s491 0 10f
Mn492 s492 s491 0 0 nch W=0.5u L=0.18u
Mp492 s492 s491 vdd vdd pch W=1u L=0.18u
Cl492 s492 0 10f
Mn493 s493 s492 0 0 nch W=0.5u L=0.18u
Mp493 s493 s492 vdd vdd pch W=1u L=0.18u
Cl493 s493 0 10f
Mn494 s494 s493 0 0 nch W=0.5u L=0.18u
Mp494 s494 s493 vdd vdd pch W=1u L=0.18u
Cl494 s494 0 10f
Mn495 s495 s494 0 0 nch W=0.5u L=0.18u
Mp495 s495 s494 vdd vdd pch W=1u L=0.18u
Cl495 s495 0 10f
Mn496 s496 s495 0 0 nch W=0.5u L=0.18u
Mp496 s496 s495 vdd vdd pch W=1u L=0.18u
Cl496 s496 0 10f
Mn497 s497 s496 0 0 nch W=0.5u L=0.18u
Mp497 s497 s496 vdd vdd pch W=1u L=0.18u
Cl497 s497 0 10f
Mn498 s498 s497 0 0 nch W=0.5u L=0.18u
Mp498 s498 s497 vdd vdd pch W=1u L=0.18u
Cl498 s498 0 10f
Mn499 s499 s498 0 0 nch W=0.5u L=0.18u
Mp499 s499 s498 vdd vdd pch W=1u L=0.18u
Cl499 s499 0 10f
Mn500 s500 s499 0 0 nch W=0.5u L=0.18u
Mp500 s500 s499 vdd vdd pch W=1u L=0.18u
Cl500 s500 0 10f
Mn501 s501 s500 0 0 nch W=0.5u L=0.18u
Mp501 s501 s500 vdd vdd pch W=1u L=0.18u
Cl501 s501 0 10f
Mn502 s502 s501 0 0 nch W=0.5u L=0.18u
Mp502 s502 s501 vdd vdd pch W=1u L=0.18u
Cl502 s502 0 10f
Mn503 s503 s502 0 0 nch W=0.5u L=0.18u
Mp503 s503 s502 vdd vdd pch W=1u L=0.18u
Cl503 s503 0 10f
Mn504 s504 s503 0 0 nch W=0.5u L=0.18u
Mp504 s504 s503 vdd vdd pch W=1u L=0.18u
Cl504 s504 0 10f
Mn505 s505 s504 0 0 nch W=0.5u L=0.18u
Mp505 s505 s504 vdd vdd pch W=1u L=0.18u
Cl505 s505 0 10f
Mn506 s506 s505 0 0 nch W=0.5u L=0.18u
Mp506 s506 s505 vdd vdd pch W=1u L=0.18u
Cl506 s506 0 10f
Mn507 s507 s506 0 0 nch W=0.5u L=0.18u
Mp507 s507 s506 vdd vdd pch W=1u L=0.18u
Cl507 s507 0 10f
Mn508 s508 s507 0 0 nch W=0.5u L=0.18u
Mp508 s508 s507 vdd vdd pch W=1u L=0.18u
Cl508 s508 0 10f
Mn509 s509 s508 0 0 nch W=0.5u L=0.18u
Mp509 s509 s508 vdd vdd pch W=1u L=0.18u
Cl509 s509 0 10f
Mn510 s510 s509 0 0 nch W=0.5u L=0.18u
Mp510 s510 s509 vdd vdd pch W=1u L=0.18u
Cl510 s510 0 10f
Mn511 s511 s510 0 0 nch W=0.5u L=0.18u
Mp511 s511 s510 vdd vdd pch W=1u L=0.18u
Cl511 s511 0 10f
Mn512 s512 s511 0 0 nch W=0.5u L=0.18u
Mp512 s512 s511 vdd vdd pch W=1u L=0.18u
Cl512 s512 0 10f
Mn513 s513 s512 0 0 nch W=0.5u L=0.18u
Mp513 s513 s512 vdd vdd pch W=1u L=0.18u
Cl513 s513 0 10f
Mn514 s514 s513 0 0 nch W=0.5u L=0.18u
Mp514 s514 s513 vdd vdd pch W=1u L=0.18u
Cl514 s514 0 10f
Mn515 s515 s514 0 0 nch W=0.5u L=0.18u
Mp515 s515 s514 vdd vdd pch W=1u L=0.18u
Cl515 s515 0 10f
Mn516 s516 s515 0 0 nch W=0.5u L=0.18u
Mp516 s516 s515 vdd vdd pch W=1u L=0.18u
Cl516 s516 0 10f
Mn517 s517 s516 0 0 nch W=0.5u L=0.18u
Mp517 s517 s516 vdd vdd pch W=1u L=0.18u
Cl517 s517 0 10f
Mn518 s518 s517 0 0 nch W=0.5u L=0.18u
Mp518 s518 s517 vdd vdd pch W=1u L=0.18u
Cl518 s518 0 10f
Mn519 s519 s518 0 0 nch W=0.5u L=0.18u
Mp519 s519 s518 vdd vdd pch W=1u L=0.18u
Cl519 s519 0 10f
Mn520 s520 s519 0 0 nch W=0.5u L=0.18u
Mp520 s520 s519 vdd vdd pch W=1u L=0.18u
Cl520 s520 0 10f
Mn521 s521 s520 0 0 nch W=0.5u L=0.18u
Mp521 s521 s520 vdd vdd pch W=1u L=0.18u
Cl521 s521 0 10f
Mn522 s522 s521 0 0 nch W=0.5u L=0.18u
Mp522 s522 s521 vdd vdd pch W=1u L=0.18u
Cl522 s522 0 10f
Mn523 s523 s522 0 0 nch W=0.5u L=0.18u
Mp523 s523 s522 vdd vdd pch W=1u L=0.18u
Cl523 s523 0 10f
Mn524 s524 s523 0 0 nch W=0.5u L=0.18u
Mp524 s524 s523 vdd vdd pch W=1u L=0.18u
Cl524 s524 0 10f
Mn525 s525 s524 0 0 nch W=0.5u L=0.18u
Mp525 s525 s524 vdd vdd pch W=1u L=0.18u
Cl525 s525 0 10f
Mn526 s526 s525 0 0 nch W=0.5u L=0.18u
Mp526 s526 s525 vdd vdd pch W=1u L=0.18u
Cl526 s526 0 10f
Mn527 s527 s526 0 0 nch W=0.5u L=0.18u
Mp527 s527 s526 vdd vdd pch W=1u L=0.18u
Cl527 s527 0 10f
Mn528 s528 s527 0 0 nch W=0.5u L=0.18u
Mp528 s528 s527 vdd vdd pch W=1u L=0.18u
Cl528 s528 0 10f
Mn529 s529 s528 0 0 nch W=0.5u L=0.18u
Mp529 s529 s528 vdd vdd pch W=1u L=0.18u
Cl529 s529 0 10f
Mn530 s530 s529 0 0 nch W=0.5u L=0.18u
Mp530 s530 s529 vdd vdd pch W=1u L=0.18u
Cl530 s530 0 10f
Mn531 s531 s530 0 0 nch W=0.5u L=0.18u
Mp531 s531 s530 vdd vdd pch W=1u L=0.18u
Cl531 s531 0 10f
Mn532 s532 s531 0 0 nch W=0.5u L=0.18u
Mp532 s532 s531 vdd vdd pch W=1u L=0.18u
Cl532 s532 0 10f
Mn533 s533 s532 0 0 nch W=0.5u L=0.18u
Mp533 s533 s532 vdd vdd pch W=1u L=0.18u
Cl533 s533 0 10f
Mn534 s534 s533 0 0 nch W=0.5u L=0.18u
Mp534 s534 s533 vdd vdd pch W=1u L=0.18u
Cl534 s534 0 10f
Mn535 s535 s534 0 0 nch W=0.5u L=0.18u
Mp535 s535 s534 vdd vdd pch W=1u L=0.18u
Cl535 s535 0 10f
Mn536 s536 s535 0 0 nch W=0.5u L=0.18u
Mp536 s536 s535 vdd vdd pch W=1u L=0.18u
Cl536 s536 0 10f
Mn537 s537 s536 0 0 nch W=0.5u L=0.18u
Mp537 s537 s536 vdd vdd pch W=1u L=0.18u
Cl537 s537 0 10f
Mn538 s538 s537 0 0 nch W=0.5u L=0.18u
Mp538 s538 s537 vdd vdd pch W=1u L=0.18u
Cl538 s538 0 10f
Mn539 s539 s538 0 0 nch W=0.5u L=0.18u
Mp539 s539 s538 vdd vdd pch W=1u L=0.18u
Cl539 s539 0 10f
Mn540 s540 s539 0 0 nch W=0.5u L=0.18u
Mp540 s540 s539 vdd vdd pch W=1u L=0.18u
Cl540 s540 0 10f
Mn541 s541 s540 0 0 nch W=0.5u L=0.18u
Mp541 s541 s540 vdd vdd pch W=1u L=0.18u
Cl541 s541 0 10f
Mn542 s542 s541 0 0 nch W=0.5u L=0.18u
Mp542 s542 s541 vdd vdd pch W=1u L=0.18u
Cl542 s542 0 10f
Mn543 s543 s542 0 0 nch W=0.5u L=0.18u
Mp543 s543 s542 vdd vdd pch W=1u L=0.18u
Cl543 s543 0 10f
Mn544 s544 s543 0 0 nch W=0.5u L=0.18u
Mp544 s544 s543 vdd vdd pch W=1u L=0.18u
Cl544 s544 0 10f
Mn545 s545 s544 0 0 nch W=0.5u L=0.18u
Mp545 s545 s544 vdd vdd pch W=1u L=0.18u
Cl545 s545 0 10f
Mn546 s546 s545 0 0 nch W=0.5u L=0.18u
Mp546 s546 s545 vdd vdd pch W=1u L=0.18u
Cl546 s546 0 10f
Mn547 s547 s546 0 0 nch W=0.5u L=0.18u
Mp547 s547 s546 vdd vdd pch W=1u L=0.18u
Cl547 s547 0 10f
Mn548 s548 s547 0 0 nch W=0.5u L=0.18u
Mp548 s548 s547 vdd vdd pch W=1u L=0.18u
Cl548 s548 0 10f
Mn549 s549 s548 0 0 nch W=0.5u L=0.18u
Mp549 s549 s548 vdd vdd pch W=1u L=0.18u
Cl549 s549 0 10f
Mn550 s550 s549 0 0 nch W=0.5u L=0.18u
Mp550 s550 s549 vdd vdd pch W=1u L=0.18u
Cl550 s550 0 10f
Mn551 s551 s550 0 0 nch W=0.5u L=0.18u
Mp551 s551 s550 vdd vdd pch W=1u L=0.18u
Cl551 s551 0 10f
Mn552 s552 s551 0 0 nch W=0.5u L=0.18u
Mp552 s552 s551 vdd vdd pch W=1u L=0.18u
Cl552 s552 0 10f
Mn553 s553 s552 0 0 nch W=0.5u L=0.18u
Mp553 s553 s552 vdd vdd pch W=1u L=0.18u
Cl553 s553 0 10f
Mn554 s554 s553 0 0 nch W=0.5u L=0.18u
Mp554 s554 s553 vdd vdd pch W=1u L=0.18u
Cl554 s554 0 10f
Mn555 s555 s554 0 0 nch W=0.5u L=0.18u
Mp555 s555 s554 vdd vdd pch W=1u L=0.18u
Cl555 s555 0 10f
Mn556 s556 s555 0 0 nch W=0.5u L=0.18u
Mp556 s556 s555 vdd vdd pch W=1u L=0.18u
Cl556 s556 0 10f
Mn557 s557 s556 0 0 nch W=0.5u L=0.18u
Mp557 s557 s556 vdd vdd pch W=1u L=0.18u
Cl557 s557 0 10f
Mn558 s558 s557 0 0 nch W=0.5u L=0.18u
Mp558 s558 s557 vdd vdd pch W=1u L=0.18u
Cl558 s558 0 10f
Mn559 s559 s558 0 0 nch W=0.5u L=0.18u
Mp559 s559 s558 vdd vdd pch W=1u L=0.18u
Cl559 s559 0 10f
Mn560 s560 s559 0 0 nch W=0.5u L=0.18u
Mp560 s560 s559 vdd vdd pch W=1u L=0.18u
Cl560 s560 0 10f
Mn561 s561 s560 0 0 nch W=0.5u L=0.18u
Mp561 s561 s560 vdd vdd pch W=1u L=0.18u
Cl561 s561 0 10f
Mn562 s562 s561 0 0 nch W=0.5u L=0.18u
Mp562 s562 s561 vdd vdd pch W=1u L=0.18u
Cl562 s562 0 10f
Mn563 s563 s562 0 0 nch W=0.5u L=0.18u
Mp563 s563 s562 vdd vdd pch W=1u L=0.18u
Cl563 s563 0 10f
Mn564 s564 s563 0 0 nch W=0.5u L=0.18u
Mp564 s564 s563 vdd vdd pch W=1u L=0.18u
Cl564 s564 0 10f
Mn565 s565 s564 0 0 nch W=0.5u L=0.18u
Mp565 s565 s564 vdd vdd pch W=1u L=0.18u
Cl565 s565 0 10f
Mn566 s566 s565 0 0 nch W=0.5u L=0.18u
Mp566 s566 s565 vdd vdd pch W=1u L=0.18u
Cl566 s566 0 10f
Mn567 s567 s566 0 0 nch W=0.5u L=0.18u
Mp567 s567 s566 vdd vdd pch W=1u L=0.18u
Cl567 s567 0 10f
Mn568 s568 s567 0 0 nch W=0.5u L=0.18u
Mp568 s568 s567 vdd vdd pch W=1u L=0.18u
Cl568 s568 0 10f
Mn569 s569 s568 0 0 nch W=0.5u L=0.18u
Mp569 s569 s568 vdd vdd pch W=1u L=0.18u
Cl569 s569 0 10f
Mn570 s570 s569 0 0 nch W=0.5u L=0.18u
Mp570 s570 s569 vdd vdd pch W=1u L=0.18u
Cl570 s570 0 10f
Mn571 s571 s570 0 0 nch W=0.5u L=0.18u
Mp571 s571 s570 vdd vdd pch W=1u L=0.18u
Cl571 s571 0 10f
Mn572 s572 s571 0 0 nch W=0.5u L=0.18u
Mp572 s572 s571 vdd vdd pch W=1u L=0.18u
Cl572 s572 0 10f
Mn573 s573 s572 0 0 nch W=0.5u L=0.18u
Mp573 s573 s572 vdd vdd pch W=1u L=0.18u
Cl573 s573 0 10f
Mn574 s574 s573 0 0 nch W=0.5u L=0.18u
Mp574 s574 s573 vdd vdd pch W=1u L=0.18u
Cl574 s574 0 10f
Mn575 s575 s574 0 0 nch W=0.5u L=0.18u
Mp575 s575 s574 vdd vdd pch W=1u L=0.18u
Cl575 s575 0 10f
Mn576 s576 s575 0 0 nch W=0.5u L=0.18u
Mp576 s576 s575 vdd vdd pch W=1u L=0.18u
Cl576 s576 0 10f
Mn577 s577 s576 0 0 nch W=0.5u L=0.18u
Mp577 s577 s576 vdd vdd pch W=1u L=0.18u
Cl577 s577 0 10f
Mn578 s578 s577 0 0 nch W=0.5u L=0.18u
Mp578 s578 s577 vdd vdd pch W=1u L=0.18u
Cl578 s578 0 10f
Mn579 s579 s578 0 0 nch W=0.5u L=0.18u
Mp579 s579 s578 vdd vdd pch W=1u L=0.18u
Cl579 s579 0 10f
Mn580 s580 s579 0 0 nch W=0.5u L=0.18u
Mp580 s580 s579 vdd vdd pch W=1u L=0.18u
Cl580 s580 0 10f
Mn581 s581 s580 0 0 nch W=0.5u L=0.18u
Mp581 s581 s580 vdd vdd pch W=1u L=0.18u
Cl581 s581 0 10f
Mn582 s582 s581 0 0 nch W=0.5u L=0.18u
Mp582 s582 s581 vdd vdd pch W=1u L=0.18u
Cl582 s582 0 10f
Mn583 s583 s582 0 0 nch W=0.5u L=0.18u
Mp583 s583 s582 vdd vdd pch W=1u L=0.18u
Cl583 s583 0 10f
Mn584 s584 s583 0 0 nch W=0.5u L=0.18u
Mp584 s584 s583 vdd vdd pch W=1u L=0.18u
Cl584 s584 0 10f
Mn585 s585 s584 0 0 nch W=0.5u L=0.18u
Mp585 s585 s584 vdd vdd pch W=1u L=0.18u
Cl585 s585 0 10f
Mn586 s586 s585 0 0 nch W=0.5u L=0.18u
Mp586 s586 s585 vdd vdd pch W=1u L=0.18u
Cl586 s586 0 10f
Mn587 s587 s586 0 0 nch W=0.5u L=0.18u
Mp587 s587 s586 vdd vdd pch W=1u L=0.18u
Cl587 s587 0 10f
Mn588 s588 s587 0 0 nch W=0.5u L=0.18u
Mp588 s588 s587 vdd vdd pch W=1u L=0.18u
Cl588 s588 0 10f
Mn589 s589 s588 0 0 nch W=0.5u L=0.18u
Mp589 s589 s588 vdd vdd pch W=1u L=0.18u
Cl589 s589 0 10f
Mn590 s590 s589 0 0 nch W=0.5u L=0.18u
Mp590 s590 s589 vdd vdd pch W=1u L=0.18u
Cl590 s590 0 10f
Mn591 s591 s590 0 0 nch W=0.5u L=0.18u
Mp591 s591 s590 vdd vdd pch W=1u L=0.18u
Cl591 s591 0 10f
Mn592 s592 s591 0 0 nch W=0.5u L=0.18u
Mp592 s592 s591 vdd vdd pch W=1u L=0.18u
Cl592 s592 0 10f
Mn593 s593 s592 0 0 nch W=0.5u L=0.18u
Mp593 s593 s592 vdd vdd pch W=1u L=0.18u
Cl593 s593 0 10f
Mn594 s594 s593 0 0 nch W=0.5u L=0.18u
Mp594 s594 s593 vdd vdd pch W=1u L=0.18u
Cl594 s594 0 10f
Mn595 s595 s594 0 0 nch W=0.5u L=0.18u
Mp595 s595 s594 vdd vdd pch W=1u L=0.18u
Cl595 s595 0 10f
Mn596 s596 s595 0 0 nch W=0.5u L=0.18u
Mp596 s596 s595 vdd vdd pch W=1u L=0.18u
Cl596 s596 0 10f
Mn597 s597 s596 0 0 nch W=0.5u L=0.18u
Mp597 s597 s596 vdd vdd pch W=1u L=0.18u
Cl597 s597 0 10f
Mn598 s598 s597 0 0 nch W=0.5u L=0.18u
Mp598 s598 s597 vdd vdd pch W=1u L=0.18u
Cl598 s598 0 10f
Mn599 s599 s598 0 0 nch W=0.5u L=0.18u
Mp599 s599 s598 vdd vdd pch W=1u L=0.18u
Cl599 s599 0 10f
Mn600 s600 s599 0 0 nch W=0.5u L=0.18u
Mp600 s600 s599 vdd vdd pch W=1u L=0.18u
Cl600 s600 0 10f
Mn601 s601 s600 0 0 nch W=0.5u L=0.18u
Mp601 s601 s600 vdd vdd pch W=1u L=0.18u
Cl601 s601 0 10f
Mn602 s602 s601 0 0 nch W=0.5u L=0.18u
Mp602 s602 s601 vdd vdd pch W=1u L=0.18u
Cl602 s602 0 10f
Mn603 s603 s602 0 0 nch W=0.5u L=0.18u
Mp603 s603 s602 vdd vdd pch W=1u L=0.18u
Cl603 s603 0 10f
Mn604 s604 s603 0 0 nch W=0.5u L=0.18u
Mp604 s604 s603 vdd vdd pch W=1u L=0.18u
Cl604 s604 0 10f
Mn605 s605 s604 0 0 nch W=0.5u L=0.18u
Mp605 s605 s604 vdd vdd pch W=1u L=0.18u
Cl605 s605 0 10f
Mn606 s606 s605 0 0 nch W=0.5u L=0.18u
Mp606 s606 s605 vdd vdd pch W=1u L=0.18u
Cl606 s606 0 10f
Mn607 s607 s606 0 0 nch W=0.5u L=0.18u
Mp607 s607 s606 vdd vdd pch W=1u L=0.18u
Cl607 s607 0 10f
Mn608 s608 s607 0 0 nch W=0.5u L=0.18u
Mp608 s608 s607 vdd vdd pch W=1u L=0.18u
Cl608 s608 0 10f
Mn609 s609 s608 0 0 nch W=0.5u L=0.18u
Mp609 s609 s608 vdd vdd pch W=1u L=0.18u
Cl609 s609 0 10f
Mn610 s610 s609 0 0 nch W=0.5u L=0.18u
Mp610 s610 s609 vdd vdd pch W=1u L=0.18u
Cl610 s610 0 10f
Mn611 s611 s610 0 0 nch W=0.5u L=0.18u
Mp611 s611 s610 vdd vdd pch W=1u L=0.18u
Cl611 s611 0 10f
Mn612 s612 s611 0 0 nch W=0.5u L=0.18u
Mp612 s612 s611 vdd vdd pch W=1u L=0.18u
Cl612 s612 0 10f
Mn613 s613 s612 0 0 nch W=0.5u L=0.18u
Mp613 s613 s612 vdd vdd pch W=1u L=0.18u
Cl613 s613 0 10f
Mn614 s614 s613 0 0 nch W=0.5u L=0.18u
Mp614 s614 s613 vdd vdd pch W=1u L=0.18u
Cl614 s614 0 10f
Mn615 s615 s614 0 0 nch W=0.5u L=0.18u
Mp615 s615 s614 vdd vdd pch W=1u L=0.18u
Cl615 s615 0 10f
Mn616 s616 s615 0 0 nch W=0.5u L=0.18u
Mp616 s616 s615 vdd vdd pch W=1u L=0.18u
Cl616 s616 0 10f
Mn617 s617 s616 0 0 nch W=0.5u L=0.18u
Mp617 s617 s616 vdd vdd pch W=1u L=0.18u
Cl617 s617 0 10f
Mn618 s618 s617 0 0 nch W=0.5u L=0.18u
Mp618 s618 s617 vdd vdd pch W=1u L=0.18u
Cl618 s618 0 10f
Mn619 s619 s618 0 0 nch W=0.5u L=0.18u
Mp619 s619 s618 vdd vdd pch W=1u L=0.18u
Cl619 s619 0 10f
Mn620 s620 s619 0 0 nch W=0.5u L=0.18u
Mp620 s620 s619 vdd vdd pch W=1u L=0.18u
Cl620 s620 0 10f
Mn621 s621 s620 0 0 nch W=0.5u L=0.18u
Mp621 s621 s620 vdd vdd pch W=1u L=0.18u
Cl621 s621 0 10f
Mn622 s622 s621 0 0 nch W=0.5u L=0.18u
Mp622 s622 s621 vdd vdd pch W=1u L=0.18u
Cl622 s622 0 10f
Mn623 s623 s622 0 0 nch W=0.5u L=0.18u
Mp623 s623 s622 vdd vdd pch W=1u L=0.18u
Cl623 s623 0 10f
Mn624 s624 s623 0 0 nch W=0.5u L=0.18u
Mp624 s624 s623 vdd vdd pch W=1u L=0.18u
Cl624 s624 0 10f
Mn625 s625 s624 0 0 nch W=0.5u L=0.18u
Mp625 s625 s624 vdd vdd pch W=1u L=0.18u
Cl625 s625 0 10f
Mn626 s626 s625 0 0 nch W=0.5u L=0.18u
Mp626 s626 s625 vdd vdd pch W=1u L=0.18u
Cl626 s626 0 10f
Mn627 s627 s626 0 0 nch W=0.5u L=0.18u
Mp627 s627 s626 vdd vdd pch W=1u L=0.18u
Cl627 s627 0 10f
Mn628 s628 s627 0 0 nch W=0.5u L=0.18u
Mp628 s628 s627 vdd vdd pch W=1u L=0.18u
Cl628 s628 0 10f
Mn629 s629 s628 0 0 nch W=0.5u L=0.18u
Mp629 s629 s628 vdd vdd pch W=1u L=0.18u
Cl629 s629 0 10f
Mn630 s630 s629 0 0 nch W=0.5u L=0.18u
Mp630 s630 s629 vdd vdd pch W=1u L=0.18u
Cl630 s630 0 10f
Mn631 s631 s630 0 0 nch W=0.5u L=0.18u
Mp631 s631 s630 vdd vdd pch W=1u L=0.18u
Cl631 s631 0 10f
Mn632 s632 s631 0 0 nch W=0.5u L=0.18u
Mp632 s632 s631 vdd vdd pch W=1u L=0.18u
Cl632 s632 0 10f
Mn633 s633 s632 0 0 nch W=0.5u L=0.18u
Mp633 s633 s632 vdd vdd pch W=1u L=0.18u
Cl633 s633 0 10f
Mn634 s634 s633 0 0 nch W=0.5u L=0.18u
Mp634 s634 s633 vdd vdd pch W=1u L=0.18u
Cl634 s634 0 10f
Mn635 s635 s634 0 0 nch W=0.5u L=0.18u
Mp635 s635 s634 vdd vdd pch W=1u L=0.18u
Cl635 s635 0 10f
Mn636 s636 s635 0 0 nch W=0.5u L=0.18u
Mp636 s636 s635 vdd vdd pch W=1u L=0.18u
Cl636 s636 0 10f
Mn637 s637 s636 0 0 nch W=0.5u L=0.18u
Mp637 s637 s636 vdd vdd pch W=1u L=0.18u
Cl637 s637 0 10f
Mn638 s638 s637 0 0 nch W=0.5u L=0.18u
Mp638 s638 s637 vdd vdd pch W=1u L=0.18u
Cl638 s638 0 10f
Mn639 s639 s638 0 0 nch W=0.5u L=0.18u
Mp639 s639 s638 vdd vdd pch W=1u L=0.18u
Cl639 s639 0 10f
Mn640 s640 s639 0 0 nch W=0.5u L=0.18u
Mp640 s640 s639 vdd vdd pch W=1u L=0.18u
Cl640 s640 0 10f
Mn641 s641 s640 0 0 nch W=0.5u L=0.18u
Mp641 s641 s640 vdd vdd pch W=1u L=0.18u
Cl641 s641 0 10f
Mn642 s642 s641 0 0 nch W=0.5u L=0.18u
Mp642 s642 s641 vdd vdd pch W=1u L=0.18u
Cl642 s642 0 10f
Mn643 s643 s642 0 0 nch W=0.5u L=0.18u
Mp643 s643 s642 vdd vdd pch W=1u L=0.18u
Cl643 s643 0 10f
Mn644 s644 s643 0 0 nch W=0.5u L=0.18u
Mp644 s644 s643 vdd vdd pch W=1u L=0.18u
Cl644 s644 0 10f
Mn645 s645 s644 0 0 nch W=0.5u L=0.18u
Mp645 s645 s644 vdd vdd pch W=1u L=0.18u
Cl645 s645 0 10f
Mn646 s646 s645 0 0 nch W=0.5u L=0.18u
Mp646 s646 s645 vdd vdd pch W=1u L=0.18u
Cl646 s646 0 10f
Mn647 s647 s646 0 0 nch W=0.5u L=0.18u
Mp647 s647 s646 vdd vdd pch W=1u L=0.18u
Cl647 s647 0 10f
Mn648 s648 s647 0 0 nch W=0.5u L=0.18u
Mp648 s648 s647 vdd vdd pch W=1u L=0.18u
Cl648 s648 0 10f
Mn649 s649 s648 0 0 nch W=0.5u L=0.18u
Mp649 s649 s648 vdd vdd pch W=1u L=0.18u
Cl649 s649 0 10f
Mn650 s650 s649 0 0 nch W=0.5u L=0.18u
Mp650 s650 s649 vdd vdd pch W=1u L=0.18u
Cl650 s650 0 10f
Mn651 s651 s650 0 0 nch W=0.5u L=0.18u
Mp651 s651 s650 vdd vdd pch W=1u L=0.18u
Cl651 s651 0 10f
Mn652 s652 s651 0 0 nch W=0.5u L=0.18u
Mp652 s652 s651 vdd vdd pch W=1u L=0.18u
Cl652 s652 0 10f
Mn653 s653 s652 0 0 nch W=0.5u L=0.18u
Mp653 s653 s652 vdd vdd pch W=1u L=0.18u
Cl653 s653 0 10f
Mn654 s654 s653 0 0 nch W=0.5u L=0.18u
Mp654 s654 s653 vdd vdd pch W=1u L=0.18u
Cl654 s654 0 10f
Mn655 s655 s654 0 0 nch W=0.5u L=0.18u
Mp655 s655 s654 vdd vdd pch W=1u L=0.18u
Cl655 s655 0 10f
Mn656 s656 s655 0 0 nch W=0.5u L=0.18u
Mp656 s656 s655 vdd vdd pch W=1u L=0.18u
Cl656 s656 0 10f
Mn657 s657 s656 0 0 nch W=0.5u L=0.18u
Mp657 s657 s656 vdd vdd pch W=1u L=0.18u
Cl657 s657 0 10f
Mn658 s658 s657 0 0 nch W=0.5u L=0.18u
Mp658 s658 s657 vdd vdd pch W=1u L=0.18u
Cl658 s658 0 10f
Mn659 s659 s658 0 0 nch W=0.5u L=0.18u
Mp659 s659 s658 vdd vdd pch W=1u L=0.18u
Cl659 s659 0 10f
Mn660 s660 s659 0 0 nch W=0.5u L=0.18u
Mp660 s660 s659 vdd vdd pch W=1u L=0.18u
Cl660 s660 0 10f
Mn661 s661 s660 0 0 nch W=0.5u L=0.18u
Mp661 s661 s660 vdd vdd pch W=1u L=0.18u
Cl661 s661 0 10f
Mn662 s662 s661 0 0 nch W=0.5u L=0.18u
Mp662 s662 s661 vdd vdd pch W=1u L=0.18u
Cl662 s662 0 10f
Mn663 s663 s662 0 0 nch W=0.5u L=0.18u
Mp663 s663 s662 vdd vdd pch W=1u L=0.18u
Cl663 s663 0 10f
Mn664 s664 s663 0 0 nch W=0.5u L=0.18u
Mp664 s664 s663 vdd vdd pch W=1u L=0.18u
Cl664 s664 0 10f
Mn665 s665 s664 0 0 nch W=0.5u L=0.18u
Mp665 s665 s664 vdd vdd pch W=1u L=0.18u
Cl665 s665 0 10f
Mn666 s666 s665 0 0 nch W=0.5u L=0.18u
Mp666 s666 s665 vdd vdd pch W=1u L=0.18u
Cl666 s666 0 10f
Mn667 s667 s666 0 0 nch W=0.5u L=0.18u
Mp667 s667 s666 vdd vdd pch W=1u L=0.18u
Cl667 s667 0 10f
Mn668 s668 s667 0 0 nch W=0.5u L=0.18u
Mp668 s668 s667 vdd vdd pch W=1u L=0.18u
Cl668 s668 0 10f
Mn669 s669 s668 0 0 nch W=0.5u L=0.18u
Mp669 s669 s668 vdd vdd pch W=1u L=0.18u
Cl669 s669 0 10f
Mn670 s670 s669 0 0 nch W=0.5u L=0.18u
Mp670 s670 s669 vdd vdd pch W=1u L=0.18u
Cl670 s670 0 10f
Mn671 s671 s670 0 0 nch W=0.5u L=0.18u
Mp671 s671 s670 vdd vdd pch W=1u L=0.18u
Cl671 s671 0 10f
Mn672 s672 s671 0 0 nch W=0.5u L=0.18u
Mp672 s672 s671 vdd vdd pch W=1u L=0.18u
Cl672 s672 0 10f
Mn673 s673 s672 0 0 nch W=0.5u L=0.18u
Mp673 s673 s672 vdd vdd pch W=1u L=0.18u
Cl673 s673 0 10f
Mn674 s674 s673 0 0 nch W=0.5u L=0.18u
Mp674 s674 s673 vdd vdd pch W=1u L=0.18u
Cl674 s674 0 10f
Mn675 s675 s674 0 0 nch W=0.5u L=0.18u
Mp675 s675 s674 vdd vdd pch W=1u L=0.18u
Cl675 s675 0 10f
Mn676 s676 s675 0 0 nch W=0.5u L=0.18u
Mp676 s676 s675 vdd vdd pch W=1u L=0.18u
Cl676 s676 0 10f
Mn677 s677 s676 0 0 nch W=0.5u L=0.18u
Mp677 s677 s676 vdd vdd pch W=1u L=0.18u
Cl677 s677 0 10f
Mn678 s678 s677 0 0 nch W=0.5u L=0.18u
Mp678 s678 s677 vdd vdd pch W=1u L=0.18u
Cl678 s678 0 10f
Mn679 s679 s678 0 0 nch W=0.5u L=0.18u
Mp679 s679 s678 vdd vdd pch W=1u L=0.18u
Cl679 s679 0 10f
Mn680 s680 s679 0 0 nch W=0.5u L=0.18u
Mp680 s680 s679 vdd vdd pch W=1u L=0.18u
Cl680 s680 0 10f
Mn681 s681 s680 0 0 nch W=0.5u L=0.18u
Mp681 s681 s680 vdd vdd pch W=1u L=0.18u
Cl681 s681 0 10f
Mn682 s682 s681 0 0 nch W=0.5u L=0.18u
Mp682 s682 s681 vdd vdd pch W=1u L=0.18u
Cl682 s682 0 10f
Mn683 s683 s682 0 0 nch W=0.5u L=0.18u
Mp683 s683 s682 vdd vdd pch W=1u L=0.18u
Cl683 s683 0 10f
Mn684 s684 s683 0 0 nch W=0.5u L=0.18u
Mp684 s684 s683 vdd vdd pch W=1u L=0.18u
Cl684 s684 0 10f
Mn685 s685 s684 0 0 nch W=0.5u L=0.18u
Mp685 s685 s684 vdd vdd pch W=1u L=0.18u
Cl685 s685 0 10f
Mn686 s686 s685 0 0 nch W=0.5u L=0.18u
Mp686 s686 s685 vdd vdd pch W=1u L=0.18u
Cl686 s686 0 10f
Mn687 s687 s686 0 0 nch W=0.5u L=0.18u
Mp687 s687 s686 vdd vdd pch W=1u L=0.18u
Cl687 s687 0 10f
Mn688 s688 s687 0 0 nch W=0.5u L=0.18u
Mp688 s688 s687 vdd vdd pch W=1u L=0.18u
Cl688 s688 0 10f
Mn689 s689 s688 0 0 nch W=0.5u L=0.18u
Mp689 s689 s688 vdd vdd pch W=1u L=0.18u
Cl689 s689 0 10f
Mn690 s690 s689 0 0 nch W=0.5u L=0.18u
Mp690 s690 s689 vdd vdd pch W=1u L=0.18u
Cl690 s690 0 10f
Mn691 s691 s690 0 0 nch W=0.5u L=0.18u
Mp691 s691 s690 vdd vdd pch W=1u L=0.18u
Cl691 s691 0 10f
Mn692 s692 s691 0 0 nch W=0.5u L=0.18u
Mp692 s692 s691 vdd vdd pch W=1u L=0.18u
Cl692 s692 0 10f
Mn693 s693 s692 0 0 nch W=0.5u L=0.18u
Mp693 s693 s692 vdd vdd pch W=1u L=0.18u
Cl693 s693 0 10f
Mn694 s694 s693 0 0 nch W=0.5u L=0.18u
Mp694 s694 s693 vdd vdd pch W=1u L=0.18u
Cl694 s694 0 10f
Mn695 s695 s694 0 0 nch W=0.5u L=0.18u
Mp695 s695 s694 vdd vdd pch W=1u L=0.18u
Cl695 s695 0 10f
Mn696 s696 s695 0 0 nch W=0.5u L=0.18u
Mp696 s696 s695 vdd vdd pch W=1u L=0.18u
Cl696 s696 0 10f
Mn697 s697 s696 0 0 nch W=0.5u L=0.18u
Mp697 s697 s696 vdd vdd pch W=1u L=0.18u
Cl697 s697 0 10f
Mn698 s698 s697 0 0 nch W=0.5u L=0.18u
Mp698 s698 s697 vdd vdd pch W=1u L=0.18u
Cl698 s698 0 10f
Mn699 s699 s698 0 0 nch W=0.5u L=0.18u
Mp699 s699 s698 vdd vdd pch W=1u L=0.18u
Cl699 s699 0 10f
Mn700 s700 s699 0 0 nch W=0.5u L=0.18u
Mp700 s700 s699 vdd vdd pch W=1u L=0.18u
Cl700 s700 0 10f
Mn701 s701 s700 0 0 nch W=0.5u L=0.18u
Mp701 s701 s700 vdd vdd pch W=1u L=0.18u
Cl701 s701 0 10f
Mn702 s702 s701 0 0 nch W=0.5u L=0.18u
Mp702 s702 s701 vdd vdd pch W=1u L=0.18u
Cl702 s702 0 10f
Mn703 s703 s702 0 0 nch W=0.5u L=0.18u
Mp703 s703 s702 vdd vdd pch W=1u L=0.18u
Cl703 s703 0 10f
Mn704 s704 s703 0 0 nch W=0.5u L=0.18u
Mp704 s704 s703 vdd vdd pch W=1u L=0.18u
Cl704 s704 0 10f
Mn705 s705 s704 0 0 nch W=0.5u L=0.18u
Mp705 s705 s704 vdd vdd pch W=1u L=0.18u
Cl705 s705 0 10f
Mn706 s706 s705 0 0 nch W=0.5u L=0.18u
Mp706 s706 s705 vdd vdd pch W=1u L=0.18u
Cl706 s706 0 10f
Mn707 s707 s706 0 0 nch W=0.5u L=0.18u
Mp707 s707 s706 vdd vdd pch W=1u L=0.18u
Cl707 s707 0 10f
Mn708 s708 s707 0 0 nch W=0.5u L=0.18u
Mp708 s708 s707 vdd vdd pch W=1u L=0.18u
Cl708 s708 0 10f
Mn709 s709 s708 0 0 nch W=0.5u L=0.18u
Mp709 s709 s708 vdd vdd pch W=1u L=0.18u
Cl709 s709 0 10f
Mn710 s710 s709 0 0 nch W=0.5u L=0.18u
Mp710 s710 s709 vdd vdd pch W=1u L=0.18u
Cl710 s710 0 10f
Mn711 s711 s710 0 0 nch W=0.5u L=0.18u
Mp711 s711 s710 vdd vdd pch W=1u L=0.18u
Cl711 s711 0 10f
Mn712 s712 s711 0 0 nch W=0.5u L=0.18u
Mp712 s712 s711 vdd vdd pch W=1u L=0.18u
Cl712 s712 0 10f
Mn713 s713 s712 0 0 nch W=0.5u L=0.18u
Mp713 s713 s712 vdd vdd pch W=1u L=0.18u
Cl713 s713 0 10f
Mn714 s714 s713 0 0 nch W=0.5u L=0.18u
Mp714 s714 s713 vdd vdd pch W=1u L=0.18u
Cl714 s714 0 10f
Mn715 s715 s714 0 0 nch W=0.5u L=0.18u
Mp715 s715 s714 vdd vdd pch W=1u L=0.18u
Cl715 s715 0 10f
Mn716 s716 s715 0 0 nch W=0.5u L=0.18u
Mp716 s716 s715 vdd vdd pch W=1u L=0.18u
Cl716 s716 0 10f
Mn717 s717 s716 0 0 nch W=0.5u L=0.18u
Mp717 s717 s716 vdd vdd pch W=1u L=0.18u
Cl717 s717 0 10f
Mn718 s718 s717 0 0 nch W=0.5u L=0.18u
Mp718 s718 s717 vdd vdd pch W=1u L=0.18u
Cl718 s718 0 10f
Mn719 s719 s718 0 0 nch W=0.5u L=0.18u
Mp719 s719 s718 vdd vdd pch W=1u L=0.18u
Cl719 s719 0 10f
Mn720 s720 s719 0 0 nch W=0.5u L=0.18u
Mp720 s720 s719 vdd vdd pch W=1u L=0.18u
Cl720 s720 0 10f
Mn721 s721 s720 0 0 nch W=0.5u L=0.18u
Mp721 s721 s720 vdd vdd pch W=1u L=0.18u
Cl721 s721 0 10f
Mn722 s722 s721 0 0 nch W=0.5u L=0.18u
Mp722 s722 s721 vdd vdd pch W=1u L=0.18u
Cl722 s722 0 10f
Mn723 s723 s722 0 0 nch W=0.5u L=0.18u
Mp723 s723 s722 vdd vdd pch W=1u L=0.18u
Cl723 s723 0 10f
Mn724 s724 s723 0 0 nch W=0.5u L=0.18u
Mp724 s724 s723 vdd vdd pch W=1u L=0.18u
Cl724 s724 0 10f
Mn725 s725 s724 0 0 nch W=0.5u L=0.18u
Mp725 s725 s724 vdd vdd pch W=1u L=0.18u
Cl725 s725 0 10f
Mn726 s726 s725 0 0 nch W=0.5u L=0.18u
Mp726 s726 s725 vdd vdd pch W=1u L=0.18u
Cl726 s726 0 10f
Mn727 s727 s726 0 0 nch W=0.5u L=0.18u
Mp727 s727 s726 vdd vdd pch W=1u L=0.18u
Cl727 s727 0 10f
Mn728 s728 s727 0 0 nch W=0.5u L=0.18u
Mp728 s728 s727 vdd vdd pch W=1u L=0.18u
Cl728 s728 0 10f
Mn729 s729 s728 0 0 nch W=0.5u L=0.18u
Mp729 s729 s728 vdd vdd pch W=1u L=0.18u
Cl729 s729 0 10f
Mn730 s730 s729 0 0 nch W=0.5u L=0.18u
Mp730 s730 s729 vdd vdd pch W=1u L=0.18u
Cl730 s730 0 10f
Mn731 s731 s730 0 0 nch W=0.5u L=0.18u
Mp731 s731 s730 vdd vdd pch W=1u L=0.18u
Cl731 s731 0 10f
Mn732 s732 s731 0 0 nch W=0.5u L=0.18u
Mp732 s732 s731 vdd vdd pch W=1u L=0.18u
Cl732 s732 0 10f
Mn733 s733 s732 0 0 nch W=0.5u L=0.18u
Mp733 s733 s732 vdd vdd pch W=1u L=0.18u
Cl733 s733 0 10f
Mn734 s734 s733 0 0 nch W=0.5u L=0.18u
Mp734 s734 s733 vdd vdd pch W=1u L=0.18u
Cl734 s734 0 10f
Mn735 s735 s734 0 0 nch W=0.5u L=0.18u
Mp735 s735 s734 vdd vdd pch W=1u L=0.18u
Cl735 s735 0 10f
Mn736 s736 s735 0 0 nch W=0.5u L=0.18u
Mp736 s736 s735 vdd vdd pch W=1u L=0.18u
Cl736 s736 0 10f
Mn737 s737 s736 0 0 nch W=0.5u L=0.18u
Mp737 s737 s736 vdd vdd pch W=1u L=0.18u
Cl737 s737 0 10f
Mn738 s738 s737 0 0 nch W=0.5u L=0.18u
Mp738 s738 s737 vdd vdd pch W=1u L=0.18u
Cl738 s738 0 10f
Mn739 s739 s738 0 0 nch W=0.5u L=0.18u
Mp739 s739 s738 vdd vdd pch W=1u L=0.18u
Cl739 s739 0 10f
Mn740 s740 s739 0 0 nch W=0.5u L=0.18u
Mp740 s740 s739 vdd vdd pch W=1u L=0.18u
Cl740 s740 0 10f
Mn741 s741 s740 0 0 nch W=0.5u L=0.18u
Mp741 s741 s740 vdd vdd pch W=1u L=0.18u
Cl741 s741 0 10f
Mn742 s742 s741 0 0 nch W=0.5u L=0.18u
Mp742 s742 s741 vdd vdd pch W=1u L=0.18u
Cl742 s742 0 10f
Mn743 s743 s742 0 0 nch W=0.5u L=0.18u
Mp743 s743 s742 vdd vdd pch W=1u L=0.18u
Cl743 s743 0 10f
Mn744 s744 s743 0 0 nch W=0.5u L=0.18u
Mp744 s744 s743 vdd vdd pch W=1u L=0.18u
Cl744 s744 0 10f
Mn745 s745 s744 0 0 nch W=0.5u L=0.18u
Mp745 s745 s744 vdd vdd pch W=1u L=0.18u
Cl745 s745 0 10f
Mn746 s746 s745 0 0 nch W=0.5u L=0.18u
Mp746 s746 s745 vdd vdd pch W=1u L=0.18u
Cl746 s746 0 10f
Mn747 s747 s746 0 0 nch W=0.5u L=0.18u
Mp747 s747 s746 vdd vdd pch W=1u L=0.18u
Cl747 s747 0 10f
Mn748 s748 s747 0 0 nch W=0.5u L=0.18u
Mp748 s748 s747 vdd vdd pch W=1u L=0.18u
Cl748 s748 0 10f
Mn749 s749 s748 0 0 nch W=0.5u L=0.18u
Mp749 s749 s748 vdd vdd pch W=1u L=0.18u
Cl749 s749 0 10f
Mn750 s750 s749 0 0 nch W=0.5u L=0.18u
Mp750 s750 s749 vdd vdd pch W=1u L=0.18u
Cl750 s750 0 10f
Mn751 s751 s750 0 0 nch W=0.5u L=0.18u
Mp751 s751 s750 vdd vdd pch W=1u L=0.18u
Cl751 s751 0 10f
Mn752 s752 s751 0 0 nch W=0.5u L=0.18u
Mp752 s752 s751 vdd vdd pch W=1u L=0.18u
Cl752 s752 0 10f
Mn753 s753 s752 0 0 nch W=0.5u L=0.18u
Mp753 s753 s752 vdd vdd pch W=1u L=0.18u
Cl753 s753 0 10f
Mn754 s754 s753 0 0 nch W=0.5u L=0.18u
Mp754 s754 s753 vdd vdd pch W=1u L=0.18u
Cl754 s754 0 10f
Mn755 s755 s754 0 0 nch W=0.5u L=0.18u
Mp755 s755 s754 vdd vdd pch W=1u L=0.18u
Cl755 s755 0 10f
Mn756 s756 s755 0 0 nch W=0.5u L=0.18u
Mp756 s756 s755 vdd vdd pch W=1u L=0.18u
Cl756 s756 0 10f
Mn757 s757 s756 0 0 nch W=0.5u L=0.18u
Mp757 s757 s756 vdd vdd pch W=1u L=0.18u
Cl757 s757 0 10f
Mn758 s758 s757 0 0 nch W=0.5u L=0.18u
Mp758 s758 s757 vdd vdd pch W=1u L=0.18u
Cl758 s758 0 10f
Mn759 s759 s758 0 0 nch W=0.5u L=0.18u
Mp759 s759 s758 vdd vdd pch W=1u L=0.18u
Cl759 s759 0 10f
Mn760 s760 s759 0 0 nch W=0.5u L=0.18u
Mp760 s760 s759 vdd vdd pch W=1u L=0.18u
Cl760 s760 0 10f
Mn761 s761 s760 0 0 nch W=0.5u L=0.18u
Mp761 s761 s760 vdd vdd pch W=1u L=0.18u
Cl761 s761 0 10f
Mn762 s762 s761 0 0 nch W=0.5u L=0.18u
Mp762 s762 s761 vdd vdd pch W=1u L=0.18u
Cl762 s762 0 10f
Mn763 s763 s762 0 0 nch W=0.5u L=0.18u
Mp763 s763 s762 vdd vdd pch W=1u L=0.18u
Cl763 s763 0 10f
Mn764 s764 s763 0 0 nch W=0.5u L=0.18u
Mp764 s764 s763 vdd vdd pch W=1u L=0.18u
Cl764 s764 0 10f
Mn765 s765 s764 0 0 nch W=0.5u L=0.18u
Mp765 s765 s764 vdd vdd pch W=1u L=0.18u
Cl765 s765 0 10f
Mn766 s766 s765 0 0 nch W=0.5u L=0.18u
Mp766 s766 s765 vdd vdd pch W=1u L=0.18u
Cl766 s766 0 10f
Mn767 s767 s766 0 0 nch W=0.5u L=0.18u
Mp767 s767 s766 vdd vdd pch W=1u L=0.18u
Cl767 s767 0 10f
Mn768 s768 s767 0 0 nch W=0.5u L=0.18u
Mp768 s768 s767 vdd vdd pch W=1u L=0.18u
Cl768 s768 0 10f
Mn769 s769 s768 0 0 nch W=0.5u L=0.18u
Mp769 s769 s768 vdd vdd pch W=1u L=0.18u
Cl769 s769 0 10f
Mn770 s770 s769 0 0 nch W=0.5u L=0.18u
Mp770 s770 s769 vdd vdd pch W=1u L=0.18u
Cl770 s770 0 10f
Mn771 s771 s770 0 0 nch W=0.5u L=0.18u
Mp771 s771 s770 vdd vdd pch W=1u L=0.18u
Cl771 s771 0 10f
Mn772 s772 s771 0 0 nch W=0.5u L=0.18u
Mp772 s772 s771 vdd vdd pch W=1u L=0.18u
Cl772 s772 0 10f
Mn773 s773 s772 0 0 nch W=0.5u L=0.18u
Mp773 s773 s772 vdd vdd pch W=1u L=0.18u
Cl773 s773 0 10f
Mn774 s774 s773 0 0 nch W=0.5u L=0.18u
Mp774 s774 s773 vdd vdd pch W=1u L=0.18u
Cl774 s774 0 10f
Mn775 s775 s774 0 0 nch W=0.5u L=0.18u
Mp775 s775 s774 vdd vdd pch W=1u L=0.18u
Cl775 s775 0 10f
Mn776 s776 s775 0 0 nch W=0.5u L=0.18u
Mp776 s776 s775 vdd vdd pch W=1u L=0.18u
Cl776 s776 0 10f
Mn777 s777 s776 0 0 nch W=0.5u L=0.18u
Mp777 s777 s776 vdd vdd pch W=1u L=0.18u
Cl777 s777 0 10f
Mn778 s778 s777 0 0 nch W=0.5u L=0.18u
Mp778 s778 s777 vdd vdd pch W=1u L=0.18u
Cl778 s778 0 10f
Mn779 s779 s778 0 0 nch W=0.5u L=0.18u
Mp779 s779 s778 vdd vdd pch W=1u L=0.18u
Cl779 s779 0 10f
Mn780 s780 s779 0 0 nch W=0.5u L=0.18u
Mp780 s780 s779 vdd vdd pch W=1u L=0.18u
Cl780 s780 0 10f
Mn781 s781 s780 0 0 nch W=0.5u L=0.18u
Mp781 s781 s780 vdd vdd pch W=1u L=0.18u
Cl781 s781 0 10f
Mn782 s782 s781 0 0 nch W=0.5u L=0.18u
Mp782 s782 s781 vdd vdd pch W=1u L=0.18u
Cl782 s782 0 10f
Mn783 s783 s782 0 0 nch W=0.5u L=0.18u
Mp783 s783 s782 vdd vdd pch W=1u L=0.18u
Cl783 s783 0 10f
Mn784 s784 s783 0 0 nch W=0.5u L=0.18u
Mp784 s784 s783 vdd vdd pch W=1u L=0.18u
Cl784 s784 0 10f
Mn785 s785 s784 0 0 nch W=0.5u L=0.18u
Mp785 s785 s784 vdd vdd pch W=1u L=0.18u
Cl785 s785 0 10f
Mn786 s786 s785 0 0 nch W=0.5u L=0.18u
Mp786 s786 s785 vdd vdd pch W=1u L=0.18u
Cl786 s786 0 10f
Mn787 s787 s786 0 0 nch W=0.5u L=0.18u
Mp787 s787 s786 vdd vdd pch W=1u L=0.18u
Cl787 s787 0 10f
Mn788 s788 s787 0 0 nch W=0.5u L=0.18u
Mp788 s788 s787 vdd vdd pch W=1u L=0.18u
Cl788 s788 0 10f
Mn789 s789 s788 0 0 nch W=0.5u L=0.18u
Mp789 s789 s788 vdd vdd pch W=1u L=0.18u
Cl789 s789 0 10f
Mn790 s790 s789 0 0 nch W=0.5u L=0.18u
Mp790 s790 s789 vdd vdd pch W=1u L=0.18u
Cl790 s790 0 10f
Mn791 s791 s790 0 0 nch W=0.5u L=0.18u
Mp791 s791 s790 vdd vdd pch W=1u L=0.18u
Cl791 s791 0 10f
Mn792 s792 s791 0 0 nch W=0.5u L=0.18u
Mp792 s792 s791 vdd vdd pch W=1u L=0.18u
Cl792 s792 0 10f
Mn793 s793 s792 0 0 nch W=0.5u L=0.18u
Mp793 s793 s792 vdd vdd pch W=1u L=0.18u
Cl793 s793 0 10f
Mn794 s794 s793 0 0 nch W=0.5u L=0.18u
Mp794 s794 s793 vdd vdd pch W=1u L=0.18u
Cl794 s794 0 10f
Mn795 s795 s794 0 0 nch W=0.5u L=0.18u
Mp795 s795 s794 vdd vdd pch W=1u L=0.18u
Cl795 s795 0 10f
Mn796 s796 s795 0 0 nch W=0.5u L=0.18u
Mp796 s796 s795 vdd vdd pch W=1u L=0.18u
Cl796 s796 0 10f
Mn797 s797 s796 0 0 nch W=0.5u L=0.18u
Mp797 s797 s796 vdd vdd pch W=1u L=0.18u
Cl797 s797 0 10f
Mn798 s798 s797 0 0 nch W=0.5u L=0.18u
Mp798 s798 s797 vdd vdd pch W=1u L=0.18u
Cl798 s798 0 10f
Mn799 s799 s798 0 0 nch W=0.5u L=0.18u
Mp799 s799 s798 vdd vdd pch W=1u L=0.18u
Cl799 s799 0 10f
Mn800 s800 s799 0 0 nch W=0.5u L=0.18u
Mp800 s800 s799 vdd vdd pch W=1u L=0.18u
Cl800 s800 0 10f
Mn801 s801 s800 0 0 nch W=0.5u L=0.18u
Mp801 s801 s800 vdd vdd pch W=1u L=0.18u
Cl801 s801 0 10f
Mn802 s802 s801 0 0 nch W=0.5u L=0.18u
Mp802 s802 s801 vdd vdd pch W=1u L=0.18u
Cl802 s802 0 10f
Mn803 s803 s802 0 0 nch W=0.5u L=0.18u
Mp803 s803 s802 vdd vdd pch W=1u L=0.18u
Cl803 s803 0 10f
Mn804 s804 s803 0 0 nch W=0.5u L=0.18u
Mp804 s804 s803 vdd vdd pch W=1u L=0.18u
Cl804 s804 0 10f
Mn805 s805 s804 0 0 nch W=0.5u L=0.18u
Mp805 s805 s804 vdd vdd pch W=1u L=0.18u
Cl805 s805 0 10f
Mn806 s806 s805 0 0 nch W=0.5u L=0.18u
Mp806 s806 s805 vdd vdd pch W=1u L=0.18u
Cl806 s806 0 10f
Mn807 s807 s806 0 0 nch W=0.5u L=0.18u
Mp807 s807 s806 vdd vdd pch W=1u L=0.18u
Cl807 s807 0 10f
Mn808 s808 s807 0 0 nch W=0.5u L=0.18u
Mp808 s808 s807 vdd vdd pch W=1u L=0.18u
Cl808 s808 0 10f
Mn809 s809 s808 0 0 nch W=0.5u L=0.18u
Mp809 s809 s808 vdd vdd pch W=1u L=0.18u
Cl809 s809 0 10f
Mn810 s810 s809 0 0 nch W=0.5u L=0.18u
Mp810 s810 s809 vdd vdd pch W=1u L=0.18u
Cl810 s810 0 10f
Mn811 s811 s810 0 0 nch W=0.5u L=0.18u
Mp811 s811 s810 vdd vdd pch W=1u L=0.18u
Cl811 s811 0 10f
Mn812 s812 s811 0 0 nch W=0.5u L=0.18u
Mp812 s812 s811 vdd vdd pch W=1u L=0.18u
Cl812 s812 0 10f
Mn813 s813 s812 0 0 nch W=0.5u L=0.18u
Mp813 s813 s812 vdd vdd pch W=1u L=0.18u
Cl813 s813 0 10f
Mn814 s814 s813 0 0 nch W=0.5u L=0.18u
Mp814 s814 s813 vdd vdd pch W=1u L=0.18u
Cl814 s814 0 10f
Mn815 s815 s814 0 0 nch W=0.5u L=0.18u
Mp815 s815 s814 vdd vdd pch W=1u L=0.18u
Cl815 s815 0 10f
Mn816 s816 s815 0 0 nch W=0.5u L=0.18u
Mp816 s816 s815 vdd vdd pch W=1u L=0.18u
Cl816 s816 0 10f
Mn817 s817 s816 0 0 nch W=0.5u L=0.18u
Mp817 s817 s816 vdd vdd pch W=1u L=0.18u
Cl817 s817 0 10f
Mn818 s818 s817 0 0 nch W=0.5u L=0.18u
Mp818 s818 s817 vdd vdd pch W=1u L=0.18u
Cl818 s818 0 10f
Mn819 s819 s818 0 0 nch W=0.5u L=0.18u
Mp819 s819 s818 vdd vdd pch W=1u L=0.18u
Cl819 s819 0 10f
Mn820 s820 s819 0 0 nch W=0.5u L=0.18u
Mp820 s820 s819 vdd vdd pch W=1u L=0.18u
Cl820 s820 0 10f
Mn821 s821 s820 0 0 nch W=0.5u L=0.18u
Mp821 s821 s820 vdd vdd pch W=1u L=0.18u
Cl821 s821 0 10f
Mn822 s822 s821 0 0 nch W=0.5u L=0.18u
Mp822 s822 s821 vdd vdd pch W=1u L=0.18u
Cl822 s822 0 10f
Mn823 s823 s822 0 0 nch W=0.5u L=0.18u
Mp823 s823 s822 vdd vdd pch W=1u L=0.18u
Cl823 s823 0 10f
Mn824 s824 s823 0 0 nch W=0.5u L=0.18u
Mp824 s824 s823 vdd vdd pch W=1u L=0.18u
Cl824 s824 0 10f
Mn825 s825 s824 0 0 nch W=0.5u L=0.18u
Mp825 s825 s824 vdd vdd pch W=1u L=0.18u
Cl825 s825 0 10f
Mn826 s826 s825 0 0 nch W=0.5u L=0.18u
Mp826 s826 s825 vdd vdd pch W=1u L=0.18u
Cl826 s826 0 10f
Mn827 s827 s826 0 0 nch W=0.5u L=0.18u
Mp827 s827 s826 vdd vdd pch W=1u L=0.18u
Cl827 s827 0 10f
Mn828 s828 s827 0 0 nch W=0.5u L=0.18u
Mp828 s828 s827 vdd vdd pch W=1u L=0.18u
Cl828 s828 0 10f
Mn829 s829 s828 0 0 nch W=0.5u L=0.18u
Mp829 s829 s828 vdd vdd pch W=1u L=0.18u
Cl829 s829 0 10f
Mn830 s830 s829 0 0 nch W=0.5u L=0.18u
Mp830 s830 s829 vdd vdd pch W=1u L=0.18u
Cl830 s830 0 10f
Mn831 s831 s830 0 0 nch W=0.5u L=0.18u
Mp831 s831 s830 vdd vdd pch W=1u L=0.18u
Cl831 s831 0 10f
Mn832 s832 s831 0 0 nch W=0.5u L=0.18u
Mp832 s832 s831 vdd vdd pch W=1u L=0.18u
Cl832 s832 0 10f
Mn833 s833 s832 0 0 nch W=0.5u L=0.18u
Mp833 s833 s832 vdd vdd pch W=1u L=0.18u
Cl833 s833 0 10f
Mn834 s834 s833 0 0 nch W=0.5u L=0.18u
Mp834 s834 s833 vdd vdd pch W=1u L=0.18u
Cl834 s834 0 10f
Mn835 s835 s834 0 0 nch W=0.5u L=0.18u
Mp835 s835 s834 vdd vdd pch W=1u L=0.18u
Cl835 s835 0 10f
Mn836 s836 s835 0 0 nch W=0.5u L=0.18u
Mp836 s836 s835 vdd vdd pch W=1u L=0.18u
Cl836 s836 0 10f
Mn837 s837 s836 0 0 nch W=0.5u L=0.18u
Mp837 s837 s836 vdd vdd pch W=1u L=0.18u
Cl837 s837 0 10f
Mn838 s838 s837 0 0 nch W=0.5u L=0.18u
Mp838 s838 s837 vdd vdd pch W=1u L=0.18u
Cl838 s838 0 10f
Mn839 s839 s838 0 0 nch W=0.5u L=0.18u
Mp839 s839 s838 vdd vdd pch W=1u L=0.18u
Cl839 s839 0 10f
Mn840 s840 s839 0 0 nch W=0.5u L=0.18u
Mp840 s840 s839 vdd vdd pch W=1u L=0.18u
Cl840 s840 0 10f
Mn841 s841 s840 0 0 nch W=0.5u L=0.18u
Mp841 s841 s840 vdd vdd pch W=1u L=0.18u
Cl841 s841 0 10f
Mn842 s842 s841 0 0 nch W=0.5u L=0.18u
Mp842 s842 s841 vdd vdd pch W=1u L=0.18u
Cl842 s842 0 10f
Mn843 s843 s842 0 0 nch W=0.5u L=0.18u
Mp843 s843 s842 vdd vdd pch W=1u L=0.18u
Cl843 s843 0 10f
Mn844 s844 s843 0 0 nch W=0.5u L=0.18u
Mp844 s844 s843 vdd vdd pch W=1u L=0.18u
Cl844 s844 0 10f
Mn845 s845 s844 0 0 nch W=0.5u L=0.18u
Mp845 s845 s844 vdd vdd pch W=1u L=0.18u
Cl845 s845 0 10f
Mn846 s846 s845 0 0 nch W=0.5u L=0.18u
Mp846 s846 s845 vdd vdd pch W=1u L=0.18u
Cl846 s846 0 10f
Mn847 s847 s846 0 0 nch W=0.5u L=0.18u
Mp847 s847 s846 vdd vdd pch W=1u L=0.18u
Cl847 s847 0 10f
Mn848 s848 s847 0 0 nch W=0.5u L=0.18u
Mp848 s848 s847 vdd vdd pch W=1u L=0.18u
Cl848 s848 0 10f
Mn849 s849 s848 0 0 nch W=0.5u L=0.18u
Mp849 s849 s848 vdd vdd pch W=1u L=0.18u
Cl849 s849 0 10f
Mn850 s850 s849 0 0 nch W=0.5u L=0.18u
Mp850 s850 s849 vdd vdd pch W=1u L=0.18u
Cl850 s850 0 10f
Mn851 s851 s850 0 0 nch W=0.5u L=0.18u
Mp851 s851 s850 vdd vdd pch W=1u L=0.18u
Cl851 s851 0 10f
Mn852 s852 s851 0 0 nch W=0.5u L=0.18u
Mp852 s852 s851 vdd vdd pch W=1u L=0.18u
Cl852 s852 0 10f
Mn853 s853 s852 0 0 nch W=0.5u L=0.18u
Mp853 s853 s852 vdd vdd pch W=1u L=0.18u
Cl853 s853 0 10f
Mn854 s854 s853 0 0 nch W=0.5u L=0.18u
Mp854 s854 s853 vdd vdd pch W=1u L=0.18u
Cl854 s854 0 10f
Mn855 s855 s854 0 0 nch W=0.5u L=0.18u
Mp855 s855 s854 vdd vdd pch W=1u L=0.18u
Cl855 s855 0 10f
Mn856 s856 s855 0 0 nch W=0.5u L=0.18u
Mp856 s856 s855 vdd vdd pch W=1u L=0.18u
Cl856 s856 0 10f
Mn857 s857 s856 0 0 nch W=0.5u L=0.18u
Mp857 s857 s856 vdd vdd pch W=1u L=0.18u
Cl857 s857 0 10f
Mn858 s858 s857 0 0 nch W=0.5u L=0.18u
Mp858 s858 s857 vdd vdd pch W=1u L=0.18u
Cl858 s858 0 10f
Mn859 s859 s858 0 0 nch W=0.5u L=0.18u
Mp859 s859 s858 vdd vdd pch W=1u L=0.18u
Cl859 s859 0 10f
Mn860 s860 s859 0 0 nch W=0.5u L=0.18u
Mp860 s860 s859 vdd vdd pch W=1u L=0.18u
Cl860 s860 0 10f
Mn861 s861 s860 0 0 nch W=0.5u L=0.18u
Mp861 s861 s860 vdd vdd pch W=1u L=0.18u
Cl861 s861 0 10f
Mn862 s862 s861 0 0 nch W=0.5u L=0.18u
Mp862 s862 s861 vdd vdd pch W=1u L=0.18u
Cl862 s862 0 10f
Mn863 s863 s862 0 0 nch W=0.5u L=0.18u
Mp863 s863 s862 vdd vdd pch W=1u L=0.18u
Cl863 s863 0 10f
Mn864 s864 s863 0 0 nch W=0.5u L=0.18u
Mp864 s864 s863 vdd vdd pch W=1u L=0.18u
Cl864 s864 0 10f
Mn865 s865 s864 0 0 nch W=0.5u L=0.18u
Mp865 s865 s864 vdd vdd pch W=1u L=0.18u
Cl865 s865 0 10f
Mn866 s866 s865 0 0 nch W=0.5u L=0.18u
Mp866 s866 s865 vdd vdd pch W=1u L=0.18u
Cl866 s866 0 10f
Mn867 s867 s866 0 0 nch W=0.5u L=0.18u
Mp867 s867 s866 vdd vdd pch W=1u L=0.18u
Cl867 s867 0 10f
Mn868 s868 s867 0 0 nch W=0.5u L=0.18u
Mp868 s868 s867 vdd vdd pch W=1u L=0.18u
Cl868 s868 0 10f
Mn869 s869 s868 0 0 nch W=0.5u L=0.18u
Mp869 s869 s868 vdd vdd pch W=1u L=0.18u
Cl869 s869 0 10f
Mn870 s870 s869 0 0 nch W=0.5u L=0.18u
Mp870 s870 s869 vdd vdd pch W=1u L=0.18u
Cl870 s870 0 10f
Mn871 s871 s870 0 0 nch W=0.5u L=0.18u
Mp871 s871 s870 vdd vdd pch W=1u L=0.18u
Cl871 s871 0 10f
Mn872 s872 s871 0 0 nch W=0.5u L=0.18u
Mp872 s872 s871 vdd vdd pch W=1u L=0.18u
Cl872 s872 0 10f
Mn873 s873 s872 0 0 nch W=0.5u L=0.18u
Mp873 s873 s872 vdd vdd pch W=1u L=0.18u
Cl873 s873 0 10f
Mn874 s874 s873 0 0 nch W=0.5u L=0.18u
Mp874 s874 s873 vdd vdd pch W=1u L=0.18u
Cl874 s874 0 10f
Mn875 s875 s874 0 0 nch W=0.5u L=0.18u
Mp875 s875 s874 vdd vdd pch W=1u L=0.18u
Cl875 s875 0 10f
Mn876 s876 s875 0 0 nch W=0.5u L=0.18u
Mp876 s876 s875 vdd vdd pch W=1u L=0.18u
Cl876 s876 0 10f
Mn877 s877 s876 0 0 nch W=0.5u L=0.18u
Mp877 s877 s876 vdd vdd pch W=1u L=0.18u
Cl877 s877 0 10f
Mn878 s878 s877 0 0 nch W=0.5u L=0.18u
Mp878 s878 s877 vdd vdd pch W=1u L=0.18u
Cl878 s878 0 10f
Mn879 s879 s878 0 0 nch W=0.5u L=0.18u
Mp879 s879 s878 vdd vdd pch W=1u L=0.18u
Cl879 s879 0 10f
Mn880 s880 s879 0 0 nch W=0.5u L=0.18u
Mp880 s880 s879 vdd vdd pch W=1u L=0.18u
Cl880 s880 0 10f
Mn881 s881 s880 0 0 nch W=0.5u L=0.18u
Mp881 s881 s880 vdd vdd pch W=1u L=0.18u
Cl881 s881 0 10f
Mn882 s882 s881 0 0 nch W=0.5u L=0.18u
Mp882 s882 s881 vdd vdd pch W=1u L=0.18u
Cl882 s882 0 10f
Mn883 s883 s882 0 0 nch W=0.5u L=0.18u
Mp883 s883 s882 vdd vdd pch W=1u L=0.18u
Cl883 s883 0 10f
Mn884 s884 s883 0 0 nch W=0.5u L=0.18u
Mp884 s884 s883 vdd vdd pch W=1u L=0.18u
Cl884 s884 0 10f
Mn885 s885 s884 0 0 nch W=0.5u L=0.18u
Mp885 s885 s884 vdd vdd pch W=1u L=0.18u
Cl885 s885 0 10f
Mn886 s886 s885 0 0 nch W=0.5u L=0.18u
Mp886 s886 s885 vdd vdd pch W=1u L=0.18u
Cl886 s886 0 10f
Mn887 s887 s886 0 0 nch W=0.5u L=0.18u
Mp887 s887 s886 vdd vdd pch W=1u L=0.18u
Cl887 s887 0 10f
Mn888 s888 s887 0 0 nch W=0.5u L=0.18u
Mp888 s888 s887 vdd vdd pch W=1u L=0.18u
Cl888 s888 0 10f
Mn889 s889 s888 0 0 nch W=0.5u L=0.18u
Mp889 s889 s888 vdd vdd pch W=1u L=0.18u
Cl889 s889 0 10f
Mn890 s890 s889 0 0 nch W=0.5u L=0.18u
Mp890 s890 s889 vdd vdd pch W=1u L=0.18u
Cl890 s890 0 10f
Mn891 s891 s890 0 0 nch W=0.5u L=0.18u
Mp891 s891 s890 vdd vdd pch W=1u L=0.18u
Cl891 s891 0 10f
Mn892 s892 s891 0 0 nch W=0.5u L=0.18u
Mp892 s892 s891 vdd vdd pch W=1u L=0.18u
Cl892 s892 0 10f
Mn893 s893 s892 0 0 nch W=0.5u L=0.18u
Mp893 s893 s892 vdd vdd pch W=1u L=0.18u
Cl893 s893 0 10f
Mn894 s894 s893 0 0 nch W=0.5u L=0.18u
Mp894 s894 s893 vdd vdd pch W=1u L=0.18u
Cl894 s894 0 10f
Mn895 s895 s894 0 0 nch W=0.5u L=0.18u
Mp895 s895 s894 vdd vdd pch W=1u L=0.18u
Cl895 s895 0 10f
Mn896 s896 s895 0 0 nch W=0.5u L=0.18u
Mp896 s896 s895 vdd vdd pch W=1u L=0.18u
Cl896 s896 0 10f
Mn897 s897 s896 0 0 nch W=0.5u L=0.18u
Mp897 s897 s896 vdd vdd pch W=1u L=0.18u
Cl897 s897 0 10f
Mn898 s898 s897 0 0 nch W=0.5u L=0.18u
Mp898 s898 s897 vdd vdd pch W=1u L=0.18u
Cl898 s898 0 10f
Mn899 s899 s898 0 0 nch W=0.5u L=0.18u
Mp899 s899 s898 vdd vdd pch W=1u L=0.18u
Cl899 s899 0 10f
Mn900 s900 s899 0 0 nch W=0.5u L=0.18u
Mp900 s900 s899 vdd vdd pch W=1u L=0.18u
Cl900 s900 0 10f
Mn901 s901 s900 0 0 nch W=0.5u L=0.18u
Mp901 s901 s900 vdd vdd pch W=1u L=0.18u
Cl901 s901 0 10f
Mn902 s902 s901 0 0 nch W=0.5u L=0.18u
Mp902 s902 s901 vdd vdd pch W=1u L=0.18u
Cl902 s902 0 10f
Mn903 s903 s902 0 0 nch W=0.5u L=0.18u
Mp903 s903 s902 vdd vdd pch W=1u L=0.18u
Cl903 s903 0 10f
Mn904 s904 s903 0 0 nch W=0.5u L=0.18u
Mp904 s904 s903 vdd vdd pch W=1u L=0.18u
Cl904 s904 0 10f
Mn905 s905 s904 0 0 nch W=0.5u L=0.18u
Mp905 s905 s904 vdd vdd pch W=1u L=0.18u
Cl905 s905 0 10f
Mn906 s906 s905 0 0 nch W=0.5u L=0.18u
Mp906 s906 s905 vdd vdd pch W=1u L=0.18u
Cl906 s906 0 10f
Mn907 s907 s906 0 0 nch W=0.5u L=0.18u
Mp907 s907 s906 vdd vdd pch W=1u L=0.18u
Cl907 s907 0 10f
Mn908 s908 s907 0 0 nch W=0.5u L=0.18u
Mp908 s908 s907 vdd vdd pch W=1u L=0.18u
Cl908 s908 0 10f
Mn909 s909 s908 0 0 nch W=0.5u L=0.18u
Mp909 s909 s908 vdd vdd pch W=1u L=0.18u
Cl909 s909 0 10f
Mn910 s910 s909 0 0 nch W=0.5u L=0.18u
Mp910 s910 s909 vdd vdd pch W=1u L=0.18u
Cl910 s910 0 10f
Mn911 s911 s910 0 0 nch W=0.5u L=0.18u
Mp911 s911 s910 vdd vdd pch W=1u L=0.18u
Cl911 s911 0 10f
Mn912 s912 s911 0 0 nch W=0.5u L=0.18u
Mp912 s912 s911 vdd vdd pch W=1u L=0.18u
Cl912 s912 0 10f
Mn913 s913 s912 0 0 nch W=0.5u L=0.18u
Mp913 s913 s912 vdd vdd pch W=1u L=0.18u
Cl913 s913 0 10f
Mn914 s914 s913 0 0 nch W=0.5u L=0.18u
Mp914 s914 s913 vdd vdd pch W=1u L=0.18u
Cl914 s914 0 10f
Mn915 s915 s914 0 0 nch W=0.5u L=0.18u
Mp915 s915 s914 vdd vdd pch W=1u L=0.18u
Cl915 s915 0 10f
Mn916 s916 s915 0 0 nch W=0.5u L=0.18u
Mp916 s916 s915 vdd vdd pch W=1u L=0.18u
Cl916 s916 0 10f
Mn917 s917 s916 0 0 nch W=0.5u L=0.18u
Mp917 s917 s916 vdd vdd pch W=1u L=0.18u
Cl917 s917 0 10f
Mn918 s918 s917 0 0 nch W=0.5u L=0.18u
Mp918 s918 s917 vdd vdd pch W=1u L=0.18u
Cl918 s918 0 10f
Mn919 s919 s918 0 0 nch W=0.5u L=0.18u
Mp919 s919 s918 vdd vdd pch W=1u L=0.18u
Cl919 s919 0 10f
Mn920 s920 s919 0 0 nch W=0.5u L=0.18u
Mp920 s920 s919 vdd vdd pch W=1u L=0.18u
Cl920 s920 0 10f
Mn921 s921 s920 0 0 nch W=0.5u L=0.18u
Mp921 s921 s920 vdd vdd pch W=1u L=0.18u
Cl921 s921 0 10f
Mn922 s922 s921 0 0 nch W=0.5u L=0.18u
Mp922 s922 s921 vdd vdd pch W=1u L=0.18u
Cl922 s922 0 10f
Mn923 s923 s922 0 0 nch W=0.5u L=0.18u
Mp923 s923 s922 vdd vdd pch W=1u L=0.18u
Cl923 s923 0 10f
Mn924 s924 s923 0 0 nch W=0.5u L=0.18u
Mp924 s924 s923 vdd vdd pch W=1u L=0.18u
Cl924 s924 0 10f
Mn925 s925 s924 0 0 nch W=0.5u L=0.18u
Mp925 s925 s924 vdd vdd pch W=1u L=0.18u
Cl925 s925 0 10f
Mn926 s926 s925 0 0 nch W=0.5u L=0.18u
Mp926 s926 s925 vdd vdd pch W=1u L=0.18u
Cl926 s926 0 10f
Mn927 s927 s926 0 0 nch W=0.5u L=0.18u
Mp927 s927 s926 vdd vdd pch W=1u L=0.18u
Cl927 s927 0 10f
Mn928 s928 s927 0 0 nch W=0.5u L=0.18u
Mp928 s928 s927 vdd vdd pch W=1u L=0.18u
Cl928 s928 0 10f
Mn929 s929 s928 0 0 nch W=0.5u L=0.18u
Mp929 s929 s928 vdd vdd pch W=1u L=0.18u
Cl929 s929 0 10f
Mn930 s930 s929 0 0 nch W=0.5u L=0.18u
Mp930 s930 s929 vdd vdd pch W=1u L=0.18u
Cl930 s930 0 10f
Mn931 s931 s930 0 0 nch W=0.5u L=0.18u
Mp931 s931 s930 vdd vdd pch W=1u L=0.18u
Cl931 s931 0 10f
Mn932 s932 s931 0 0 nch W=0.5u L=0.18u
Mp932 s932 s931 vdd vdd pch W=1u L=0.18u
Cl932 s932 0 10f
Mn933 s933 s932 0 0 nch W=0.5u L=0.18u
Mp933 s933 s932 vdd vdd pch W=1u L=0.18u
Cl933 s933 0 10f
Mn934 s934 s933 0 0 nch W=0.5u L=0.18u
Mp934 s934 s933 vdd vdd pch W=1u L=0.18u
Cl934 s934 0 10f
Mn935 s935 s934 0 0 nch W=0.5u L=0.18u
Mp935 s935 s934 vdd vdd pch W=1u L=0.18u
Cl935 s935 0 10f
Mn936 s936 s935 0 0 nch W=0.5u L=0.18u
Mp936 s936 s935 vdd vdd pch W=1u L=0.18u
Cl936 s936 0 10f
Mn937 s937 s936 0 0 nch W=0.5u L=0.18u
Mp937 s937 s936 vdd vdd pch W=1u L=0.18u
Cl937 s937 0 10f
Mn938 s938 s937 0 0 nch W=0.5u L=0.18u
Mp938 s938 s937 vdd vdd pch W=1u L=0.18u
Cl938 s938 0 10f
Mn939 s939 s938 0 0 nch W=0.5u L=0.18u
Mp939 s939 s938 vdd vdd pch W=1u L=0.18u
Cl939 s939 0 10f
Mn940 s940 s939 0 0 nch W=0.5u L=0.18u
Mp940 s940 s939 vdd vdd pch W=1u L=0.18u
Cl940 s940 0 10f
Mn941 s941 s940 0 0 nch W=0.5u L=0.18u
Mp941 s941 s940 vdd vdd pch W=1u L=0.18u
Cl941 s941 0 10f
Mn942 s942 s941 0 0 nch W=0.5u L=0.18u
Mp942 s942 s941 vdd vdd pch W=1u L=0.18u
Cl942 s942 0 10f
Mn943 s943 s942 0 0 nch W=0.5u L=0.18u
Mp943 s943 s942 vdd vdd pch W=1u L=0.18u
Cl943 s943 0 10f
Mn944 s944 s943 0 0 nch W=0.5u L=0.18u
Mp944 s944 s943 vdd vdd pch W=1u L=0.18u
Cl944 s944 0 10f
Mn945 s945 s944 0 0 nch W=0.5u L=0.18u
Mp945 s945 s944 vdd vdd pch W=1u L=0.18u
Cl945 s945 0 10f
Mn946 s946 s945 0 0 nch W=0.5u L=0.18u
Mp946 s946 s945 vdd vdd pch W=1u L=0.18u
Cl946 s946 0 10f
Mn947 s947 s946 0 0 nch W=0.5u L=0.18u
Mp947 s947 s946 vdd vdd pch W=1u L=0.18u
Cl947 s947 0 10f
Mn948 s948 s947 0 0 nch W=0.5u L=0.18u
Mp948 s948 s947 vdd vdd pch W=1u L=0.18u
Cl948 s948 0 10f
Mn949 s949 s948 0 0 nch W=0.5u L=0.18u
Mp949 s949 s948 vdd vdd pch W=1u L=0.18u
Cl949 s949 0 10f
Mn950 s950 s949 0 0 nch W=0.5u L=0.18u
Mp950 s950 s949 vdd vdd pch W=1u L=0.18u
Cl950 s950 0 10f
Mn951 s951 s950 0 0 nch W=0.5u L=0.18u
Mp951 s951 s950 vdd vdd pch W=1u L=0.18u
Cl951 s951 0 10f
Mn952 s952 s951 0 0 nch W=0.5u L=0.18u
Mp952 s952 s951 vdd vdd pch W=1u L=0.18u
Cl952 s952 0 10f
Mn953 s953 s952 0 0 nch W=0.5u L=0.18u
Mp953 s953 s952 vdd vdd pch W=1u L=0.18u
Cl953 s953 0 10f
Mn954 s954 s953 0 0 nch W=0.5u L=0.18u
Mp954 s954 s953 vdd vdd pch W=1u L=0.18u
Cl954 s954 0 10f
Mn955 s955 s954 0 0 nch W=0.5u L=0.18u
Mp955 s955 s954 vdd vdd pch W=1u L=0.18u
Cl955 s955 0 10f
Mn956 s956 s955 0 0 nch W=0.5u L=0.18u
Mp956 s956 s955 vdd vdd pch W=1u L=0.18u
Cl956 s956 0 10f
Mn957 s957 s956 0 0 nch W=0.5u L=0.18u
Mp957 s957 s956 vdd vdd pch W=1u L=0.18u
Cl957 s957 0 10f
Mn958 s958 s957 0 0 nch W=0.5u L=0.18u
Mp958 s958 s957 vdd vdd pch W=1u L=0.18u
Cl958 s958 0 10f
Mn959 s959 s958 0 0 nch W=0.5u L=0.18u
Mp959 s959 s958 vdd vdd pch W=1u L=0.18u
Cl959 s959 0 10f
Mn960 s960 s959 0 0 nch W=0.5u L=0.18u
Mp960 s960 s959 vdd vdd pch W=1u L=0.18u
Cl960 s960 0 10f
Mn961 s961 s960 0 0 nch W=0.5u L=0.18u
Mp961 s961 s960 vdd vdd pch W=1u L=0.18u
Cl961 s961 0 10f
Mn962 s962 s961 0 0 nch W=0.5u L=0.18u
Mp962 s962 s961 vdd vdd pch W=1u L=0.18u
Cl962 s962 0 10f
Mn963 s963 s962 0 0 nch W=0.5u L=0.18u
Mp963 s963 s962 vdd vdd pch W=1u L=0.18u
Cl963 s963 0 10f
Mn964 s964 s963 0 0 nch W=0.5u L=0.18u
Mp964 s964 s963 vdd vdd pch W=1u L=0.18u
Cl964 s964 0 10f
Mn965 s965 s964 0 0 nch W=0.5u L=0.18u
Mp965 s965 s964 vdd vdd pch W=1u L=0.18u
Cl965 s965 0 10f
Mn966 s966 s965 0 0 nch W=0.5u L=0.18u
Mp966 s966 s965 vdd vdd pch W=1u L=0.18u
Cl966 s966 0 10f
Mn967 s967 s966 0 0 nch W=0.5u L=0.18u
Mp967 s967 s966 vdd vdd pch W=1u L=0.18u
Cl967 s967 0 10f
Mn968 s968 s967 0 0 nch W=0.5u L=0.18u
Mp968 s968 s967 vdd vdd pch W=1u L=0.18u
Cl968 s968 0 10f
Mn969 s969 s968 0 0 nch W=0.5u L=0.18u
Mp969 s969 s968 vdd vdd pch W=1u L=0.18u
Cl969 s969 0 10f
Mn970 s970 s969 0 0 nch W=0.5u L=0.18u
Mp970 s970 s969 vdd vdd pch W=1u L=0.18u
Cl970 s970 0 10f
Mn971 s971 s970 0 0 nch W=0.5u L=0.18u
Mp971 s971 s970 vdd vdd pch W=1u L=0.18u
Cl971 s971 0 10f
Mn972 s972 s971 0 0 nch W=0.5u L=0.18u
Mp972 s972 s971 vdd vdd pch W=1u L=0.18u
Cl972 s972 0 10f
Mn973 s973 s972 0 0 nch W=0.5u L=0.18u
Mp973 s973 s972 vdd vdd pch W=1u L=0.18u
Cl973 s973 0 10f
Mn974 s974 s973 0 0 nch W=0.5u L=0.18u
Mp974 s974 s973 vdd vdd pch W=1u L=0.18u
Cl974 s974 0 10f
Mn975 s975 s974 0 0 nch W=0.5u L=0.18u
Mp975 s975 s974 vdd vdd pch W=1u L=0.18u
Cl975 s975 0 10f
Mn976 s976 s975 0 0 nch W=0.5u L=0.18u
Mp976 s976 s975 vdd vdd pch W=1u L=0.18u
Cl976 s976 0 10f
Mn977 s977 s976 0 0 nch W=0.5u L=0.18u
Mp977 s977 s976 vdd vdd pch W=1u L=0.18u
Cl977 s977 0 10f
Mn978 s978 s977 0 0 nch W=0.5u L=0.18u
Mp978 s978 s977 vdd vdd pch W=1u L=0.18u
Cl978 s978 0 10f
Mn979 s979 s978 0 0 nch W=0.5u L=0.18u
Mp979 s979 s978 vdd vdd pch W=1u L=0.18u
Cl979 s979 0 10f
Mn980 s980 s979 0 0 nch W=0.5u L=0.18u
Mp980 s980 s979 vdd vdd pch W=1u L=0.18u
Cl980 s980 0 10f
Mn981 s981 s980 0 0 nch W=0.5u L=0.18u
Mp981 s981 s980 vdd vdd pch W=1u L=0.18u
Cl981 s981 0 10f
Mn982 s982 s981 0 0 nch W=0.5u L=0.18u
Mp982 s982 s981 vdd vdd pch W=1u L=0.18u
Cl982 s982 0 10f
Mn983 s983 s982 0 0 nch W=0.5u L=0.18u
Mp983 s983 s982 vdd vdd pch W=1u L=0.18u
Cl983 s983 0 10f
Mn984 s984 s983 0 0 nch W=0.5u L=0.18u
Mp984 s984 s983 vdd vdd pch W=1u L=0.18u
Cl984 s984 0 10f
Mn985 s985 s984 0 0 nch W=0.5u L=0.18u
Mp985 s985 s984 vdd vdd pch W=1u L=0.18u
Cl985 s985 0 10f
Mn986 s986 s985 0 0 nch W=0.5u L=0.18u
Mp986 s986 s985 vdd vdd pch W=1u L=0.18u
Cl986 s986 0 10f
Mn987 s987 s986 0 0 nch W=0.5u L=0.18u
Mp987 s987 s986 vdd vdd pch W=1u L=0.18u
Cl987 s987 0 10f
Mn988 s988 s987 0 0 nch W=0.5u L=0.18u
Mp988 s988 s987 vdd vdd pch W=1u L=0.18u
Cl988 s988 0 10f
Mn989 s989 s988 0 0 nch W=0.5u L=0.18u
Mp989 s989 s988 vdd vdd pch W=1u L=0.18u
Cl989 s989 0 10f
Mn990 s990 s989 0 0 nch W=0.5u L=0.18u
Mp990 s990 s989 vdd vdd pch W=1u L=0.18u
Cl990 s990 0 10f
Mn991 s991 s990 0 0 nch W=0.5u L=0.18u
Mp991 s991 s990 vdd vdd pch W=1u L=0.18u
Cl991 s991 0 10f
Mn992 s992 s991 0 0 nch W=0.5u L=0.18u
Mp992 s992 s991 vdd vdd pch W=1u L=0.18u
Cl992 s992 0 10f
Mn993 s993 s992 0 0 nch W=0.5u L=0.18u
Mp993 s993 s992 vdd vdd pch W=1u L=0.18u
Cl993 s993 0 10f
Mn994 s994 s993 0 0 nch W=0.5u L=0.18u
Mp994 s994 s993 vdd vdd pch W=1u L=0.18u
Cl994 s994 0 10f
Mn995 s995 s994 0 0 nch W=0.5u L=0.18u
Mp995 s995 s994 vdd vdd pch W=1u L=0.18u
Cl995 s995 0 10f
Mn996 s996 s995 0 0 nch W=0.5u L=0.18u
Mp996 s996 s995 vdd vdd pch W=1u L=0.18u
Cl996 s996 0 10f
Mn997 s997 s996 0 0 nch W=0.5u L=0.18u
Mp997 s997 s996 vdd vdd pch W=1u L=0.18u
Cl997 s997 0 10f
Mn998 s998 s997 0 0 nch W=0.5u L=0.18u
Mp998 s998 s997 vdd vdd pch W=1u L=0.18u
Cl998 s998 0 10f
Mn999 s999 s998 0 0 nch W=0.5u L=0.18u
Mp999 s999 s998 vdd vdd pch W=1u L=0.18u
Cl999 s999 0 10f
Mn1000 s1000 s999 0 0 nch W=0.5u L=0.18u
Mp1000 s1000 s999 vdd vdd pch W=1u L=0.18u
Cl1000 s1000 0 10f
Mn1001 s1001 s1000 0 0 nch W=0.5u L=0.18u
Mp1001 s1001 s1000 vdd vdd pch W=1u L=0.18u
Cl1001 s1001 0 10f
Mn1002 s1002 s1001 0 0 nch W=0.5u L=0.18u
Mp1002 s1002 s1001 vdd vdd pch W=1u L=0.18u
Cl1002 s1002 0 10f
Mn1003 s1003 s1002 0 0 nch W=0.5u L=0.18u
Mp1003 s1003 s1002 vdd vdd pch W=1u L=0.18u
Cl1003 s1003 0 10f
Mn1004 s1004 s1003 0 0 nch W=0.5u L=0.18u
Mp1004 s1004 s1003 vdd vdd pch W=1u L=0.18u
Cl1004 s1004 0 10f
Mn1005 s1005 s1004 0 0 nch W=0.5u L=0.18u
Mp1005 s1005 s1004 vdd vdd pch W=1u L=0.18u
Cl1005 s1005 0 10f
Mn1006 s1006 s1005 0 0 nch W=0.5u L=0.18u
Mp1006 s1006 s1005 vdd vdd pch W=1u L=0.18u
Cl1006 s1006 0 10f
Mn1007 s1007 s1006 0 0 nch W=0.5u L=0.18u
Mp1007 s1007 s1006 vdd vdd pch W=1u L=0.18u
Cl1007 s1007 0 10f
Mn1008 s1008 s1007 0 0 nch W=0.5u L=0.18u
Mp1008 s1008 s1007 vdd vdd pch W=1u L=0.18u
Cl1008 s1008 0 10f
Mn1009 s1009 s1008 0 0 nch W=0.5u L=0.18u
Mp1009 s1009 s1008 vdd vdd pch W=1u L=0.18u
Cl1009 s1009 0 10f
Mn1010 s1010 s1009 0 0 nch W=0.5u L=0.18u
Mp1010 s1010 s1009 vdd vdd pch W=1u L=0.18u
Cl1010 s1010 0 10f
Mn1011 s1011 s1010 0 0 nch W=0.5u L=0.18u
Mp1011 s1011 s1010 vdd vdd pch W=1u L=0.18u
Cl1011 s1011 0 10f
Mn1012 s1012 s1011 0 0 nch W=0.5u L=0.18u
Mp1012 s1012 s1011 vdd vdd pch W=1u L=0.18u
Cl1012 s1012 0 10f
Mn1013 s1013 s1012 0 0 nch W=0.5u L=0.18u
Mp1013 s1013 s1012 vdd vdd pch W=1u L=0.18u
Cl1013 s1013 0 10f
Mn1014 s1014 s1013 0 0 nch W=0.5u L=0.18u
Mp1014 s1014 s1013 vdd vdd pch W=1u L=0.18u
Cl1014 s1014 0 10f
Mn1015 s1015 s1014 0 0 nch W=0.5u L=0.18u
Mp1015 s1015 s1014 vdd vdd pch W=1u L=0.18u
Cl1015 s1015 0 10f
Mn1016 s1016 s1015 0 0 nch W=0.5u L=0.18u
Mp1016 s1016 s1015 vdd vdd pch W=1u L=0.18u
Cl1016 s1016 0 10f
Mn1017 s1017 s1016 0 0 nch W=0.5u L=0.18u
Mp1017 s1017 s1016 vdd vdd pch W=1u L=0.18u
Cl1017 s1017 0 10f
Mn1018 s1018 s1017 0 0 nch W=0.5u L=0.18u
Mp1018 s1018 s1017 vdd vdd pch W=1u L=0.18u
Cl1018 s1018 0 10f
Mn1019 s1019 s1018 0 0 nch W=0.5u L=0.18u
Mp1019 s1019 s1018 vdd vdd pch W=1u L=0.18u
Cl1019 s1019 0 10f
Mn1020 s1020 s1019 0 0 nch W=0.5u L=0.18u
Mp1020 s1020 s1019 vdd vdd pch W=1u L=0.18u
Cl1020 s1020 0 10f
Mn1021 s1021 s1020 0 0 nch W=0.5u L=0.18u
Mp1021 s1021 s1020 vdd vdd pch W=1u L=0.18u
Cl1021 s1021 0 10f
Mn1022 s1022 s1021 0 0 nch W=0.5u L=0.18u
Mp1022 s1022 s1021 vdd vdd pch W=1u L=0.18u
Cl1022 s1022 0 10f
Mn1023 s1023 s1022 0 0 nch W=0.5u L=0.18u
Mp1023 s1023 s1022 vdd vdd pch W=1u L=0.18u
Cl1023 s1023 0 10f
Mn1024 s1024 s1023 0 0 nch W=0.5u L=0.18u
Mp1024 s1024 s1023 vdd vdd pch W=1u L=0.18u
Cl1024 s1024 0 10f
Mn1025 s1025 s1024 0 0 nch W=0.5u L=0.18u
Mp1025 s1025 s1024 vdd vdd pch W=1u L=0.18u
Cl1025 s1025 0 10f
Mn1026 s1026 s1025 0 0 nch W=0.5u L=0.18u
Mp1026 s1026 s1025 vdd vdd pch W=1u L=0.18u
Cl1026 s1026 0 10f
Mn1027 s1027 s1026 0 0 nch W=0.5u L=0.18u
Mp1027 s1027 s1026 vdd vdd pch W=1u L=0.18u
Cl1027 s1027 0 10f
Mn1028 s1028 s1027 0 0 nch W=0.5u L=0.18u
Mp1028 s1028 s1027 vdd vdd pch W=1u L=0.18u
Cl1028 s1028 0 10f
Mn1029 s1029 s1028 0 0 nch W=0.5u L=0.18u
Mp1029 s1029 s1028 vdd vdd pch W=1u L=0.18u
Cl1029 s1029 0 10f
Mn1030 s1030 s1029 0 0 nch W=0.5u L=0.18u
Mp1030 s1030 s1029 vdd vdd pch W=1u L=0.18u
Cl1030 s1030 0 10f
Mn1031 s1031 s1030 0 0 nch W=0.5u L=0.18u
Mp1031 s1031 s1030 vdd vdd pch W=1u L=0.18u
Cl1031 s1031 0 10f
Mn1032 s1032 s1031 0 0 nch W=0.5u L=0.18u
Mp1032 s1032 s1031 vdd vdd pch W=1u L=0.18u
Cl1032 s1032 0 10f
Mn1033 s1033 s1032 0 0 nch W=0.5u L=0.18u
Mp1033 s1033 s1032 vdd vdd pch W=1u L=0.18u
Cl1033 s1033 0 10f
Mn1034 s1034 s1033 0 0 nch W=0.5u L=0.18u
Mp1034 s1034 s1033 vdd vdd pch W=1u L=0.18u
Cl1034 s1034 0 10f
Mn1035 s1035 s1034 0 0 nch W=0.5u L=0.18u
Mp1035 s1035 s1034 vdd vdd pch W=1u L=0.18u
Cl1035 s1035 0 10f
Mn1036 s1036 s1035 0 0 nch W=0.5u L=0.18u
Mp1036 s1036 s1035 vdd vdd pch W=1u L=0.18u
Cl1036 s1036 0 10f
Mn1037 s1037 s1036 0 0 nch W=0.5u L=0.18u
Mp1037 s1037 s1036 vdd vdd pch W=1u L=0.18u
Cl1037 s1037 0 10f
Mn1038 s1038 s1037 0 0 nch W=0.5u L=0.18u
Mp1038 s1038 s1037 vdd vdd pch W=1u L=0.18u
Cl1038 s1038 0 10f
Mn1039 s1039 s1038 0 0 nch W=0.5u L=0.18u
Mp1039 s1039 s1038 vdd vdd pch W=1u L=0.18u
Cl1039 s1039 0 10f
Mn1040 s1040 s1039 0 0 nch W=0.5u L=0.18u
Mp1040 s1040 s1039 vdd vdd pch W=1u L=0.18u
Cl1040 s1040 0 10f
Mn1041 s1041 s1040 0 0 nch W=0.5u L=0.18u
Mp1041 s1041 s1040 vdd vdd pch W=1u L=0.18u
Cl1041 s1041 0 10f
Mn1042 s1042 s1041 0 0 nch W=0.5u L=0.18u
Mp1042 s1042 s1041 vdd vdd pch W=1u L=0.18u
Cl1042 s1042 0 10f
Mn1043 s1043 s1042 0 0 nch W=0.5u L=0.18u
Mp1043 s1043 s1042 vdd vdd pch W=1u L=0.18u
Cl1043 s1043 0 10f
Mn1044 s1044 s1043 0 0 nch W=0.5u L=0.18u
Mp1044 s1044 s1043 vdd vdd pch W=1u L=0.18u
Cl1044 s1044 0 10f
Mn1045 s1045 s1044 0 0 nch W=0.5u L=0.18u
Mp1045 s1045 s1044 vdd vdd pch W=1u L=0.18u
Cl1045 s1045 0 10f
Mn1046 s1046 s1045 0 0 nch W=0.5u L=0.18u
Mp1046 s1046 s1045 vdd vdd pch W=1u L=0.18u
Cl1046 s1046 0 10f
Mn1047 s1047 s1046 0 0 nch W=0.5u L=0.18u
Mp1047 s1047 s1046 vdd vdd pch W=1u L=0.18u
Cl1047 s1047 0 10f
Mn1048 s1048 s1047 0 0 nch W=0.5u L=0.18u
Mp1048 s1048 s1047 vdd vdd pch W=1u L=0.18u
Cl1048 s1048 0 10f
Mn1049 s1049 s1048 0 0 nch W=0.5u L=0.18u
Mp1049 s1049 s1048 vdd vdd pch W=1u L=0.18u
Cl1049 s1049 0 10f
Mn1050 s1050 s1049 0 0 nch W=0.5u L=0.18u
Mp1050 s1050 s1049 vdd vdd pch W=1u L=0.18u
Cl1050 s1050 0 10f
Mn1051 s1051 s1050 0 0 nch W=0.5u L=0.18u
Mp1051 s1051 s1050 vdd vdd pch W=1u L=0.18u
Cl1051 s1051 0 10f
Mn1052 s1052 s1051 0 0 nch W=0.5u L=0.18u
Mp1052 s1052 s1051 vdd vdd pch W=1u L=0.18u
Cl1052 s1052 0 10f
Mn1053 s1053 s1052 0 0 nch W=0.5u L=0.18u
Mp1053 s1053 s1052 vdd vdd pch W=1u L=0.18u
Cl1053 s1053 0 10f
Mn1054 s1054 s1053 0 0 nch W=0.5u L=0.18u
Mp1054 s1054 s1053 vdd vdd pch W=1u L=0.18u
Cl1054 s1054 0 10f
Mn1055 s1055 s1054 0 0 nch W=0.5u L=0.18u
Mp1055 s1055 s1054 vdd vdd pch W=1u L=0.18u
Cl1055 s1055 0 10f
Mn1056 s1056 s1055 0 0 nch W=0.5u L=0.18u
Mp1056 s1056 s1055 vdd vdd pch W=1u L=0.18u
Cl1056 s1056 0 10f
Mn1057 s1057 s1056 0 0 nch W=0.5u L=0.18u
Mp1057 s1057 s1056 vdd vdd pch W=1u L=0.18u
Cl1057 s1057 0 10f
Mn1058 s1058 s1057 0 0 nch W=0.5u L=0.18u
Mp1058 s1058 s1057 vdd vdd pch W=1u L=0.18u
Cl1058 s1058 0 10f
Mn1059 s1059 s1058 0 0 nch W=0.5u L=0.18u
Mp1059 s1059 s1058 vdd vdd pch W=1u L=0.18u
Cl1059 s1059 0 10f
Mn1060 s1060 s1059 0 0 nch W=0.5u L=0.18u
Mp1060 s1060 s1059 vdd vdd pch W=1u L=0.18u
Cl1060 s1060 0 10f
Mn1061 s1061 s1060 0 0 nch W=0.5u L=0.18u
Mp1061 s1061 s1060 vdd vdd pch W=1u L=0.18u
Cl1061 s1061 0 10f
Mn1062 s1062 s1061 0 0 nch W=0.5u L=0.18u
Mp1062 s1062 s1061 vdd vdd pch W=1u L=0.18u
Cl1062 s1062 0 10f
Mn1063 s1063 s1062 0 0 nch W=0.5u L=0.18u
Mp1063 s1063 s1062 vdd vdd pch W=1u L=0.18u
Cl1063 s1063 0 10f
Mn1064 s1064 s1063 0 0 nch W=0.5u L=0.18u
Mp1064 s1064 s1063 vdd vdd pch W=1u L=0.18u
Cl1064 s1064 0 10f
Mn1065 s1065 s1064 0 0 nch W=0.5u L=0.18u
Mp1065 s1065 s1064 vdd vdd pch W=1u L=0.18u
Cl1065 s1065 0 10f
Mn1066 s1066 s1065 0 0 nch W=0.5u L=0.18u
Mp1066 s1066 s1065 vdd vdd pch W=1u L=0.18u
Cl1066 s1066 0 10f
Mn1067 s1067 s1066 0 0 nch W=0.5u L=0.18u
Mp1067 s1067 s1066 vdd vdd pch W=1u L=0.18u
Cl1067 s1067 0 10f
Mn1068 s1068 s1067 0 0 nch W=0.5u L=0.18u
Mp1068 s1068 s1067 vdd vdd pch W=1u L=0.18u
Cl1068 s1068 0 10f
Mn1069 s1069 s1068 0 0 nch W=0.5u L=0.18u
Mp1069 s1069 s1068 vdd vdd pch W=1u L=0.18u
Cl1069 s1069 0 10f
Mn1070 s1070 s1069 0 0 nch W=0.5u L=0.18u
Mp1070 s1070 s1069 vdd vdd pch W=1u L=0.18u
Cl1070 s1070 0 10f
Mn1071 s1071 s1070 0 0 nch W=0.5u L=0.18u
Mp1071 s1071 s1070 vdd vdd pch W=1u L=0.18u
Cl1071 s1071 0 10f
Mn1072 s1072 s1071 0 0 nch W=0.5u L=0.18u
Mp1072 s1072 s1071 vdd vdd pch W=1u L=0.18u
Cl1072 s1072 0 10f
Mn1073 s1073 s1072 0 0 nch W=0.5u L=0.18u
Mp1073 s1073 s1072 vdd vdd pch W=1u L=0.18u
Cl1073 s1073 0 10f
Mn1074 s1074 s1073 0 0 nch W=0.5u L=0.18u
Mp1074 s1074 s1073 vdd vdd pch W=1u L=0.18u
Cl1074 s1074 0 10f
Mn1075 s1075 s1074 0 0 nch W=0.5u L=0.18u
Mp1075 s1075 s1074 vdd vdd pch W=1u L=0.18u
Cl1075 s1075 0 10f
Mn1076 s1076 s1075 0 0 nch W=0.5u L=0.18u
Mp1076 s1076 s1075 vdd vdd pch W=1u L=0.18u
Cl1076 s1076 0 10f
Mn1077 s1077 s1076 0 0 nch W=0.5u L=0.18u
Mp1077 s1077 s1076 vdd vdd pch W=1u L=0.18u
Cl1077 s1077 0 10f
Mn1078 s1078 s1077 0 0 nch W=0.5u L=0.18u
Mp1078 s1078 s1077 vdd vdd pch W=1u L=0.18u
Cl1078 s1078 0 10f
Mn1079 s1079 s1078 0 0 nch W=0.5u L=0.18u
Mp1079 s1079 s1078 vdd vdd pch W=1u L=0.18u
Cl1079 s1079 0 10f
Mn1080 s1080 s1079 0 0 nch W=0.5u L=0.18u
Mp1080 s1080 s1079 vdd vdd pch W=1u L=0.18u
Cl1080 s1080 0 10f
Mn1081 s1081 s1080 0 0 nch W=0.5u L=0.18u
Mp1081 s1081 s1080 vdd vdd pch W=1u L=0.18u
Cl1081 s1081 0 10f
Mn1082 s1082 s1081 0 0 nch W=0.5u L=0.18u
Mp1082 s1082 s1081 vdd vdd pch W=1u L=0.18u
Cl1082 s1082 0 10f
Mn1083 s1083 s1082 0 0 nch W=0.5u L=0.18u
Mp1083 s1083 s1082 vdd vdd pch W=1u L=0.18u
Cl1083 s1083 0 10f
Mn1084 s1084 s1083 0 0 nch W=0.5u L=0.18u
Mp1084 s1084 s1083 vdd vdd pch W=1u L=0.18u
Cl1084 s1084 0 10f
Mn1085 s1085 s1084 0 0 nch W=0.5u L=0.18u
Mp1085 s1085 s1084 vdd vdd pch W=1u L=0.18u
Cl1085 s1085 0 10f
Mn1086 s1086 s1085 0 0 nch W=0.5u L=0.18u
Mp1086 s1086 s1085 vdd vdd pch W=1u L=0.18u
Cl1086 s1086 0 10f
Mn1087 s1087 s1086 0 0 nch W=0.5u L=0.18u
Mp1087 s1087 s1086 vdd vdd pch W=1u L=0.18u
Cl1087 s1087 0 10f
Mn1088 s1088 s1087 0 0 nch W=0.5u L=0.18u
Mp1088 s1088 s1087 vdd vdd pch W=1u L=0.18u
Cl1088 s1088 0 10f
Mn1089 s1089 s1088 0 0 nch W=0.5u L=0.18u
Mp1089 s1089 s1088 vdd vdd pch W=1u L=0.18u
Cl1089 s1089 0 10f
Mn1090 s1090 s1089 0 0 nch W=0.5u L=0.18u
Mp1090 s1090 s1089 vdd vdd pch W=1u L=0.18u
Cl1090 s1090 0 10f
Mn1091 s1091 s1090 0 0 nch W=0.5u L=0.18u
Mp1091 s1091 s1090 vdd vdd pch W=1u L=0.18u
Cl1091 s1091 0 10f
Mn1092 s1092 s1091 0 0 nch W=0.5u L=0.18u
Mp1092 s1092 s1091 vdd vdd pch W=1u L=0.18u
Cl1092 s1092 0 10f
Mn1093 s1093 s1092 0 0 nch W=0.5u L=0.18u
Mp1093 s1093 s1092 vdd vdd pch W=1u L=0.18u
Cl1093 s1093 0 10f
Mn1094 s1094 s1093 0 0 nch W=0.5u L=0.18u
Mp1094 s1094 s1093 vdd vdd pch W=1u L=0.18u
Cl1094 s1094 0 10f
Mn1095 s1095 s1094 0 0 nch W=0.5u L=0.18u
Mp1095 s1095 s1094 vdd vdd pch W=1u L=0.18u
Cl1095 s1095 0 10f
Mn1096 s1096 s1095 0 0 nch W=0.5u L=0.18u
Mp1096 s1096 s1095 vdd vdd pch W=1u L=0.18u
Cl1096 s1096 0 10f
Mn1097 s1097 s1096 0 0 nch W=0.5u L=0.18u
Mp1097 s1097 s1096 vdd vdd pch W=1u L=0.18u
Cl1097 s1097 0 10f
Mn1098 s1098 s1097 0 0 nch W=0.5u L=0.18u
Mp1098 s1098 s1097 vdd vdd pch W=1u L=0.18u
Cl1098 s1098 0 10f
Mn1099 s1099 s1098 0 0 nch W=0.5u L=0.18u
Mp1099 s1099 s1098 vdd vdd pch W=1u L=0.18u
Cl1099 s1099 0 10f
Mn1100 s1100 s1099 0 0 nch W=0.5u L=0.18u
Mp1100 s1100 s1099 vdd vdd pch W=1u L=0.18u
Cl1100 s1100 0 10f
Mn1101 s1101 s1100 0 0 nch W=0.5u L=0.18u
Mp1101 s1101 s1100 vdd vdd pch W=1u L=0.18u
Cl1101 s1101 0 10f
Mn1102 s1102 s1101 0 0 nch W=0.5u L=0.18u
Mp1102 s1102 s1101 vdd vdd pch W=1u L=0.18u
Cl1102 s1102 0 10f
Mn1103 s1103 s1102 0 0 nch W=0.5u L=0.18u
Mp1103 s1103 s1102 vdd vdd pch W=1u L=0.18u
Cl1103 s1103 0 10f
Mn1104 s1104 s1103 0 0 nch W=0.5u L=0.18u
Mp1104 s1104 s1103 vdd vdd pch W=1u L=0.18u
Cl1104 s1104 0 10f
Mn1105 s1105 s1104 0 0 nch W=0.5u L=0.18u
Mp1105 s1105 s1104 vdd vdd pch W=1u L=0.18u
Cl1105 s1105 0 10f
Mn1106 s1106 s1105 0 0 nch W=0.5u L=0.18u
Mp1106 s1106 s1105 vdd vdd pch W=1u L=0.18u
Cl1106 s1106 0 10f
Mn1107 s1107 s1106 0 0 nch W=0.5u L=0.18u
Mp1107 s1107 s1106 vdd vdd pch W=1u L=0.18u
Cl1107 s1107 0 10f
Mn1108 s1108 s1107 0 0 nch W=0.5u L=0.18u
Mp1108 s1108 s1107 vdd vdd pch W=1u L=0.18u
Cl1108 s1108 0 10f
Mn1109 s1109 s1108 0 0 nch W=0.5u L=0.18u
Mp1109 s1109 s1108 vdd vdd pch W=1u L=0.18u
Cl1109 s1109 0 10f
Mn1110 s1110 s1109 0 0 nch W=0.5u L=0.18u
Mp1110 s1110 s1109 vdd vdd pch W=1u L=0.18u
Cl1110 s1110 0 10f
Mn1111 s1111 s1110 0 0 nch W=0.5u L=0.18u
Mp1111 s1111 s1110 vdd vdd pch W=1u L=0.18u
Cl1111 s1111 0 10f
Mn1112 s1112 s1111 0 0 nch W=0.5u L=0.18u
Mp1112 s1112 s1111 vdd vdd pch W=1u L=0.18u
Cl1112 s1112 0 10f
Mn1113 s1113 s1112 0 0 nch W=0.5u L=0.18u
Mp1113 s1113 s1112 vdd vdd pch W=1u L=0.18u
Cl1113 s1113 0 10f
Mn1114 s1114 s1113 0 0 nch W=0.5u L=0.18u
Mp1114 s1114 s1113 vdd vdd pch W=1u L=0.18u
Cl1114 s1114 0 10f
Mn1115 s1115 s1114 0 0 nch W=0.5u L=0.18u
Mp1115 s1115 s1114 vdd vdd pch W=1u L=0.18u
Cl1115 s1115 0 10f
Mn1116 s1116 s1115 0 0 nch W=0.5u L=0.18u
Mp1116 s1116 s1115 vdd vdd pch W=1u L=0.18u
Cl1116 s1116 0 10f
Mn1117 s1117 s1116 0 0 nch W=0.5u L=0.18u
Mp1117 s1117 s1116 vdd vdd pch W=1u L=0.18u
Cl1117 s1117 0 10f
Mn1118 s1118 s1117 0 0 nch W=0.5u L=0.18u
Mp1118 s1118 s1117 vdd vdd pch W=1u L=0.18u
Cl1118 s1118 0 10f
Mn1119 s1119 s1118 0 0 nch W=0.5u L=0.18u
Mp1119 s1119 s1118 vdd vdd pch W=1u L=0.18u
Cl1119 s1119 0 10f
Mn1120 s1120 s1119 0 0 nch W=0.5u L=0.18u
Mp1120 s1120 s1119 vdd vdd pch W=1u L=0.18u
Cl1120 s1120 0 10f
Mn1121 s1121 s1120 0 0 nch W=0.5u L=0.18u
Mp1121 s1121 s1120 vdd vdd pch W=1u L=0.18u
Cl1121 s1121 0 10f
Mn1122 s1122 s1121 0 0 nch W=0.5u L=0.18u
Mp1122 s1122 s1121 vdd vdd pch W=1u L=0.18u
Cl1122 s1122 0 10f
Mn1123 s1123 s1122 0 0 nch W=0.5u L=0.18u
Mp1123 s1123 s1122 vdd vdd pch W=1u L=0.18u
Cl1123 s1123 0 10f
Mn1124 s1124 s1123 0 0 nch W=0.5u L=0.18u
Mp1124 s1124 s1123 vdd vdd pch W=1u L=0.18u
Cl1124 s1124 0 10f
Mn1125 s1125 s1124 0 0 nch W=0.5u L=0.18u
Mp1125 s1125 s1124 vdd vdd pch W=1u L=0.18u
Cl1125 s1125 0 10f
Mn1126 s1126 s1125 0 0 nch W=0.5u L=0.18u
Mp1126 s1126 s1125 vdd vdd pch W=1u L=0.18u
Cl1126 s1126 0 10f
Mn1127 s1127 s1126 0 0 nch W=0.5u L=0.18u
Mp1127 s1127 s1126 vdd vdd pch W=1u L=0.18u
Cl1127 s1127 0 10f
Mn1128 s1128 s1127 0 0 nch W=0.5u L=0.18u
Mp1128 s1128 s1127 vdd vdd pch W=1u L=0.18u
Cl1128 s1128 0 10f
Mn1129 s1129 s1128 0 0 nch W=0.5u L=0.18u
Mp1129 s1129 s1128 vdd vdd pch W=1u L=0.18u
Cl1129 s1129 0 10f
Mn1130 s1130 s1129 0 0 nch W=0.5u L=0.18u
Mp1130 s1130 s1129 vdd vdd pch W=1u L=0.18u
Cl1130 s1130 0 10f
Mn1131 s1131 s1130 0 0 nch W=0.5u L=0.18u
Mp1131 s1131 s1130 vdd vdd pch W=1u L=0.18u
Cl1131 s1131 0 10f
Mn1132 s1132 s1131 0 0 nch W=0.5u L=0.18u
Mp1132 s1132 s1131 vdd vdd pch W=1u L=0.18u
Cl1132 s1132 0 10f
Mn1133 s1133 s1132 0 0 nch W=0.5u L=0.18u
Mp1133 s1133 s1132 vdd vdd pch W=1u L=0.18u
Cl1133 s1133 0 10f
Mn1134 s1134 s1133 0 0 nch W=0.5u L=0.18u
Mp1134 s1134 s1133 vdd vdd pch W=1u L=0.18u
Cl1134 s1134 0 10f
Mn1135 s1135 s1134 0 0 nch W=0.5u L=0.18u
Mp1135 s1135 s1134 vdd vdd pch W=1u L=0.18u
Cl1135 s1135 0 10f
Mn1136 s1136 s1135 0 0 nch W=0.5u L=0.18u
Mp1136 s1136 s1135 vdd vdd pch W=1u L=0.18u
Cl1136 s1136 0 10f
Mn1137 s1137 s1136 0 0 nch W=0.5u L=0.18u
Mp1137 s1137 s1136 vdd vdd pch W=1u L=0.18u
Cl1137 s1137 0 10f
Mn1138 s1138 s1137 0 0 nch W=0.5u L=0.18u
Mp1138 s1138 s1137 vdd vdd pch W=1u L=0.18u
Cl1138 s1138 0 10f
Mn1139 s1139 s1138 0 0 nch W=0.5u L=0.18u
Mp1139 s1139 s1138 vdd vdd pch W=1u L=0.18u
Cl1139 s1139 0 10f
Mn1140 s1140 s1139 0 0 nch W=0.5u L=0.18u
Mp1140 s1140 s1139 vdd vdd pch W=1u L=0.18u
Cl1140 s1140 0 10f
Mn1141 s1141 s1140 0 0 nch W=0.5u L=0.18u
Mp1141 s1141 s1140 vdd vdd pch W=1u L=0.18u
Cl1141 s1141 0 10f
Mn1142 s1142 s1141 0 0 nch W=0.5u L=0.18u
Mp1142 s1142 s1141 vdd vdd pch W=1u L=0.18u
Cl1142 s1142 0 10f
Mn1143 s1143 s1142 0 0 nch W=0.5u L=0.18u
Mp1143 s1143 s1142 vdd vdd pch W=1u L=0.18u
Cl1143 s1143 0 10f
Mn1144 s1144 s1143 0 0 nch W=0.5u L=0.18u
Mp1144 s1144 s1143 vdd vdd pch W=1u L=0.18u
Cl1144 s1144 0 10f
Mn1145 s1145 s1144 0 0 nch W=0.5u L=0.18u
Mp1145 s1145 s1144 vdd vdd pch W=1u L=0.18u
Cl1145 s1145 0 10f
Mn1146 s1146 s1145 0 0 nch W=0.5u L=0.18u
Mp1146 s1146 s1145 vdd vdd pch W=1u L=0.18u
Cl1146 s1146 0 10f
Mn1147 s1147 s1146 0 0 nch W=0.5u L=0.18u
Mp1147 s1147 s1146 vdd vdd pch W=1u L=0.18u
Cl1147 s1147 0 10f
Mn1148 s1148 s1147 0 0 nch W=0.5u L=0.18u
Mp1148 s1148 s1147 vdd vdd pch W=1u L=0.18u
Cl1148 s1148 0 10f
Mn1149 s1149 s1148 0 0 nch W=0.5u L=0.18u
Mp1149 s1149 s1148 vdd vdd pch W=1u L=0.18u
Cl1149 s1149 0 10f
Mn1150 s1150 s1149 0 0 nch W=0.5u L=0.18u
Mp1150 s1150 s1149 vdd vdd pch W=1u L=0.18u
Cl1150 s1150 0 10f
Mn1151 s1151 s1150 0 0 nch W=0.5u L=0.18u
Mp1151 s1151 s1150 vdd vdd pch W=1u L=0.18u
Cl1151 s1151 0 10f
Mn1152 s1152 s1151 0 0 nch W=0.5u L=0.18u
Mp1152 s1152 s1151 vdd vdd pch W=1u L=0.18u
Cl1152 s1152 0 10f
Mn1153 s1153 s1152 0 0 nch W=0.5u L=0.18u
Mp1153 s1153 s1152 vdd vdd pch W=1u L=0.18u
Cl1153 s1153 0 10f
Mn1154 s1154 s1153 0 0 nch W=0.5u L=0.18u
Mp1154 s1154 s1153 vdd vdd pch W=1u L=0.18u
Cl1154 s1154 0 10f
Mn1155 s1155 s1154 0 0 nch W=0.5u L=0.18u
Mp1155 s1155 s1154 vdd vdd pch W=1u L=0.18u
Cl1155 s1155 0 10f
Mn1156 s1156 s1155 0 0 nch W=0.5u L=0.18u
Mp1156 s1156 s1155 vdd vdd pch W=1u L=0.18u
Cl1156 s1156 0 10f
Mn1157 s1157 s1156 0 0 nch W=0.5u L=0.18u
Mp1157 s1157 s1156 vdd vdd pch W=1u L=0.18u
Cl1157 s1157 0 10f
Mn1158 s1158 s1157 0 0 nch W=0.5u L=0.18u
Mp1158 s1158 s1157 vdd vdd pch W=1u L=0.18u
Cl1158 s1158 0 10f
Mn1159 s1159 s1158 0 0 nch W=0.5u L=0.18u
Mp1159 s1159 s1158 vdd vdd pch W=1u L=0.18u
Cl1159 s1159 0 10f
Mn1160 s1160 s1159 0 0 nch W=0.5u L=0.18u
Mp1160 s1160 s1159 vdd vdd pch W=1u L=0.18u
Cl1160 s1160 0 10f
Mn1161 s1161 s1160 0 0 nch W=0.5u L=0.18u
Mp1161 s1161 s1160 vdd vdd pch W=1u L=0.18u
Cl1161 s1161 0 10f
Mn1162 s1162 s1161 0 0 nch W=0.5u L=0.18u
Mp1162 s1162 s1161 vdd vdd pch W=1u L=0.18u
Cl1162 s1162 0 10f
Mn1163 s1163 s1162 0 0 nch W=0.5u L=0.18u
Mp1163 s1163 s1162 vdd vdd pch W=1u L=0.18u
Cl1163 s1163 0 10f
Mn1164 s1164 s1163 0 0 nch W=0.5u L=0.18u
Mp1164 s1164 s1163 vdd vdd pch W=1u L=0.18u
Cl1164 s1164 0 10f
Mn1165 s1165 s1164 0 0 nch W=0.5u L=0.18u
Mp1165 s1165 s1164 vdd vdd pch W=1u L=0.18u
Cl1165 s1165 0 10f
Mn1166 s1166 s1165 0 0 nch W=0.5u L=0.18u
Mp1166 s1166 s1165 vdd vdd pch W=1u L=0.18u
Cl1166 s1166 0 10f
Mn1167 s1167 s1166 0 0 nch W=0.5u L=0.18u
Mp1167 s1167 s1166 vdd vdd pch W=1u L=0.18u
Cl1167 s1167 0 10f
Mn1168 s1168 s1167 0 0 nch W=0.5u L=0.18u
Mp1168 s1168 s1167 vdd vdd pch W=1u L=0.18u
Cl1168 s1168 0 10f
Mn1169 s1169 s1168 0 0 nch W=0.5u L=0.18u
Mp1169 s1169 s1168 vdd vdd pch W=1u L=0.18u
Cl1169 s1169 0 10f
Mn1170 s1170 s1169 0 0 nch W=0.5u L=0.18u
Mp1170 s1170 s1169 vdd vdd pch W=1u L=0.18u
Cl1170 s1170 0 10f
Mn1171 s1171 s1170 0 0 nch W=0.5u L=0.18u
Mp1171 s1171 s1170 vdd vdd pch W=1u L=0.18u
Cl1171 s1171 0 10f
Mn1172 s1172 s1171 0 0 nch W=0.5u L=0.18u
Mp1172 s1172 s1171 vdd vdd pch W=1u L=0.18u
Cl1172 s1172 0 10f
Mn1173 s1173 s1172 0 0 nch W=0.5u L=0.18u
Mp1173 s1173 s1172 vdd vdd pch W=1u L=0.18u
Cl1173 s1173 0 10f
Mn1174 s1174 s1173 0 0 nch W=0.5u L=0.18u
Mp1174 s1174 s1173 vdd vdd pch W=1u L=0.18u
Cl1174 s1174 0 10f
Mn1175 s1175 s1174 0 0 nch W=0.5u L=0.18u
Mp1175 s1175 s1174 vdd vdd pch W=1u L=0.18u
Cl1175 s1175 0 10f
Mn1176 s1176 s1175 0 0 nch W=0.5u L=0.18u
Mp1176 s1176 s1175 vdd vdd pch W=1u L=0.18u
Cl1176 s1176 0 10f
Mn1177 s1177 s1176 0 0 nch W=0.5u L=0.18u
Mp1177 s1177 s1176 vdd vdd pch W=1u L=0.18u
Cl1177 s1177 0 10f
Mn1178 s1178 s1177 0 0 nch W=0.5u L=0.18u
Mp1178 s1178 s1177 vdd vdd pch W=1u L=0.18u
Cl1178 s1178 0 10f
Mn1179 s1179 s1178 0 0 nch W=0.5u L=0.18u
Mp1179 s1179 s1178 vdd vdd pch W=1u L=0.18u
Cl1179 s1179 0 10f
Mn1180 s1180 s1179 0 0 nch W=0.5u L=0.18u
Mp1180 s1180 s1179 vdd vdd pch W=1u L=0.18u
Cl1180 s1180 0 10f
Mn1181 s1181 s1180 0 0 nch W=0.5u L=0.18u
Mp1181 s1181 s1180 vdd vdd pch W=1u L=0.18u
Cl1181 s1181 0 10f
Mn1182 s1182 s1181 0 0 nch W=0.5u L=0.18u
Mp1182 s1182 s1181 vdd vdd pch W=1u L=0.18u
Cl1182 s1182 0 10f
Mn1183 s1183 s1182 0 0 nch W=0.5u L=0.18u
Mp1183 s1183 s1182 vdd vdd pch W=1u L=0.18u
Cl1183 s1183 0 10f
Mn1184 s1184 s1183 0 0 nch W=0.5u L=0.18u
Mp1184 s1184 s1183 vdd vdd pch W=1u L=0.18u
Cl1184 s1184 0 10f
Mn1185 s1185 s1184 0 0 nch W=0.5u L=0.18u
Mp1185 s1185 s1184 vdd vdd pch W=1u L=0.18u
Cl1185 s1185 0 10f
Mn1186 s1186 s1185 0 0 nch W=0.5u L=0.18u
Mp1186 s1186 s1185 vdd vdd pch W=1u L=0.18u
Cl1186 s1186 0 10f
Mn1187 s1187 s1186 0 0 nch W=0.5u L=0.18u
Mp1187 s1187 s1186 vdd vdd pch W=1u L=0.18u
Cl1187 s1187 0 10f
Mn1188 s1188 s1187 0 0 nch W=0.5u L=0.18u
Mp1188 s1188 s1187 vdd vdd pch W=1u L=0.18u
Cl1188 s1188 0 10f
Mn1189 s1189 s1188 0 0 nch W=0.5u L=0.18u
Mp1189 s1189 s1188 vdd vdd pch W=1u L=0.18u
Cl1189 s1189 0 10f
Mn1190 s1190 s1189 0 0 nch W=0.5u L=0.18u
Mp1190 s1190 s1189 vdd vdd pch W=1u L=0.18u
Cl1190 s1190 0 10f
Mn1191 s1191 s1190 0 0 nch W=0.5u L=0.18u
Mp1191 s1191 s1190 vdd vdd pch W=1u L=0.18u
Cl1191 s1191 0 10f
Mn1192 s1192 s1191 0 0 nch W=0.5u L=0.18u
Mp1192 s1192 s1191 vdd vdd pch W=1u L=0.18u
Cl1192 s1192 0 10f
Mn1193 s1193 s1192 0 0 nch W=0.5u L=0.18u
Mp1193 s1193 s1192 vdd vdd pch W=1u L=0.18u
Cl1193 s1193 0 10f
Mn1194 s1194 s1193 0 0 nch W=0.5u L=0.18u
Mp1194 s1194 s1193 vdd vdd pch W=1u L=0.18u
Cl1194 s1194 0 10f
Mn1195 s1195 s1194 0 0 nch W=0.5u L=0.18u
Mp1195 s1195 s1194 vdd vdd pch W=1u L=0.18u
Cl1195 s1195 0 10f
Mn1196 s1196 s1195 0 0 nch W=0.5u L=0.18u
Mp1196 s1196 s1195 vdd vdd pch W=1u L=0.18u
Cl1196 s1196 0 10f
Mn1197 s1197 s1196 0 0 nch W=0.5u L=0.18u
Mp1197 s1197 s1196 vdd vdd pch W=1u L=0.18u
Cl1197 s1197 0 10f
Mn1198 s1198 s1197 0 0 nch W=0.5u L=0.18u
Mp1198 s1198 s1197 vdd vdd pch W=1u L=0.18u
Cl1198 s1198 0 10f
Mn1199 s1199 s1198 0 0 nch W=0.5u L=0.18u
Mp1199 s1199 s1198 vdd vdd pch W=1u L=0.18u
Cl1199 s1199 0 10f
Mn1200 s1200 s1199 0 0 nch W=0.5u L=0.18u
Mp1200 s1200 s1199 vdd vdd pch W=1u L=0.18u
Cl1200 s1200 0 10f
Mn1201 s1201 s1200 0 0 nch W=0.5u L=0.18u
Mp1201 s1201 s1200 vdd vdd pch W=1u L=0.18u
Cl1201 s1201 0 10f
Mn1202 s1202 s1201 0 0 nch W=0.5u L=0.18u
Mp1202 s1202 s1201 vdd vdd pch W=1u L=0.18u
Cl1202 s1202 0 10f
Mn1203 s1203 s1202 0 0 nch W=0.5u L=0.18u
Mp1203 s1203 s1202 vdd vdd pch W=1u L=0.18u
Cl1203 s1203 0 10f
Mn1204 s1204 s1203 0 0 nch W=0.5u L=0.18u
Mp1204 s1204 s1203 vdd vdd pch W=1u L=0.18u
Cl1204 s1204 0 10f
Mn1205 s1205 s1204 0 0 nch W=0.5u L=0.18u
Mp1205 s1205 s1204 vdd vdd pch W=1u L=0.18u
Cl1205 s1205 0 10f
Mn1206 s1206 s1205 0 0 nch W=0.5u L=0.18u
Mp1206 s1206 s1205 vdd vdd pch W=1u L=0.18u
Cl1206 s1206 0 10f
Mn1207 s1207 s1206 0 0 nch W=0.5u L=0.18u
Mp1207 s1207 s1206 vdd vdd pch W=1u L=0.18u
Cl1207 s1207 0 10f
Mn1208 s1208 s1207 0 0 nch W=0.5u L=0.18u
Mp1208 s1208 s1207 vdd vdd pch W=1u L=0.18u
Cl1208 s1208 0 10f
Mn1209 s1209 s1208 0 0 nch W=0.5u L=0.18u
Mp1209 s1209 s1208 vdd vdd pch W=1u L=0.18u
Cl1209 s1209 0 10f
Mn1210 s1210 s1209 0 0 nch W=0.5u L=0.18u
Mp1210 s1210 s1209 vdd vdd pch W=1u L=0.18u
Cl1210 s1210 0 10f
Mn1211 s1211 s1210 0 0 nch W=0.5u L=0.18u
Mp1211 s1211 s1210 vdd vdd pch W=1u L=0.18u
Cl1211 s1211 0 10f
Mn1212 s1212 s1211 0 0 nch W=0.5u L=0.18u
Mp1212 s1212 s1211 vdd vdd pch W=1u L=0.18u
Cl1212 s1212 0 10f
Mn1213 s1213 s1212 0 0 nch W=0.5u L=0.18u
Mp1213 s1213 s1212 vdd vdd pch W=1u L=0.18u
Cl1213 s1213 0 10f
Mn1214 s1214 s1213 0 0 nch W=0.5u L=0.18u
Mp1214 s1214 s1213 vdd vdd pch W=1u L=0.18u
Cl1214 s1214 0 10f
Mn1215 s1215 s1214 0 0 nch W=0.5u L=0.18u
Mp1215 s1215 s1214 vdd vdd pch W=1u L=0.18u
Cl1215 s1215 0 10f
Mn1216 s1216 s1215 0 0 nch W=0.5u L=0.18u
Mp1216 s1216 s1215 vdd vdd pch W=1u L=0.18u
Cl1216 s1216 0 10f
Mn1217 s1217 s1216 0 0 nch W=0.5u L=0.18u
Mp1217 s1217 s1216 vdd vdd pch W=1u L=0.18u
Cl1217 s1217 0 10f
Mn1218 s1218 s1217 0 0 nch W=0.5u L=0.18u
Mp1218 s1218 s1217 vdd vdd pch W=1u L=0.18u
Cl1218 s1218 0 10f
Mn1219 s1219 s1218 0 0 nch W=0.5u L=0.18u
Mp1219 s1219 s1218 vdd vdd pch W=1u L=0.18u
Cl1219 s1219 0 10f
Mn1220 s1220 s1219 0 0 nch W=0.5u L=0.18u
Mp1220 s1220 s1219 vdd vdd pch W=1u L=0.18u
Cl1220 s1220 0 10f
Mn1221 s1221 s1220 0 0 nch W=0.5u L=0.18u
Mp1221 s1221 s1220 vdd vdd pch W=1u L=0.18u
Cl1221 s1221 0 10f
Mn1222 s1222 s1221 0 0 nch W=0.5u L=0.18u
Mp1222 s1222 s1221 vdd vdd pch W=1u L=0.18u
Cl1222 s1222 0 10f
Mn1223 s1223 s1222 0 0 nch W=0.5u L=0.18u
Mp1223 s1223 s1222 vdd vdd pch W=1u L=0.18u
Cl1223 s1223 0 10f
Mn1224 s1224 s1223 0 0 nch W=0.5u L=0.18u
Mp1224 s1224 s1223 vdd vdd pch W=1u L=0.18u
Cl1224 s1224 0 10f
Mn1225 s1225 s1224 0 0 nch W=0.5u L=0.18u
Mp1225 s1225 s1224 vdd vdd pch W=1u L=0.18u
Cl1225 s1225 0 10f
Mn1226 s1226 s1225 0 0 nch W=0.5u L=0.18u
Mp1226 s1226 s1225 vdd vdd pch W=1u L=0.18u
Cl1226 s1226 0 10f
Mn1227 s1227 s1226 0 0 nch W=0.5u L=0.18u
Mp1227 s1227 s1226 vdd vdd pch W=1u L=0.18u
Cl1227 s1227 0 10f
Mn1228 s1228 s1227 0 0 nch W=0.5u L=0.18u
Mp1228 s1228 s1227 vdd vdd pch W=1u L=0.18u
Cl1228 s1228 0 10f
Mn1229 s1229 s1228 0 0 nch W=0.5u L=0.18u
Mp1229 s1229 s1228 vdd vdd pch W=1u L=0.18u
Cl1229 s1229 0 10f
Mn1230 s1230 s1229 0 0 nch W=0.5u L=0.18u
Mp1230 s1230 s1229 vdd vdd pch W=1u L=0.18u
Cl1230 s1230 0 10f
Mn1231 s1231 s1230 0 0 nch W=0.5u L=0.18u
Mp1231 s1231 s1230 vdd vdd pch W=1u L=0.18u
Cl1231 s1231 0 10f
Mn1232 s1232 s1231 0 0 nch W=0.5u L=0.18u
Mp1232 s1232 s1231 vdd vdd pch W=1u L=0.18u
Cl1232 s1232 0 10f
Mn1233 s1233 s1232 0 0 nch W=0.5u L=0.18u
Mp1233 s1233 s1232 vdd vdd pch W=1u L=0.18u
Cl1233 s1233 0 10f
Mn1234 s1234 s1233 0 0 nch W=0.5u L=0.18u
Mp1234 s1234 s1233 vdd vdd pch W=1u L=0.18u
Cl1234 s1234 0 10f
Mn1235 s1235 s1234 0 0 nch W=0.5u L=0.18u
Mp1235 s1235 s1234 vdd vdd pch W=1u L=0.18u
Cl1235 s1235 0 10f
Mn1236 s1236 s1235 0 0 nch W=0.5u L=0.18u
Mp1236 s1236 s1235 vdd vdd pch W=1u L=0.18u
Cl1236 s1236 0 10f
Mn1237 s1237 s1236 0 0 nch W=0.5u L=0.18u
Mp1237 s1237 s1236 vdd vdd pch W=1u L=0.18u
Cl1237 s1237 0 10f
Mn1238 s1238 s1237 0 0 nch W=0.5u L=0.18u
Mp1238 s1238 s1237 vdd vdd pch W=1u L=0.18u
Cl1238 s1238 0 10f
Mn1239 s1239 s1238 0 0 nch W=0.5u L=0.18u
Mp1239 s1239 s1238 vdd vdd pch W=1u L=0.18u
Cl1239 s1239 0 10f
Mn1240 s1240 s1239 0 0 nch W=0.5u L=0.18u
Mp1240 s1240 s1239 vdd vdd pch W=1u L=0.18u
Cl1240 s1240 0 10f
Mn1241 s1241 s1240 0 0 nch W=0.5u L=0.18u
Mp1241 s1241 s1240 vdd vdd pch W=1u L=0.18u
Cl1241 s1241 0 10f
Mn1242 s1242 s1241 0 0 nch W=0.5u L=0.18u
Mp1242 s1242 s1241 vdd vdd pch W=1u L=0.18u
Cl1242 s1242 0 10f
Mn1243 s1243 s1242 0 0 nch W=0.5u L=0.18u
Mp1243 s1243 s1242 vdd vdd pch W=1u L=0.18u
Cl1243 s1243 0 10f
Mn1244 s1244 s1243 0 0 nch W=0.5u L=0.18u
Mp1244 s1244 s1243 vdd vdd pch W=1u L=0.18u
Cl1244 s1244 0 10f
Mn1245 s1245 s1244 0 0 nch W=0.5u L=0.18u
Mp1245 s1245 s1244 vdd vdd pch W=1u L=0.18u
Cl1245 s1245 0 10f
Mn1246 s1246 s1245 0 0 nch W=0.5u L=0.18u
Mp1246 s1246 s1245 vdd vdd pch W=1u L=0.18u
Cl1246 s1246 0 10f
Mn1247 s1247 s1246 0 0 nch W=0.5u L=0.18u
Mp1247 s1247 s1246 vdd vdd pch W=1u L=0.18u
Cl1247 s1247 0 10f
Mn1248 s1248 s1247 0 0 nch W=0.5u L=0.18u
Mp1248 s1248 s1247 vdd vdd pch W=1u L=0.18u
Cl1248 s1248 0 10f
Mn1249 s1249 s1248 0 0 nch W=0.5u L=0.18u
Mp1249 s1249 s1248 vdd vdd pch W=1u L=0.18u
Cl1249 s1249 0 10f
Mn1250 s1250 s1249 0 0 nch W=0.5u L=0.18u
Mp1250 s1250 s1249 vdd vdd pch W=1u L=0.18u
Cl1250 s1250 0 10f
Mn1251 s1251 s1250 0 0 nch W=0.5u L=0.18u
Mp1251 s1251 s1250 vdd vdd pch W=1u L=0.18u
Cl1251 s1251 0 10f
Mn1252 s1252 s1251 0 0 nch W=0.5u L=0.18u
Mp1252 s1252 s1251 vdd vdd pch W=1u L=0.18u
Cl1252 s1252 0 10f
Mn1253 s1253 s1252 0 0 nch W=0.5u L=0.18u
Mp1253 s1253 s1252 vdd vdd pch W=1u L=0.18u
Cl1253 s1253 0 10f
Mn1254 s1254 s1253 0 0 nch W=0.5u L=0.18u
Mp1254 s1254 s1253 vdd vdd pch W=1u L=0.18u
Cl1254 s1254 0 10f
Mn1255 s1255 s1254 0 0 nch W=0.5u L=0.18u
Mp1255 s1255 s1254 vdd vdd pch W=1u L=0.18u
Cl1255 s1255 0 10f
Mn1256 s1256 s1255 0 0 nch W=0.5u L=0.18u
Mp1256 s1256 s1255 vdd vdd pch W=1u L=0.18u
Cl1256 s1256 0 10f
Mn1257 s1257 s1256 0 0 nch W=0.5u L=0.18u
Mp1257 s1257 s1256 vdd vdd pch W=1u L=0.18u
Cl1257 s1257 0 10f
Mn1258 s1258 s1257 0 0 nch W=0.5u L=0.18u
Mp1258 s1258 s1257 vdd vdd pch W=1u L=0.18u
Cl1258 s1258 0 10f
Mn1259 s1259 s1258 0 0 nch W=0.5u L=0.18u
Mp1259 s1259 s1258 vdd vdd pch W=1u L=0.18u
Cl1259 s1259 0 10f
Mn1260 s1260 s1259 0 0 nch W=0.5u L=0.18u
Mp1260 s1260 s1259 vdd vdd pch W=1u L=0.18u
Cl1260 s1260 0 10f
Mn1261 s1261 s1260 0 0 nch W=0.5u L=0.18u
Mp1261 s1261 s1260 vdd vdd pch W=1u L=0.18u
Cl1261 s1261 0 10f
Mn1262 s1262 s1261 0 0 nch W=0.5u L=0.18u
Mp1262 s1262 s1261 vdd vdd pch W=1u L=0.18u
Cl1262 s1262 0 10f
Mn1263 s1263 s1262 0 0 nch W=0.5u L=0.18u
Mp1263 s1263 s1262 vdd vdd pch W=1u L=0.18u
Cl1263 s1263 0 10f
Mn1264 s1264 s1263 0 0 nch W=0.5u L=0.18u
Mp1264 s1264 s1263 vdd vdd pch W=1u L=0.18u
Cl1264 s1264 0 10f
Mn1265 s1265 s1264 0 0 nch W=0.5u L=0.18u
Mp1265 s1265 s1264 vdd vdd pch W=1u L=0.18u
Cl1265 s1265 0 10f
Mn1266 s1266 s1265 0 0 nch W=0.5u L=0.18u
Mp1266 s1266 s1265 vdd vdd pch W=1u L=0.18u
Cl1266 s1266 0 10f
Mn1267 s1267 s1266 0 0 nch W=0.5u L=0.18u
Mp1267 s1267 s1266 vdd vdd pch W=1u L=0.18u
Cl1267 s1267 0 10f
Mn1268 s1268 s1267 0 0 nch W=0.5u L=0.18u
Mp1268 s1268 s1267 vdd vdd pch W=1u L=0.18u
Cl1268 s1268 0 10f
Mn1269 s1269 s1268 0 0 nch W=0.5u L=0.18u
Mp1269 s1269 s1268 vdd vdd pch W=1u L=0.18u
Cl1269 s1269 0 10f
Mn1270 s1270 s1269 0 0 nch W=0.5u L=0.18u
Mp1270 s1270 s1269 vdd vdd pch W=1u L=0.18u
Cl1270 s1270 0 10f
Mn1271 s1271 s1270 0 0 nch W=0.5u L=0.18u
Mp1271 s1271 s1270 vdd vdd pch W=1u L=0.18u
Cl1271 s1271 0 10f
Mn1272 s1272 s1271 0 0 nch W=0.5u L=0.18u
Mp1272 s1272 s1271 vdd vdd pch W=1u L=0.18u
Cl1272 s1272 0 10f
Mn1273 s1273 s1272 0 0 nch W=0.5u L=0.18u
Mp1273 s1273 s1272 vdd vdd pch W=1u L=0.18u
Cl1273 s1273 0 10f
Mn1274 s1274 s1273 0 0 nch W=0.5u L=0.18u
Mp1274 s1274 s1273 vdd vdd pch W=1u L=0.18u
Cl1274 s1274 0 10f
Mn1275 s1275 s1274 0 0 nch W=0.5u L=0.18u
Mp1275 s1275 s1274 vdd vdd pch W=1u L=0.18u
Cl1275 s1275 0 10f
Mn1276 s1276 s1275 0 0 nch W=0.5u L=0.18u
Mp1276 s1276 s1275 vdd vdd pch W=1u L=0.18u
Cl1276 s1276 0 10f
Mn1277 s1277 s1276 0 0 nch W=0.5u L=0.18u
Mp1277 s1277 s1276 vdd vdd pch W=1u L=0.18u
Cl1277 s1277 0 10f
Mn1278 s1278 s1277 0 0 nch W=0.5u L=0.18u
Mp1278 s1278 s1277 vdd vdd pch W=1u L=0.18u
Cl1278 s1278 0 10f
Mn1279 s1279 s1278 0 0 nch W=0.5u L=0.18u
Mp1279 s1279 s1278 vdd vdd pch W=1u L=0.18u
Cl1279 s1279 0 10f
Mn1280 s1280 s1279 0 0 nch W=0.5u L=0.18u
Mp1280 s1280 s1279 vdd vdd pch W=1u L=0.18u
Cl1280 s1280 0 10f
Mn1281 s1281 s1280 0 0 nch W=0.5u L=0.18u
Mp1281 s1281 s1280 vdd vdd pch W=1u L=0.18u
Cl1281 s1281 0 10f
Mn1282 s1282 s1281 0 0 nch W=0.5u L=0.18u
Mp1282 s1282 s1281 vdd vdd pch W=1u L=0.18u
Cl1282 s1282 0 10f
Mn1283 s1283 s1282 0 0 nch W=0.5u L=0.18u
Mp1283 s1283 s1282 vdd vdd pch W=1u L=0.18u
Cl1283 s1283 0 10f
Mn1284 s1284 s1283 0 0 nch W=0.5u L=0.18u
Mp1284 s1284 s1283 vdd vdd pch W=1u L=0.18u
Cl1284 s1284 0 10f
Mn1285 s1285 s1284 0 0 nch W=0.5u L=0.18u
Mp1285 s1285 s1284 vdd vdd pch W=1u L=0.18u
Cl1285 s1285 0 10f
Mn1286 s1286 s1285 0 0 nch W=0.5u L=0.18u
Mp1286 s1286 s1285 vdd vdd pch W=1u L=0.18u
Cl1286 s1286 0 10f
Mn1287 s1287 s1286 0 0 nch W=0.5u L=0.18u
Mp1287 s1287 s1286 vdd vdd pch W=1u L=0.18u
Cl1287 s1287 0 10f
Mn1288 s1288 s1287 0 0 nch W=0.5u L=0.18u
Mp1288 s1288 s1287 vdd vdd pch W=1u L=0.18u
Cl1288 s1288 0 10f
Mn1289 s1289 s1288 0 0 nch W=0.5u L=0.18u
Mp1289 s1289 s1288 vdd vdd pch W=1u L=0.18u
Cl1289 s1289 0 10f
Mn1290 s1290 s1289 0 0 nch W=0.5u L=0.18u
Mp1290 s1290 s1289 vdd vdd pch W=1u L=0.18u
Cl1290 s1290 0 10f
Mn1291 s1291 s1290 0 0 nch W=0.5u L=0.18u
Mp1291 s1291 s1290 vdd vdd pch W=1u L=0.18u
Cl1291 s1291 0 10f
Mn1292 s1292 s1291 0 0 nch W=0.5u L=0.18u
Mp1292 s1292 s1291 vdd vdd pch W=1u L=0.18u
Cl1292 s1292 0 10f
Mn1293 s1293 s1292 0 0 nch W=0.5u L=0.18u
Mp1293 s1293 s1292 vdd vdd pch W=1u L=0.18u
Cl1293 s1293 0 10f
Mn1294 s1294 s1293 0 0 nch W=0.5u L=0.18u
Mp1294 s1294 s1293 vdd vdd pch W=1u L=0.18u
Cl1294 s1294 0 10f
Mn1295 s1295 s1294 0 0 nch W=0.5u L=0.18u
Mp1295 s1295 s1294 vdd vdd pch W=1u L=0.18u
Cl1295 s1295 0 10f
Mn1296 s1296 s1295 0 0 nch W=0.5u L=0.18u
Mp1296 s1296 s1295 vdd vdd pch W=1u L=0.18u
Cl1296 s1296 0 10f
Mn1297 s1297 s1296 0 0 nch W=0.5u L=0.18u
Mp1297 s1297 s1296 vdd vdd pch W=1u L=0.18u
Cl1297 s1297 0 10f
Mn1298 s1298 s1297 0 0 nch W=0.5u L=0.18u
Mp1298 s1298 s1297 vdd vdd pch W=1u L=0.18u
Cl1298 s1298 0 10f
Mn1299 s1299 s1298 0 0 nch W=0.5u L=0.18u
Mp1299 s1299 s1298 vdd vdd pch W=1u L=0.18u
Cl1299 s1299 0 10f
Mn1300 s1300 s1299 0 0 nch W=0.5u L=0.18u
Mp1300 s1300 s1299 vdd vdd pch W=1u L=0.18u
Cl1300 s1300 0 10f
Mn1301 s1301 s1300 0 0 nch W=0.5u L=0.18u
Mp1301 s1301 s1300 vdd vdd pch W=1u L=0.18u
Cl1301 s1301 0 10f
Mn1302 s1302 s1301 0 0 nch W=0.5u L=0.18u
Mp1302 s1302 s1301 vdd vdd pch W=1u L=0.18u
Cl1302 s1302 0 10f
Mn1303 s1303 s1302 0 0 nch W=0.5u L=0.18u
Mp1303 s1303 s1302 vdd vdd pch W=1u L=0.18u
Cl1303 s1303 0 10f
Mn1304 s1304 s1303 0 0 nch W=0.5u L=0.18u
Mp1304 s1304 s1303 vdd vdd pch W=1u L=0.18u
Cl1304 s1304 0 10f
Mn1305 s1305 s1304 0 0 nch W=0.5u L=0.18u
Mp1305 s1305 s1304 vdd vdd pch W=1u L=0.18u
Cl1305 s1305 0 10f
Mn1306 s1306 s1305 0 0 nch W=0.5u L=0.18u
Mp1306 s1306 s1305 vdd vdd pch W=1u L=0.18u
Cl1306 s1306 0 10f
Mn1307 s1307 s1306 0 0 nch W=0.5u L=0.18u
Mp1307 s1307 s1306 vdd vdd pch W=1u L=0.18u
Cl1307 s1307 0 10f
Mn1308 s1308 s1307 0 0 nch W=0.5u L=0.18u
Mp1308 s1308 s1307 vdd vdd pch W=1u L=0.18u
Cl1308 s1308 0 10f
Mn1309 s1309 s1308 0 0 nch W=0.5u L=0.18u
Mp1309 s1309 s1308 vdd vdd pch W=1u L=0.18u
Cl1309 s1309 0 10f
Mn1310 s1310 s1309 0 0 nch W=0.5u L=0.18u
Mp1310 s1310 s1309 vdd vdd pch W=1u L=0.18u
Cl1310 s1310 0 10f
Mn1311 s1311 s1310 0 0 nch W=0.5u L=0.18u
Mp1311 s1311 s1310 vdd vdd pch W=1u L=0.18u
Cl1311 s1311 0 10f
Mn1312 s1312 s1311 0 0 nch W=0.5u L=0.18u
Mp1312 s1312 s1311 vdd vdd pch W=1u L=0.18u
Cl1312 s1312 0 10f
Mn1313 s1313 s1312 0 0 nch W=0.5u L=0.18u
Mp1313 s1313 s1312 vdd vdd pch W=1u L=0.18u
Cl1313 s1313 0 10f
Mn1314 s1314 s1313 0 0 nch W=0.5u L=0.18u
Mp1314 s1314 s1313 vdd vdd pch W=1u L=0.18u
Cl1314 s1314 0 10f
Mn1315 s1315 s1314 0 0 nch W=0.5u L=0.18u
Mp1315 s1315 s1314 vdd vdd pch W=1u L=0.18u
Cl1315 s1315 0 10f
Mn1316 s1316 s1315 0 0 nch W=0.5u L=0.18u
Mp1316 s1316 s1315 vdd vdd pch W=1u L=0.18u
Cl1316 s1316 0 10f
Mn1317 s1317 s1316 0 0 nch W=0.5u L=0.18u
Mp1317 s1317 s1316 vdd vdd pch W=1u L=0.18u
Cl1317 s1317 0 10f
Mn1318 s1318 s1317 0 0 nch W=0.5u L=0.18u
Mp1318 s1318 s1317 vdd vdd pch W=1u L=0.18u
Cl1318 s1318 0 10f
Mn1319 s1319 s1318 0 0 nch W=0.5u L=0.18u
Mp1319 s1319 s1318 vdd vdd pch W=1u L=0.18u
Cl1319 s1319 0 10f
Mn1320 s1320 s1319 0 0 nch W=0.5u L=0.18u
Mp1320 s1320 s1319 vdd vdd pch W=1u L=0.18u
Cl1320 s1320 0 10f
Mn1321 s1321 s1320 0 0 nch W=0.5u L=0.18u
Mp1321 s1321 s1320 vdd vdd pch W=1u L=0.18u
Cl1321 s1321 0 10f
Mn1322 s1322 s1321 0 0 nch W=0.5u L=0.18u
Mp1322 s1322 s1321 vdd vdd pch W=1u L=0.18u
Cl1322 s1322 0 10f
Mn1323 s1323 s1322 0 0 nch W=0.5u L=0.18u
Mp1323 s1323 s1322 vdd vdd pch W=1u L=0.18u
Cl1323 s1323 0 10f
Mn1324 s1324 s1323 0 0 nch W=0.5u L=0.18u
Mp1324 s1324 s1323 vdd vdd pch W=1u L=0.18u
Cl1324 s1324 0 10f
Mn1325 s1325 s1324 0 0 nch W=0.5u L=0.18u
Mp1325 s1325 s1324 vdd vdd pch W=1u L=0.18u
Cl1325 s1325 0 10f
Mn1326 s1326 s1325 0 0 nch W=0.5u L=0.18u
Mp1326 s1326 s1325 vdd vdd pch W=1u L=0.18u
Cl1326 s1326 0 10f
Mn1327 s1327 s1326 0 0 nch W=0.5u L=0.18u
Mp1327 s1327 s1326 vdd vdd pch W=1u L=0.18u
Cl1327 s1327 0 10f
Mn1328 s1328 s1327 0 0 nch W=0.5u L=0.18u
Mp1328 s1328 s1327 vdd vdd pch W=1u L=0.18u
Cl1328 s1328 0 10f
Mn1329 s1329 s1328 0 0 nch W=0.5u L=0.18u
Mp1329 s1329 s1328 vdd vdd pch W=1u L=0.18u
Cl1329 s1329 0 10f
Mn1330 s1330 s1329 0 0 nch W=0.5u L=0.18u
Mp1330 s1330 s1329 vdd vdd pch W=1u L=0.18u
Cl1330 s1330 0 10f
Mn1331 s1331 s1330 0 0 nch W=0.5u L=0.18u
Mp1331 s1331 s1330 vdd vdd pch W=1u L=0.18u
Cl1331 s1331 0 10f
Mn1332 s1332 s1331 0 0 nch W=0.5u L=0.18u
Mp1332 s1332 s1331 vdd vdd pch W=1u L=0.18u
Cl1332 s1332 0 10f
Mn1333 s1333 s1332 0 0 nch W=0.5u L=0.18u
Mp1333 s1333 s1332 vdd vdd pch W=1u L=0.18u
Cl1333 s1333 0 10f
Mn1334 s1334 s1333 0 0 nch W=0.5u L=0.18u
Mp1334 s1334 s1333 vdd vdd pch W=1u L=0.18u
Cl1334 s1334 0 10f
Mn1335 s1335 s1334 0 0 nch W=0.5u L=0.18u
Mp1335 s1335 s1334 vdd vdd pch W=1u L=0.18u
Cl1335 s1335 0 10f
Mn1336 s1336 s1335 0 0 nch W=0.5u L=0.18u
Mp1336 s1336 s1335 vdd vdd pch W=1u L=0.18u
Cl1336 s1336 0 10f
Mn1337 s1337 s1336 0 0 nch W=0.5u L=0.18u
Mp1337 s1337 s1336 vdd vdd pch W=1u L=0.18u
Cl1337 s1337 0 10f
Mn1338 s1338 s1337 0 0 nch W=0.5u L=0.18u
Mp1338 s1338 s1337 vdd vdd pch W=1u L=0.18u
Cl1338 s1338 0 10f
Mn1339 s1339 s1338 0 0 nch W=0.5u L=0.18u
Mp1339 s1339 s1338 vdd vdd pch W=1u L=0.18u
Cl1339 s1339 0 10f
Mn1340 s1340 s1339 0 0 nch W=0.5u L=0.18u
Mp1340 s1340 s1339 vdd vdd pch W=1u L=0.18u
Cl1340 s1340 0 10f
Mn1341 s1341 s1340 0 0 nch W=0.5u L=0.18u
Mp1341 s1341 s1340 vdd vdd pch W=1u L=0.18u
Cl1341 s1341 0 10f
Mn1342 s1342 s1341 0 0 nch W=0.5u L=0.18u
Mp1342 s1342 s1341 vdd vdd pch W=1u L=0.18u
Cl1342 s1342 0 10f
Mn1343 s1343 s1342 0 0 nch W=0.5u L=0.18u
Mp1343 s1343 s1342 vdd vdd pch W=1u L=0.18u
Cl1343 s1343 0 10f
Mn1344 s1344 s1343 0 0 nch W=0.5u L=0.18u
Mp1344 s1344 s1343 vdd vdd pch W=1u L=0.18u
Cl1344 s1344 0 10f
Mn1345 s1345 s1344 0 0 nch W=0.5u L=0.18u
Mp1345 s1345 s1344 vdd vdd pch W=1u L=0.18u
Cl1345 s1345 0 10f
Mn1346 s1346 s1345 0 0 nch W=0.5u L=0.18u
Mp1346 s1346 s1345 vdd vdd pch W=1u L=0.18u
Cl1346 s1346 0 10f
Mn1347 s1347 s1346 0 0 nch W=0.5u L=0.18u
Mp1347 s1347 s1346 vdd vdd pch W=1u L=0.18u
Cl1347 s1347 0 10f
Mn1348 s1348 s1347 0 0 nch W=0.5u L=0.18u
Mp1348 s1348 s1347 vdd vdd pch W=1u L=0.18u
Cl1348 s1348 0 10f
Mn1349 s1349 s1348 0 0 nch W=0.5u L=0.18u
Mp1349 s1349 s1348 vdd vdd pch W=1u L=0.18u
Cl1349 s1349 0 10f
Mn1350 s1350 s1349 0 0 nch W=0.5u L=0.18u
Mp1350 s1350 s1349 vdd vdd pch W=1u L=0.18u
Cl1350 s1350 0 10f
Mn1351 s1351 s1350 0 0 nch W=0.5u L=0.18u
Mp1351 s1351 s1350 vdd vdd pch W=1u L=0.18u
Cl1351 s1351 0 10f
Mn1352 s1352 s1351 0 0 nch W=0.5u L=0.18u
Mp1352 s1352 s1351 vdd vdd pch W=1u L=0.18u
Cl1352 s1352 0 10f
Mn1353 s1353 s1352 0 0 nch W=0.5u L=0.18u
Mp1353 s1353 s1352 vdd vdd pch W=1u L=0.18u
Cl1353 s1353 0 10f
Mn1354 s1354 s1353 0 0 nch W=0.5u L=0.18u
Mp1354 s1354 s1353 vdd vdd pch W=1u L=0.18u
Cl1354 s1354 0 10f
Mn1355 s1355 s1354 0 0 nch W=0.5u L=0.18u
Mp1355 s1355 s1354 vdd vdd pch W=1u L=0.18u
Cl1355 s1355 0 10f
Mn1356 s1356 s1355 0 0 nch W=0.5u L=0.18u
Mp1356 s1356 s1355 vdd vdd pch W=1u L=0.18u
Cl1356 s1356 0 10f
Mn1357 s1357 s1356 0 0 nch W=0.5u L=0.18u
Mp1357 s1357 s1356 vdd vdd pch W=1u L=0.18u
Cl1357 s1357 0 10f
Mn1358 s1358 s1357 0 0 nch W=0.5u L=0.18u
Mp1358 s1358 s1357 vdd vdd pch W=1u L=0.18u
Cl1358 s1358 0 10f
Mn1359 s1359 s1358 0 0 nch W=0.5u L=0.18u
Mp1359 s1359 s1358 vdd vdd pch W=1u L=0.18u
Cl1359 s1359 0 10f
Mn1360 s1360 s1359 0 0 nch W=0.5u L=0.18u
Mp1360 s1360 s1359 vdd vdd pch W=1u L=0.18u
Cl1360 s1360 0 10f
Mn1361 s1361 s1360 0 0 nch W=0.5u L=0.18u
Mp1361 s1361 s1360 vdd vdd pch W=1u L=0.18u
Cl1361 s1361 0 10f
Mn1362 s1362 s1361 0 0 nch W=0.5u L=0.18u
Mp1362 s1362 s1361 vdd vdd pch W=1u L=0.18u
Cl1362 s1362 0 10f
Mn1363 s1363 s1362 0 0 nch W=0.5u L=0.18u
Mp1363 s1363 s1362 vdd vdd pch W=1u L=0.18u
Cl1363 s1363 0 10f
Mn1364 s1364 s1363 0 0 nch W=0.5u L=0.18u
Mp1364 s1364 s1363 vdd vdd pch W=1u L=0.18u
Cl1364 s1364 0 10f
Mn1365 s1365 s1364 0 0 nch W=0.5u L=0.18u
Mp1365 s1365 s1364 vdd vdd pch W=1u L=0.18u
Cl1365 s1365 0 10f
Mn1366 s1366 s1365 0 0 nch W=0.5u L=0.18u
Mp1366 s1366 s1365 vdd vdd pch W=1u L=0.18u
Cl1366 s1366 0 10f
Mn1367 s1367 s1366 0 0 nch W=0.5u L=0.18u
Mp1367 s1367 s1366 vdd vdd pch W=1u L=0.18u
Cl1367 s1367 0 10f
Mn1368 s1368 s1367 0 0 nch W=0.5u L=0.18u
Mp1368 s1368 s1367 vdd vdd pch W=1u L=0.18u
Cl1368 s1368 0 10f
Mn1369 s1369 s1368 0 0 nch W=0.5u L=0.18u
Mp1369 s1369 s1368 vdd vdd pch W=1u L=0.18u
Cl1369 s1369 0 10f
Mn1370 s1370 s1369 0 0 nch W=0.5u L=0.18u
Mp1370 s1370 s1369 vdd vdd pch W=1u L=0.18u
Cl1370 s1370 0 10f
Mn1371 s1371 s1370 0 0 nch W=0.5u L=0.18u
Mp1371 s1371 s1370 vdd vdd pch W=1u L=0.18u
Cl1371 s1371 0 10f
Mn1372 s1372 s1371 0 0 nch W=0.5u L=0.18u
Mp1372 s1372 s1371 vdd vdd pch W=1u L=0.18u
Cl1372 s1372 0 10f
Mn1373 s1373 s1372 0 0 nch W=0.5u L=0.18u
Mp1373 s1373 s1372 vdd vdd pch W=1u L=0.18u
Cl1373 s1373 0 10f
Mn1374 s1374 s1373 0 0 nch W=0.5u L=0.18u
Mp1374 s1374 s1373 vdd vdd pch W=1u L=0.18u
Cl1374 s1374 0 10f
Mn1375 s1375 s1374 0 0 nch W=0.5u L=0.18u
Mp1375 s1375 s1374 vdd vdd pch W=1u L=0.18u
Cl1375 s1375 0 10f
Mn1376 s1376 s1375 0 0 nch W=0.5u L=0.18u
Mp1376 s1376 s1375 vdd vdd pch W=1u L=0.18u
Cl1376 s1376 0 10f
Mn1377 s1377 s1376 0 0 nch W=0.5u L=0.18u
Mp1377 s1377 s1376 vdd vdd pch W=1u L=0.18u
Cl1377 s1377 0 10f
Mn1378 s1378 s1377 0 0 nch W=0.5u L=0.18u
Mp1378 s1378 s1377 vdd vdd pch W=1u L=0.18u
Cl1378 s1378 0 10f
Mn1379 s1379 s1378 0 0 nch W=0.5u L=0.18u
Mp1379 s1379 s1378 vdd vdd pch W=1u L=0.18u
Cl1379 s1379 0 10f
Mn1380 s1380 s1379 0 0 nch W=0.5u L=0.18u
Mp1380 s1380 s1379 vdd vdd pch W=1u L=0.18u
Cl1380 s1380 0 10f
Mn1381 s1381 s1380 0 0 nch W=0.5u L=0.18u
Mp1381 s1381 s1380 vdd vdd pch W=1u L=0.18u
Cl1381 s1381 0 10f
Mn1382 s1382 s1381 0 0 nch W=0.5u L=0.18u
Mp1382 s1382 s1381 vdd vdd pch W=1u L=0.18u
Cl1382 s1382 0 10f
Mn1383 s1383 s1382 0 0 nch W=0.5u L=0.18u
Mp1383 s1383 s1382 vdd vdd pch W=1u L=0.18u
Cl1383 s1383 0 10f
Mn1384 s1384 s1383 0 0 nch W=0.5u L=0.18u
Mp1384 s1384 s1383 vdd vdd pch W=1u L=0.18u
Cl1384 s1384 0 10f
Mn1385 s1385 s1384 0 0 nch W=0.5u L=0.18u
Mp1385 s1385 s1384 vdd vdd pch W=1u L=0.18u
Cl1385 s1385 0 10f
Mn1386 s1386 s1385 0 0 nch W=0.5u L=0.18u
Mp1386 s1386 s1385 vdd vdd pch W=1u L=0.18u
Cl1386 s1386 0 10f
Mn1387 s1387 s1386 0 0 nch W=0.5u L=0.18u
Mp1387 s1387 s1386 vdd vdd pch W=1u L=0.18u
Cl1387 s1387 0 10f
Mn1388 s1388 s1387 0 0 nch W=0.5u L=0.18u
Mp1388 s1388 s1387 vdd vdd pch W=1u L=0.18u
Cl1388 s1388 0 10f
Mn1389 s1389 s1388 0 0 nch W=0.5u L=0.18u
Mp1389 s1389 s1388 vdd vdd pch W=1u L=0.18u
Cl1389 s1389 0 10f
Mn1390 s1390 s1389 0 0 nch W=0.5u L=0.18u
Mp1390 s1390 s1389 vdd vdd pch W=1u L=0.18u
Cl1390 s1390 0 10f
Mn1391 s1391 s1390 0 0 nch W=0.5u L=0.18u
Mp1391 s1391 s1390 vdd vdd pch W=1u L=0.18u
Cl1391 s1391 0 10f
Mn1392 s1392 s1391 0 0 nch W=0.5u L=0.18u
Mp1392 s1392 s1391 vdd vdd pch W=1u L=0.18u
Cl1392 s1392 0 10f
Mn1393 s1393 s1392 0 0 nch W=0.5u L=0.18u
Mp1393 s1393 s1392 vdd vdd pch W=1u L=0.18u
Cl1393 s1393 0 10f
Mn1394 s1394 s1393 0 0 nch W=0.5u L=0.18u
Mp1394 s1394 s1393 vdd vdd pch W=1u L=0.18u
Cl1394 s1394 0 10f
Mn1395 s1395 s1394 0 0 nch W=0.5u L=0.18u
Mp1395 s1395 s1394 vdd vdd pch W=1u L=0.18u
Cl1395 s1395 0 10f
Mn1396 s1396 s1395 0 0 nch W=0.5u L=0.18u
Mp1396 s1396 s1395 vdd vdd pch W=1u L=0.18u
Cl1396 s1396 0 10f
Mn1397 s1397 s1396 0 0 nch W=0.5u L=0.18u
Mp1397 s1397 s1396 vdd vdd pch W=1u L=0.18u
Cl1397 s1397 0 10f
Mn1398 s1398 s1397 0 0 nch W=0.5u L=0.18u
Mp1398 s1398 s1397 vdd vdd pch W=1u L=0.18u
Cl1398 s1398 0 10f
Mn1399 s1399 s1398 0 0 nch W=0.5u L=0.18u
Mp1399 s1399 s1398 vdd vdd pch W=1u L=0.18u
Cl1399 s1399 0 10f
Mn1400 s1400 s1399 0 0 nch W=0.5u L=0.18u
Mp1400 s1400 s1399 vdd vdd pch W=1u L=0.18u
Cl1400 s1400 0 10f
Mn1401 s1401 s1400 0 0 nch W=0.5u L=0.18u
Mp1401 s1401 s1400 vdd vdd pch W=1u L=0.18u
Cl1401 s1401 0 10f
Mn1402 s1402 s1401 0 0 nch W=0.5u L=0.18u
Mp1402 s1402 s1401 vdd vdd pch W=1u L=0.18u
Cl1402 s1402 0 10f
Mn1403 s1403 s1402 0 0 nch W=0.5u L=0.18u
Mp1403 s1403 s1402 vdd vdd pch W=1u L=0.18u
Cl1403 s1403 0 10f
Mn1404 s1404 s1403 0 0 nch W=0.5u L=0.18u
Mp1404 s1404 s1403 vdd vdd pch W=1u L=0.18u
Cl1404 s1404 0 10f
Mn1405 s1405 s1404 0 0 nch W=0.5u L=0.18u
Mp1405 s1405 s1404 vdd vdd pch W=1u L=0.18u
Cl1405 s1405 0 10f
Mn1406 s1406 s1405 0 0 nch W=0.5u L=0.18u
Mp1406 s1406 s1405 vdd vdd pch W=1u L=0.18u
Cl1406 s1406 0 10f
Mn1407 s1407 s1406 0 0 nch W=0.5u L=0.18u
Mp1407 s1407 s1406 vdd vdd pch W=1u L=0.18u
Cl1407 s1407 0 10f
Mn1408 s1408 s1407 0 0 nch W=0.5u L=0.18u
Mp1408 s1408 s1407 vdd vdd pch W=1u L=0.18u
Cl1408 s1408 0 10f
Mn1409 s1409 s1408 0 0 nch W=0.5u L=0.18u
Mp1409 s1409 s1408 vdd vdd pch W=1u L=0.18u
Cl1409 s1409 0 10f
Mn1410 s1410 s1409 0 0 nch W=0.5u L=0.18u
Mp1410 s1410 s1409 vdd vdd pch W=1u L=0.18u
Cl1410 s1410 0 10f
Mn1411 s1411 s1410 0 0 nch W=0.5u L=0.18u
Mp1411 s1411 s1410 vdd vdd pch W=1u L=0.18u
Cl1411 s1411 0 10f
Mn1412 s1412 s1411 0 0 nch W=0.5u L=0.18u
Mp1412 s1412 s1411 vdd vdd pch W=1u L=0.18u
Cl1412 s1412 0 10f
Mn1413 s1413 s1412 0 0 nch W=0.5u L=0.18u
Mp1413 s1413 s1412 vdd vdd pch W=1u L=0.18u
Cl1413 s1413 0 10f
Mn1414 s1414 s1413 0 0 nch W=0.5u L=0.18u
Mp1414 s1414 s1413 vdd vdd pch W=1u L=0.18u
Cl1414 s1414 0 10f
Mn1415 s1415 s1414 0 0 nch W=0.5u L=0.18u
Mp1415 s1415 s1414 vdd vdd pch W=1u L=0.18u
Cl1415 s1415 0 10f
Mn1416 s1416 s1415 0 0 nch W=0.5u L=0.18u
Mp1416 s1416 s1415 vdd vdd pch W=1u L=0.18u
Cl1416 s1416 0 10f
Mn1417 s1417 s1416 0 0 nch W=0.5u L=0.18u
Mp1417 s1417 s1416 vdd vdd pch W=1u L=0.18u
Cl1417 s1417 0 10f
Mn1418 s1418 s1417 0 0 nch W=0.5u L=0.18u
Mp1418 s1418 s1417 vdd vdd pch W=1u L=0.18u
Cl1418 s1418 0 10f
Mn1419 s1419 s1418 0 0 nch W=0.5u L=0.18u
Mp1419 s1419 s1418 vdd vdd pch W=1u L=0.18u
Cl1419 s1419 0 10f
Mn1420 s1420 s1419 0 0 nch W=0.5u L=0.18u
Mp1420 s1420 s1419 vdd vdd pch W=1u L=0.18u
Cl1420 s1420 0 10f
Mn1421 s1421 s1420 0 0 nch W=0.5u L=0.18u
Mp1421 s1421 s1420 vdd vdd pch W=1u L=0.18u
Cl1421 s1421 0 10f
Mn1422 s1422 s1421 0 0 nch W=0.5u L=0.18u
Mp1422 s1422 s1421 vdd vdd pch W=1u L=0.18u
Cl1422 s1422 0 10f
Mn1423 s1423 s1422 0 0 nch W=0.5u L=0.18u
Mp1423 s1423 s1422 vdd vdd pch W=1u L=0.18u
Cl1423 s1423 0 10f
Mn1424 s1424 s1423 0 0 nch W=0.5u L=0.18u
Mp1424 s1424 s1423 vdd vdd pch W=1u L=0.18u
Cl1424 s1424 0 10f
Mn1425 s1425 s1424 0 0 nch W=0.5u L=0.18u
Mp1425 s1425 s1424 vdd vdd pch W=1u L=0.18u
Cl1425 s1425 0 10f
Mn1426 s1426 s1425 0 0 nch W=0.5u L=0.18u
Mp1426 s1426 s1425 vdd vdd pch W=1u L=0.18u
Cl1426 s1426 0 10f
Mn1427 s1427 s1426 0 0 nch W=0.5u L=0.18u
Mp1427 s1427 s1426 vdd vdd pch W=1u L=0.18u
Cl1427 s1427 0 10f
Mn1428 s1428 s1427 0 0 nch W=0.5u L=0.18u
Mp1428 s1428 s1427 vdd vdd pch W=1u L=0.18u
Cl1428 s1428 0 10f
Mn1429 s1429 s1428 0 0 nch W=0.5u L=0.18u
Mp1429 s1429 s1428 vdd vdd pch W=1u L=0.18u
Cl1429 s1429 0 10f
Mn1430 s1430 s1429 0 0 nch W=0.5u L=0.18u
Mp1430 s1430 s1429 vdd vdd pch W=1u L=0.18u
Cl1430 s1430 0 10f
Mn1431 s1431 s1430 0 0 nch W=0.5u L=0.18u
Mp1431 s1431 s1430 vdd vdd pch W=1u L=0.18u
Cl1431 s1431 0 10f
Mn1432 s1432 s1431 0 0 nch W=0.5u L=0.18u
Mp1432 s1432 s1431 vdd vdd pch W=1u L=0.18u
Cl1432 s1432 0 10f
Mn1433 s1433 s1432 0 0 nch W=0.5u L=0.18u
Mp1433 s1433 s1432 vdd vdd pch W=1u L=0.18u
Cl1433 s1433 0 10f
Mn1434 s1434 s1433 0 0 nch W=0.5u L=0.18u
Mp1434 s1434 s1433 vdd vdd pch W=1u L=0.18u
Cl1434 s1434 0 10f
Mn1435 s1435 s1434 0 0 nch W=0.5u L=0.18u
Mp1435 s1435 s1434 vdd vdd pch W=1u L=0.18u
Cl1435 s1435 0 10f
Mn1436 s1436 s1435 0 0 nch W=0.5u L=0.18u
Mp1436 s1436 s1435 vdd vdd pch W=1u L=0.18u
Cl1436 s1436 0 10f
Mn1437 s1437 s1436 0 0 nch W=0.5u L=0.18u
Mp1437 s1437 s1436 vdd vdd pch W=1u L=0.18u
Cl1437 s1437 0 10f
Mn1438 s1438 s1437 0 0 nch W=0.5u L=0.18u
Mp1438 s1438 s1437 vdd vdd pch W=1u L=0.18u
Cl1438 s1438 0 10f
Mn1439 s1439 s1438 0 0 nch W=0.5u L=0.18u
Mp1439 s1439 s1438 vdd vdd pch W=1u L=0.18u
Cl1439 s1439 0 10f
Mn1440 s1440 s1439 0 0 nch W=0.5u L=0.18u
Mp1440 s1440 s1439 vdd vdd pch W=1u L=0.18u
Cl1440 s1440 0 10f
Mn1441 s1441 s1440 0 0 nch W=0.5u L=0.18u
Mp1441 s1441 s1440 vdd vdd pch W=1u L=0.18u
Cl1441 s1441 0 10f
Mn1442 s1442 s1441 0 0 nch W=0.5u L=0.18u
Mp1442 s1442 s1441 vdd vdd pch W=1u L=0.18u
Cl1442 s1442 0 10f
Mn1443 s1443 s1442 0 0 nch W=0.5u L=0.18u
Mp1443 s1443 s1442 vdd vdd pch W=1u L=0.18u
Cl1443 s1443 0 10f
Mn1444 s1444 s1443 0 0 nch W=0.5u L=0.18u
Mp1444 s1444 s1443 vdd vdd pch W=1u L=0.18u
Cl1444 s1444 0 10f
Mn1445 s1445 s1444 0 0 nch W=0.5u L=0.18u
Mp1445 s1445 s1444 vdd vdd pch W=1u L=0.18u
Cl1445 s1445 0 10f
Mn1446 s1446 s1445 0 0 nch W=0.5u L=0.18u
Mp1446 s1446 s1445 vdd vdd pch W=1u L=0.18u
Cl1446 s1446 0 10f
Mn1447 s1447 s1446 0 0 nch W=0.5u L=0.18u
Mp1447 s1447 s1446 vdd vdd pch W=1u L=0.18u
Cl1447 s1447 0 10f
Mn1448 s1448 s1447 0 0 nch W=0.5u L=0.18u
Mp1448 s1448 s1447 vdd vdd pch W=1u L=0.18u
Cl1448 s1448 0 10f
Mn1449 s1449 s1448 0 0 nch W=0.5u L=0.18u
Mp1449 s1449 s1448 vdd vdd pch W=1u L=0.18u
Cl1449 s1449 0 10f
Mn1450 s1450 s1449 0 0 nch W=0.5u L=0.18u
Mp1450 s1450 s1449 vdd vdd pch W=1u L=0.18u
Cl1450 s1450 0 10f
Mn1451 s1451 s1450 0 0 nch W=0.5u L=0.18u
Mp1451 s1451 s1450 vdd vdd pch W=1u L=0.18u
Cl1451 s1451 0 10f
Mn1452 s1452 s1451 0 0 nch W=0.5u L=0.18u
Mp1452 s1452 s1451 vdd vdd pch W=1u L=0.18u
Cl1452 s1452 0 10f
Mn1453 s1453 s1452 0 0 nch W=0.5u L=0.18u
Mp1453 s1453 s1452 vdd vdd pch W=1u L=0.18u
Cl1453 s1453 0 10f
Mn1454 s1454 s1453 0 0 nch W=0.5u L=0.18u
Mp1454 s1454 s1453 vdd vdd pch W=1u L=0.18u
Cl1454 s1454 0 10f
Mn1455 s1455 s1454 0 0 nch W=0.5u L=0.18u
Mp1455 s1455 s1454 vdd vdd pch W=1u L=0.18u
Cl1455 s1455 0 10f
Mn1456 s1456 s1455 0 0 nch W=0.5u L=0.18u
Mp1456 s1456 s1455 vdd vdd pch W=1u L=0.18u
Cl1456 s1456 0 10f
Mn1457 s1457 s1456 0 0 nch W=0.5u L=0.18u
Mp1457 s1457 s1456 vdd vdd pch W=1u L=0.18u
Cl1457 s1457 0 10f
Mn1458 s1458 s1457 0 0 nch W=0.5u L=0.18u
Mp1458 s1458 s1457 vdd vdd pch W=1u L=0.18u
Cl1458 s1458 0 10f
Mn1459 s1459 s1458 0 0 nch W=0.5u L=0.18u
Mp1459 s1459 s1458 vdd vdd pch W=1u L=0.18u
Cl1459 s1459 0 10f
Mn1460 s1460 s1459 0 0 nch W=0.5u L=0.18u
Mp1460 s1460 s1459 vdd vdd pch W=1u L=0.18u
Cl1460 s1460 0 10f
Mn1461 s1461 s1460 0 0 nch W=0.5u L=0.18u
Mp1461 s1461 s1460 vdd vdd pch W=1u L=0.18u
Cl1461 s1461 0 10f
Mn1462 s1462 s1461 0 0 nch W=0.5u L=0.18u
Mp1462 s1462 s1461 vdd vdd pch W=1u L=0.18u
Cl1462 s1462 0 10f
Mn1463 s1463 s1462 0 0 nch W=0.5u L=0.18u
Mp1463 s1463 s1462 vdd vdd pch W=1u L=0.18u
Cl1463 s1463 0 10f
Mn1464 s1464 s1463 0 0 nch W=0.5u L=0.18u
Mp1464 s1464 s1463 vdd vdd pch W=1u L=0.18u
Cl1464 s1464 0 10f
Mn1465 s1465 s1464 0 0 nch W=0.5u L=0.18u
Mp1465 s1465 s1464 vdd vdd pch W=1u L=0.18u
Cl1465 s1465 0 10f
Mn1466 s1466 s1465 0 0 nch W=0.5u L=0.18u
Mp1466 s1466 s1465 vdd vdd pch W=1u L=0.18u
Cl1466 s1466 0 10f
Mn1467 s1467 s1466 0 0 nch W=0.5u L=0.18u
Mp1467 s1467 s1466 vdd vdd pch W=1u L=0.18u
Cl1467 s1467 0 10f
Mn1468 s1468 s1467 0 0 nch W=0.5u L=0.18u
Mp1468 s1468 s1467 vdd vdd pch W=1u L=0.18u
Cl1468 s1468 0 10f
Mn1469 s1469 s1468 0 0 nch W=0.5u L=0.18u
Mp1469 s1469 s1468 vdd vdd pch W=1u L=0.18u
Cl1469 s1469 0 10f
Mn1470 s1470 s1469 0 0 nch W=0.5u L=0.18u
Mp1470 s1470 s1469 vdd vdd pch W=1u L=0.18u
Cl1470 s1470 0 10f
Mn1471 s1471 s1470 0 0 nch W=0.5u L=0.18u
Mp1471 s1471 s1470 vdd vdd pch W=1u L=0.18u
Cl1471 s1471 0 10f
Mn1472 s1472 s1471 0 0 nch W=0.5u L=0.18u
Mp1472 s1472 s1471 vdd vdd pch W=1u L=0.18u
Cl1472 s1472 0 10f
Mn1473 s1473 s1472 0 0 nch W=0.5u L=0.18u
Mp1473 s1473 s1472 vdd vdd pch W=1u L=0.18u
Cl1473 s1473 0 10f
Mn1474 s1474 s1473 0 0 nch W=0.5u L=0.18u
Mp1474 s1474 s1473 vdd vdd pch W=1u L=0.18u
Cl1474 s1474 0 10f
Mn1475 s1475 s1474 0 0 nch W=0.5u L=0.18u
Mp1475 s1475 s1474 vdd vdd pch W=1u L=0.18u
Cl1475 s1475 0 10f
Mn1476 s1476 s1475 0 0 nch W=0.5u L=0.18u
Mp1476 s1476 s1475 vdd vdd pch W=1u L=0.18u
Cl1476 s1476 0 10f
Mn1477 s1477 s1476 0 0 nch W=0.5u L=0.18u
Mp1477 s1477 s1476 vdd vdd pch W=1u L=0.18u
Cl1477 s1477 0 10f
Mn1478 s1478 s1477 0 0 nch W=0.5u L=0.18u
Mp1478 s1478 s1477 vdd vdd pch W=1u L=0.18u
Cl1478 s1478 0 10f
Mn1479 s1479 s1478 0 0 nch W=0.5u L=0.18u
Mp1479 s1479 s1478 vdd vdd pch W=1u L=0.18u
Cl1479 s1479 0 10f
Mn1480 s1480 s1479 0 0 nch W=0.5u L=0.18u
Mp1480 s1480 s1479 vdd vdd pch W=1u L=0.18u
Cl1480 s1480 0 10f
Mn1481 s1481 s1480 0 0 nch W=0.5u L=0.18u
Mp1481 s1481 s1480 vdd vdd pch W=1u L=0.18u
Cl1481 s1481 0 10f
Mn1482 s1482 s1481 0 0 nch W=0.5u L=0.18u
Mp1482 s1482 s1481 vdd vdd pch W=1u L=0.18u
Cl1482 s1482 0 10f
Mn1483 s1483 s1482 0 0 nch W=0.5u L=0.18u
Mp1483 s1483 s1482 vdd vdd pch W=1u L=0.18u
Cl1483 s1483 0 10f
Mn1484 s1484 s1483 0 0 nch W=0.5u L=0.18u
Mp1484 s1484 s1483 vdd vdd pch W=1u L=0.18u
Cl1484 s1484 0 10f
Mn1485 s1485 s1484 0 0 nch W=0.5u L=0.18u
Mp1485 s1485 s1484 vdd vdd pch W=1u L=0.18u
Cl1485 s1485 0 10f
Mn1486 s1486 s1485 0 0 nch W=0.5u L=0.18u
Mp1486 s1486 s1485 vdd vdd pch W=1u L=0.18u
Cl1486 s1486 0 10f
Mn1487 s1487 s1486 0 0 nch W=0.5u L=0.18u
Mp1487 s1487 s1486 vdd vdd pch W=1u L=0.18u
Cl1487 s1487 0 10f
Mn1488 s1488 s1487 0 0 nch W=0.5u L=0.18u
Mp1488 s1488 s1487 vdd vdd pch W=1u L=0.18u
Cl1488 s1488 0 10f
Mn1489 s1489 s1488 0 0 nch W=0.5u L=0.18u
Mp1489 s1489 s1488 vdd vdd pch W=1u L=0.18u
Cl1489 s1489 0 10f
Mn1490 s1490 s1489 0 0 nch W=0.5u L=0.18u
Mp1490 s1490 s1489 vdd vdd pch W=1u L=0.18u
Cl1490 s1490 0 10f
Mn1491 s1491 s1490 0 0 nch W=0.5u L=0.18u
Mp1491 s1491 s1490 vdd vdd pch W=1u L=0.18u
Cl1491 s1491 0 10f
Mn1492 s1492 s1491 0 0 nch W=0.5u L=0.18u
Mp1492 s1492 s1491 vdd vdd pch W=1u L=0.18u
Cl1492 s1492 0 10f
Mn1493 s1493 s1492 0 0 nch W=0.5u L=0.18u
Mp1493 s1493 s1492 vdd vdd pch W=1u L=0.18u
Cl1493 s1493 0 10f
Mn1494 s1494 s1493 0 0 nch W=0.5u L=0.18u
Mp1494 s1494 s1493 vdd vdd pch W=1u L=0.18u
Cl1494 s1494 0 10f
Mn1495 s1495 s1494 0 0 nch W=0.5u L=0.18u
Mp1495 s1495 s1494 vdd vdd pch W=1u L=0.18u
Cl1495 s1495 0 10f
Mn1496 s1496 s1495 0 0 nch W=0.5u L=0.18u
Mp1496 s1496 s1495 vdd vdd pch W=1u L=0.18u
Cl1496 s1496 0 10f
Mn1497 s1497 s1496 0 0 nch W=0.5u L=0.18u
Mp1497 s1497 s1496 vdd vdd pch W=1u L=0.18u
Cl1497 s1497 0 10f
Mn1498 s1498 s1497 0 0 nch W=0.5u L=0.18u
Mp1498 s1498 s1497 vdd vdd pch W=1u L=0.18u
Cl1498 s1498 0 10f
Mn1499 s1499 s1498 0 0 nch W=0.5u L=0.18u
Mp1499 s1499 s1498 vdd vdd pch W=1u L=0.18u
Cl1499 s1499 0 10f
Mn1500 s1500 s1499 0 0 nch W=0.5u L=0.18u
Mp1500 s1500 s1499 vdd vdd pch W=1u L=0.18u
Cl1500 s1500 0 10f
Mn1501 s1501 s1500 0 0 nch W=0.5u L=0.18u
Mp1501 s1501 s1500 vdd vdd pch W=1u L=0.18u
Cl1501 s1501 0 10f
Mn1502 s1502 s1501 0 0 nch W=0.5u L=0.18u
Mp1502 s1502 s1501 vdd vdd pch W=1u L=0.18u
Cl1502 s1502 0 10f
Mn1503 s1503 s1502 0 0 nch W=0.5u L=0.18u
Mp1503 s1503 s1502 vdd vdd pch W=1u L=0.18u
Cl1503 s1503 0 10f
Mn1504 s1504 s1503 0 0 nch W=0.5u L=0.18u
Mp1504 s1504 s1503 vdd vdd pch W=1u L=0.18u
Cl1504 s1504 0 10f
Mn1505 s1505 s1504 0 0 nch W=0.5u L=0.18u
Mp1505 s1505 s1504 vdd vdd pch W=1u L=0.18u
Cl1505 s1505 0 10f
Mn1506 s1506 s1505 0 0 nch W=0.5u L=0.18u
Mp1506 s1506 s1505 vdd vdd pch W=1u L=0.18u
Cl1506 s1506 0 10f
Mn1507 s1507 s1506 0 0 nch W=0.5u L=0.18u
Mp1507 s1507 s1506 vdd vdd pch W=1u L=0.18u
Cl1507 s1507 0 10f
Mn1508 s1508 s1507 0 0 nch W=0.5u L=0.18u
Mp1508 s1508 s1507 vdd vdd pch W=1u L=0.18u
Cl1508 s1508 0 10f
Mn1509 s1509 s1508 0 0 nch W=0.5u L=0.18u
Mp1509 s1509 s1508 vdd vdd pch W=1u L=0.18u
Cl1509 s1509 0 10f
Mn1510 s1510 s1509 0 0 nch W=0.5u L=0.18u
Mp1510 s1510 s1509 vdd vdd pch W=1u L=0.18u
Cl1510 s1510 0 10f
Mn1511 s1511 s1510 0 0 nch W=0.5u L=0.18u
Mp1511 s1511 s1510 vdd vdd pch W=1u L=0.18u
Cl1511 s1511 0 10f
Mn1512 s1512 s1511 0 0 nch W=0.5u L=0.18u
Mp1512 s1512 s1511 vdd vdd pch W=1u L=0.18u
Cl1512 s1512 0 10f
Mn1513 s1513 s1512 0 0 nch W=0.5u L=0.18u
Mp1513 s1513 s1512 vdd vdd pch W=1u L=0.18u
Cl1513 s1513 0 10f
Mn1514 s1514 s1513 0 0 nch W=0.5u L=0.18u
Mp1514 s1514 s1513 vdd vdd pch W=1u L=0.18u
Cl1514 s1514 0 10f
Mn1515 s1515 s1514 0 0 nch W=0.5u L=0.18u
Mp1515 s1515 s1514 vdd vdd pch W=1u L=0.18u
Cl1515 s1515 0 10f
Mn1516 s1516 s1515 0 0 nch W=0.5u L=0.18u
Mp1516 s1516 s1515 vdd vdd pch W=1u L=0.18u
Cl1516 s1516 0 10f
Mn1517 s1517 s1516 0 0 nch W=0.5u L=0.18u
Mp1517 s1517 s1516 vdd vdd pch W=1u L=0.18u
Cl1517 s1517 0 10f
Mn1518 s1518 s1517 0 0 nch W=0.5u L=0.18u
Mp1518 s1518 s1517 vdd vdd pch W=1u L=0.18u
Cl1518 s1518 0 10f
Mn1519 s1519 s1518 0 0 nch W=0.5u L=0.18u
Mp1519 s1519 s1518 vdd vdd pch W=1u L=0.18u
Cl1519 s1519 0 10f
Mn1520 s1520 s1519 0 0 nch W=0.5u L=0.18u
Mp1520 s1520 s1519 vdd vdd pch W=1u L=0.18u
Cl1520 s1520 0 10f
Mn1521 s1521 s1520 0 0 nch W=0.5u L=0.18u
Mp1521 s1521 s1520 vdd vdd pch W=1u L=0.18u
Cl1521 s1521 0 10f
Mn1522 s1522 s1521 0 0 nch W=0.5u L=0.18u
Mp1522 s1522 s1521 vdd vdd pch W=1u L=0.18u
Cl1522 s1522 0 10f
Mn1523 s1523 s1522 0 0 nch W=0.5u L=0.18u
Mp1523 s1523 s1522 vdd vdd pch W=1u L=0.18u
Cl1523 s1523 0 10f
Mn1524 s1524 s1523 0 0 nch W=0.5u L=0.18u
Mp1524 s1524 s1523 vdd vdd pch W=1u L=0.18u
Cl1524 s1524 0 10f
Mn1525 s1525 s1524 0 0 nch W=0.5u L=0.18u
Mp1525 s1525 s1524 vdd vdd pch W=1u L=0.18u
Cl1525 s1525 0 10f
Mn1526 s1526 s1525 0 0 nch W=0.5u L=0.18u
Mp1526 s1526 s1525 vdd vdd pch W=1u L=0.18u
Cl1526 s1526 0 10f
Mn1527 s1527 s1526 0 0 nch W=0.5u L=0.18u
Mp1527 s1527 s1526 vdd vdd pch W=1u L=0.18u
Cl1527 s1527 0 10f
Mn1528 s1528 s1527 0 0 nch W=0.5u L=0.18u
Mp1528 s1528 s1527 vdd vdd pch W=1u L=0.18u
Cl1528 s1528 0 10f
Mn1529 s1529 s1528 0 0 nch W=0.5u L=0.18u
Mp1529 s1529 s1528 vdd vdd pch W=1u L=0.18u
Cl1529 s1529 0 10f
Mn1530 s1530 s1529 0 0 nch W=0.5u L=0.18u
Mp1530 s1530 s1529 vdd vdd pch W=1u L=0.18u
Cl1530 s1530 0 10f
Mn1531 s1531 s1530 0 0 nch W=0.5u L=0.18u
Mp1531 s1531 s1530 vdd vdd pch W=1u L=0.18u
Cl1531 s1531 0 10f
Mn1532 s1532 s1531 0 0 nch W=0.5u L=0.18u
Mp1532 s1532 s1531 vdd vdd pch W=1u L=0.18u
Cl1532 s1532 0 10f
Mn1533 s1533 s1532 0 0 nch W=0.5u L=0.18u
Mp1533 s1533 s1532 vdd vdd pch W=1u L=0.18u
Cl1533 s1533 0 10f
Mn1534 s1534 s1533 0 0 nch W=0.5u L=0.18u
Mp1534 s1534 s1533 vdd vdd pch W=1u L=0.18u
Cl1534 s1534 0 10f
Mn1535 s1535 s1534 0 0 nch W=0.5u L=0.18u
Mp1535 s1535 s1534 vdd vdd pch W=1u L=0.18u
Cl1535 s1535 0 10f
Mn1536 s1536 s1535 0 0 nch W=0.5u L=0.18u
Mp1536 s1536 s1535 vdd vdd pch W=1u L=0.18u
Cl1536 s1536 0 10f
Mn1537 s1537 s1536 0 0 nch W=0.5u L=0.18u
Mp1537 s1537 s1536 vdd vdd pch W=1u L=0.18u
Cl1537 s1537 0 10f
Mn1538 s1538 s1537 0 0 nch W=0.5u L=0.18u
Mp1538 s1538 s1537 vdd vdd pch W=1u L=0.18u
Cl1538 s1538 0 10f
Mn1539 s1539 s1538 0 0 nch W=0.5u L=0.18u
Mp1539 s1539 s1538 vdd vdd pch W=1u L=0.18u
Cl1539 s1539 0 10f
Mn1540 s1540 s1539 0 0 nch W=0.5u L=0.18u
Mp1540 s1540 s1539 vdd vdd pch W=1u L=0.18u
Cl1540 s1540 0 10f
Mn1541 s1541 s1540 0 0 nch W=0.5u L=0.18u
Mp1541 s1541 s1540 vdd vdd pch W=1u L=0.18u
Cl1541 s1541 0 10f
Mn1542 s1542 s1541 0 0 nch W=0.5u L=0.18u
Mp1542 s1542 s1541 vdd vdd pch W=1u L=0.18u
Cl1542 s1542 0 10f
Mn1543 s1543 s1542 0 0 nch W=0.5u L=0.18u
Mp1543 s1543 s1542 vdd vdd pch W=1u L=0.18u
Cl1543 s1543 0 10f
Mn1544 s1544 s1543 0 0 nch W=0.5u L=0.18u
Mp1544 s1544 s1543 vdd vdd pch W=1u L=0.18u
Cl1544 s1544 0 10f
Mn1545 s1545 s1544 0 0 nch W=0.5u L=0.18u
Mp1545 s1545 s1544 vdd vdd pch W=1u L=0.18u
Cl1545 s1545 0 10f
Mn1546 s1546 s1545 0 0 nch W=0.5u L=0.18u
Mp1546 s1546 s1545 vdd vdd pch W=1u L=0.18u
Cl1546 s1546 0 10f
Mn1547 s1547 s1546 0 0 nch W=0.5u L=0.18u
Mp1547 s1547 s1546 vdd vdd pch W=1u L=0.18u
Cl1547 s1547 0 10f
Mn1548 s1548 s1547 0 0 nch W=0.5u L=0.18u
Mp1548 s1548 s1547 vdd vdd pch W=1u L=0.18u
Cl1548 s1548 0 10f
Mn1549 s1549 s1548 0 0 nch W=0.5u L=0.18u
Mp1549 s1549 s1548 vdd vdd pch W=1u L=0.18u
Cl1549 s1549 0 10f
Mn1550 s1550 s1549 0 0 nch W=0.5u L=0.18u
Mp1550 s1550 s1549 vdd vdd pch W=1u L=0.18u
Cl1550 s1550 0 10f
Mn1551 s1551 s1550 0 0 nch W=0.5u L=0.18u
Mp1551 s1551 s1550 vdd vdd pch W=1u L=0.18u
Cl1551 s1551 0 10f
Mn1552 s1552 s1551 0 0 nch W=0.5u L=0.18u
Mp1552 s1552 s1551 vdd vdd pch W=1u L=0.18u
Cl1552 s1552 0 10f
Mn1553 s1553 s1552 0 0 nch W=0.5u L=0.18u
Mp1553 s1553 s1552 vdd vdd pch W=1u L=0.18u
Cl1553 s1553 0 10f
Mn1554 s1554 s1553 0 0 nch W=0.5u L=0.18u
Mp1554 s1554 s1553 vdd vdd pch W=1u L=0.18u
Cl1554 s1554 0 10f
Mn1555 s1555 s1554 0 0 nch W=0.5u L=0.18u
Mp1555 s1555 s1554 vdd vdd pch W=1u L=0.18u
Cl1555 s1555 0 10f
Mn1556 s1556 s1555 0 0 nch W=0.5u L=0.18u
Mp1556 s1556 s1555 vdd vdd pch W=1u L=0.18u
Cl1556 s1556 0 10f
Mn1557 s1557 s1556 0 0 nch W=0.5u L=0.18u
Mp1557 s1557 s1556 vdd vdd pch W=1u L=0.18u
Cl1557 s1557 0 10f
Mn1558 s1558 s1557 0 0 nch W=0.5u L=0.18u
Mp1558 s1558 s1557 vdd vdd pch W=1u L=0.18u
Cl1558 s1558 0 10f
Mn1559 s1559 s1558 0 0 nch W=0.5u L=0.18u
Mp1559 s1559 s1558 vdd vdd pch W=1u L=0.18u
Cl1559 s1559 0 10f
Mn1560 s1560 s1559 0 0 nch W=0.5u L=0.18u
Mp1560 s1560 s1559 vdd vdd pch W=1u L=0.18u
Cl1560 s1560 0 10f
Mn1561 s1561 s1560 0 0 nch W=0.5u L=0.18u
Mp1561 s1561 s1560 vdd vdd pch W=1u L=0.18u
Cl1561 s1561 0 10f
Mn1562 s1562 s1561 0 0 nch W=0.5u L=0.18u
Mp1562 s1562 s1561 vdd vdd pch W=1u L=0.18u
Cl1562 s1562 0 10f
Mn1563 s1563 s1562 0 0 nch W=0.5u L=0.18u
Mp1563 s1563 s1562 vdd vdd pch W=1u L=0.18u
Cl1563 s1563 0 10f
Mn1564 s1564 s1563 0 0 nch W=0.5u L=0.18u
Mp1564 s1564 s1563 vdd vdd pch W=1u L=0.18u
Cl1564 s1564 0 10f
Mn1565 s1565 s1564 0 0 nch W=0.5u L=0.18u
Mp1565 s1565 s1564 vdd vdd pch W=1u L=0.18u
Cl1565 s1565 0 10f
Mn1566 s1566 s1565 0 0 nch W=0.5u L=0.18u
Mp1566 s1566 s1565 vdd vdd pch W=1u L=0.18u
Cl1566 s1566 0 10f
Mn1567 s1567 s1566 0 0 nch W=0.5u L=0.18u
Mp1567 s1567 s1566 vdd vdd pch W=1u L=0.18u
Cl1567 s1567 0 10f
Mn1568 s1568 s1567 0 0 nch W=0.5u L=0.18u
Mp1568 s1568 s1567 vdd vdd pch W=1u L=0.18u
Cl1568 s1568 0 10f
Mn1569 s1569 s1568 0 0 nch W=0.5u L=0.18u
Mp1569 s1569 s1568 vdd vdd pch W=1u L=0.18u
Cl1569 s1569 0 10f
Mn1570 s1570 s1569 0 0 nch W=0.5u L=0.18u
Mp1570 s1570 s1569 vdd vdd pch W=1u L=0.18u
Cl1570 s1570 0 10f
Mn1571 s1571 s1570 0 0 nch W=0.5u L=0.18u
Mp1571 s1571 s1570 vdd vdd pch W=1u L=0.18u
Cl1571 s1571 0 10f
Mn1572 s1572 s1571 0 0 nch W=0.5u L=0.18u
Mp1572 s1572 s1571 vdd vdd pch W=1u L=0.18u
Cl1572 s1572 0 10f
Mn1573 s1573 s1572 0 0 nch W=0.5u L=0.18u
Mp1573 s1573 s1572 vdd vdd pch W=1u L=0.18u
Cl1573 s1573 0 10f
Mn1574 s1574 s1573 0 0 nch W=0.5u L=0.18u
Mp1574 s1574 s1573 vdd vdd pch W=1u L=0.18u
Cl1574 s1574 0 10f
Mn1575 s1575 s1574 0 0 nch W=0.5u L=0.18u
Mp1575 s1575 s1574 vdd vdd pch W=1u L=0.18u
Cl1575 s1575 0 10f
Mn1576 s1576 s1575 0 0 nch W=0.5u L=0.18u
Mp1576 s1576 s1575 vdd vdd pch W=1u L=0.18u
Cl1576 s1576 0 10f
Mn1577 s1577 s1576 0 0 nch W=0.5u L=0.18u
Mp1577 s1577 s1576 vdd vdd pch W=1u L=0.18u
Cl1577 s1577 0 10f
Mn1578 s1578 s1577 0 0 nch W=0.5u L=0.18u
Mp1578 s1578 s1577 vdd vdd pch W=1u L=0.18u
Cl1578 s1578 0 10f
Mn1579 s1579 s1578 0 0 nch W=0.5u L=0.18u
Mp1579 s1579 s1578 vdd vdd pch W=1u L=0.18u
Cl1579 s1579 0 10f
Mn1580 s1580 s1579 0 0 nch W=0.5u L=0.18u
Mp1580 s1580 s1579 vdd vdd pch W=1u L=0.18u
Cl1580 s1580 0 10f
Mn1581 s1581 s1580 0 0 nch W=0.5u L=0.18u
Mp1581 s1581 s1580 vdd vdd pch W=1u L=0.18u
Cl1581 s1581 0 10f
Mn1582 s1582 s1581 0 0 nch W=0.5u L=0.18u
Mp1582 s1582 s1581 vdd vdd pch W=1u L=0.18u
Cl1582 s1582 0 10f
Mn1583 s1583 s1582 0 0 nch W=0.5u L=0.18u
Mp1583 s1583 s1582 vdd vdd pch W=1u L=0.18u
Cl1583 s1583 0 10f
Mn1584 s1584 s1583 0 0 nch W=0.5u L=0.18u
Mp1584 s1584 s1583 vdd vdd pch W=1u L=0.18u
Cl1584 s1584 0 10f
Mn1585 s1585 s1584 0 0 nch W=0.5u L=0.18u
Mp1585 s1585 s1584 vdd vdd pch W=1u L=0.18u
Cl1585 s1585 0 10f
Mn1586 s1586 s1585 0 0 nch W=0.5u L=0.18u
Mp1586 s1586 s1585 vdd vdd pch W=1u L=0.18u
Cl1586 s1586 0 10f
Mn1587 s1587 s1586 0 0 nch W=0.5u L=0.18u
Mp1587 s1587 s1586 vdd vdd pch W=1u L=0.18u
Cl1587 s1587 0 10f
Mn1588 s1588 s1587 0 0 nch W=0.5u L=0.18u
Mp1588 s1588 s1587 vdd vdd pch W=1u L=0.18u
Cl1588 s1588 0 10f
Mn1589 s1589 s1588 0 0 nch W=0.5u L=0.18u
Mp1589 s1589 s1588 vdd vdd pch W=1u L=0.18u
Cl1589 s1589 0 10f
Mn1590 s1590 s1589 0 0 nch W=0.5u L=0.18u
Mp1590 s1590 s1589 vdd vdd pch W=1u L=0.18u
Cl1590 s1590 0 10f
Mn1591 s1591 s1590 0 0 nch W=0.5u L=0.18u
Mp1591 s1591 s1590 vdd vdd pch W=1u L=0.18u
Cl1591 s1591 0 10f
Mn1592 s1592 s1591 0 0 nch W=0.5u L=0.18u
Mp1592 s1592 s1591 vdd vdd pch W=1u L=0.18u
Cl1592 s1592 0 10f
Mn1593 s1593 s1592 0 0 nch W=0.5u L=0.18u
Mp1593 s1593 s1592 vdd vdd pch W=1u L=0.18u
Cl1593 s1593 0 10f
Mn1594 s1594 s1593 0 0 nch W=0.5u L=0.18u
Mp1594 s1594 s1593 vdd vdd pch W=1u L=0.18u
Cl1594 s1594 0 10f
Mn1595 s1595 s1594 0 0 nch W=0.5u L=0.18u
Mp1595 s1595 s1594 vdd vdd pch W=1u L=0.18u
Cl1595 s1595 0 10f
Mn1596 s1596 s1595 0 0 nch W=0.5u L=0.18u
Mp1596 s1596 s1595 vdd vdd pch W=1u L=0.18u
Cl1596 s1596 0 10f
Mn1597 s1597 s1596 0 0 nch W=0.5u L=0.18u
Mp1597 s1597 s1596 vdd vdd pch W=1u L=0.18u
Cl1597 s1597 0 10f
Mn1598 s1598 s1597 0 0 nch W=0.5u L=0.18u
Mp1598 s1598 s1597 vdd vdd pch W=1u L=0.18u
Cl1598 s1598 0 10f
Mn1599 s1599 s1598 0 0 nch W=0.5u L=0.18u
Mp1599 s1599 s1598 vdd vdd pch W=1u L=0.18u
Cl1599 s1599 0 10f
Mn1600 s1600 s1599 0 0 nch W=0.5u L=0.18u
Mp1600 s1600 s1599 vdd vdd pch W=1u L=0.18u
Cl1600 s1600 0 10f
Mn1601 s1601 s1600 0 0 nch W=0.5u L=0.18u
Mp1601 s1601 s1600 vdd vdd pch W=1u L=0.18u
Cl1601 s1601 0 10f
Mn1602 s1602 s1601 0 0 nch W=0.5u L=0.18u
Mp1602 s1602 s1601 vdd vdd pch W=1u L=0.18u
Cl1602 s1602 0 10f
Mn1603 s1603 s1602 0 0 nch W=0.5u L=0.18u
Mp1603 s1603 s1602 vdd vdd pch W=1u L=0.18u
Cl1603 s1603 0 10f
Mn1604 s1604 s1603 0 0 nch W=0.5u L=0.18u
Mp1604 s1604 s1603 vdd vdd pch W=1u L=0.18u
Cl1604 s1604 0 10f
Mn1605 s1605 s1604 0 0 nch W=0.5u L=0.18u
Mp1605 s1605 s1604 vdd vdd pch W=1u L=0.18u
Cl1605 s1605 0 10f
Mn1606 s1606 s1605 0 0 nch W=0.5u L=0.18u
Mp1606 s1606 s1605 vdd vdd pch W=1u L=0.18u
Cl1606 s1606 0 10f
Mn1607 s1607 s1606 0 0 nch W=0.5u L=0.18u
Mp1607 s1607 s1606 vdd vdd pch W=1u L=0.18u
Cl1607 s1607 0 10f
Mn1608 s1608 s1607 0 0 nch W=0.5u L=0.18u
Mp1608 s1608 s1607 vdd vdd pch W=1u L=0.18u
Cl1608 s1608 0 10f
Mn1609 s1609 s1608 0 0 nch W=0.5u L=0.18u
Mp1609 s1609 s1608 vdd vdd pch W=1u L=0.18u
Cl1609 s1609 0 10f
Mn1610 s1610 s1609 0 0 nch W=0.5u L=0.18u
Mp1610 s1610 s1609 vdd vdd pch W=1u L=0.18u
Cl1610 s1610 0 10f
Mn1611 s1611 s1610 0 0 nch W=0.5u L=0.18u
Mp1611 s1611 s1610 vdd vdd pch W=1u L=0.18u
Cl1611 s1611 0 10f
Mn1612 s1612 s1611 0 0 nch W=0.5u L=0.18u
Mp1612 s1612 s1611 vdd vdd pch W=1u L=0.18u
Cl1612 s1612 0 10f
Mn1613 s1613 s1612 0 0 nch W=0.5u L=0.18u
Mp1613 s1613 s1612 vdd vdd pch W=1u L=0.18u
Cl1613 s1613 0 10f
Mn1614 s1614 s1613 0 0 nch W=0.5u L=0.18u
Mp1614 s1614 s1613 vdd vdd pch W=1u L=0.18u
Cl1614 s1614 0 10f
Mn1615 s1615 s1614 0 0 nch W=0.5u L=0.18u
Mp1615 s1615 s1614 vdd vdd pch W=1u L=0.18u
Cl1615 s1615 0 10f
Mn1616 s1616 s1615 0 0 nch W=0.5u L=0.18u
Mp1616 s1616 s1615 vdd vdd pch W=1u L=0.18u
Cl1616 s1616 0 10f
Mn1617 s1617 s1616 0 0 nch W=0.5u L=0.18u
Mp1617 s1617 s1616 vdd vdd pch W=1u L=0.18u
Cl1617 s1617 0 10f
Mn1618 s1618 s1617 0 0 nch W=0.5u L=0.18u
Mp1618 s1618 s1617 vdd vdd pch W=1u L=0.18u
Cl1618 s1618 0 10f
Mn1619 s1619 s1618 0 0 nch W=0.5u L=0.18u
Mp1619 s1619 s1618 vdd vdd pch W=1u L=0.18u
Cl1619 s1619 0 10f
Mn1620 s1620 s1619 0 0 nch W=0.5u L=0.18u
Mp1620 s1620 s1619 vdd vdd pch W=1u L=0.18u
Cl1620 s1620 0 10f
Mn1621 s1621 s1620 0 0 nch W=0.5u L=0.18u
Mp1621 s1621 s1620 vdd vdd pch W=1u L=0.18u
Cl1621 s1621 0 10f
Mn1622 s1622 s1621 0 0 nch W=0.5u L=0.18u
Mp1622 s1622 s1621 vdd vdd pch W=1u L=0.18u
Cl1622 s1622 0 10f
Mn1623 s1623 s1622 0 0 nch W=0.5u L=0.18u
Mp1623 s1623 s1622 vdd vdd pch W=1u L=0.18u
Cl1623 s1623 0 10f
Mn1624 s1624 s1623 0 0 nch W=0.5u L=0.18u
Mp1624 s1624 s1623 vdd vdd pch W=1u L=0.18u
Cl1624 s1624 0 10f
Mn1625 s1625 s1624 0 0 nch W=0.5u L=0.18u
Mp1625 s1625 s1624 vdd vdd pch W=1u L=0.18u
Cl1625 s1625 0 10f
Mn1626 s1626 s1625 0 0 nch W=0.5u L=0.18u
Mp1626 s1626 s1625 vdd vdd pch W=1u L=0.18u
Cl1626 s1626 0 10f
Mn1627 s1627 s1626 0 0 nch W=0.5u L=0.18u
Mp1627 s1627 s1626 vdd vdd pch W=1u L=0.18u
Cl1627 s1627 0 10f
Mn1628 s1628 s1627 0 0 nch W=0.5u L=0.18u
Mp1628 s1628 s1627 vdd vdd pch W=1u L=0.18u
Cl1628 s1628 0 10f
Mn1629 s1629 s1628 0 0 nch W=0.5u L=0.18u
Mp1629 s1629 s1628 vdd vdd pch W=1u L=0.18u
Cl1629 s1629 0 10f
Mn1630 s1630 s1629 0 0 nch W=0.5u L=0.18u
Mp1630 s1630 s1629 vdd vdd pch W=1u L=0.18u
Cl1630 s1630 0 10f
Mn1631 s1631 s1630 0 0 nch W=0.5u L=0.18u
Mp1631 s1631 s1630 vdd vdd pch W=1u L=0.18u
Cl1631 s1631 0 10f
Mn1632 s1632 s1631 0 0 nch W=0.5u L=0.18u
Mp1632 s1632 s1631 vdd vdd pch W=1u L=0.18u
Cl1632 s1632 0 10f
Mn1633 s1633 s1632 0 0 nch W=0.5u L=0.18u
Mp1633 s1633 s1632 vdd vdd pch W=1u L=0.18u
Cl1633 s1633 0 10f
Mn1634 s1634 s1633 0 0 nch W=0.5u L=0.18u
Mp1634 s1634 s1633 vdd vdd pch W=1u L=0.18u
Cl1634 s1634 0 10f
Mn1635 s1635 s1634 0 0 nch W=0.5u L=0.18u
Mp1635 s1635 s1634 vdd vdd pch W=1u L=0.18u
Cl1635 s1635 0 10f
Mn1636 s1636 s1635 0 0 nch W=0.5u L=0.18u
Mp1636 s1636 s1635 vdd vdd pch W=1u L=0.18u
Cl1636 s1636 0 10f
Mn1637 s1637 s1636 0 0 nch W=0.5u L=0.18u
Mp1637 s1637 s1636 vdd vdd pch W=1u L=0.18u
Cl1637 s1637 0 10f
Mn1638 s1638 s1637 0 0 nch W=0.5u L=0.18u
Mp1638 s1638 s1637 vdd vdd pch W=1u L=0.18u
Cl1638 s1638 0 10f
Mn1639 s1639 s1638 0 0 nch W=0.5u L=0.18u
Mp1639 s1639 s1638 vdd vdd pch W=1u L=0.18u
Cl1639 s1639 0 10f
Mn1640 s1640 s1639 0 0 nch W=0.5u L=0.18u
Mp1640 s1640 s1639 vdd vdd pch W=1u L=0.18u
Cl1640 s1640 0 10f
Mn1641 s1641 s1640 0 0 nch W=0.5u L=0.18u
Mp1641 s1641 s1640 vdd vdd pch W=1u L=0.18u
Cl1641 s1641 0 10f
Mn1642 s1642 s1641 0 0 nch W=0.5u L=0.18u
Mp1642 s1642 s1641 vdd vdd pch W=1u L=0.18u
Cl1642 s1642 0 10f
Mn1643 s1643 s1642 0 0 nch W=0.5u L=0.18u
Mp1643 s1643 s1642 vdd vdd pch W=1u L=0.18u
Cl1643 s1643 0 10f
Mn1644 s1644 s1643 0 0 nch W=0.5u L=0.18u
Mp1644 s1644 s1643 vdd vdd pch W=1u L=0.18u
Cl1644 s1644 0 10f
Mn1645 s1645 s1644 0 0 nch W=0.5u L=0.18u
Mp1645 s1645 s1644 vdd vdd pch W=1u L=0.18u
Cl1645 s1645 0 10f
Mn1646 s1646 s1645 0 0 nch W=0.5u L=0.18u
Mp1646 s1646 s1645 vdd vdd pch W=1u L=0.18u
Cl1646 s1646 0 10f
Mn1647 s1647 s1646 0 0 nch W=0.5u L=0.18u
Mp1647 s1647 s1646 vdd vdd pch W=1u L=0.18u
Cl1647 s1647 0 10f
Mn1648 s1648 s1647 0 0 nch W=0.5u L=0.18u
Mp1648 s1648 s1647 vdd vdd pch W=1u L=0.18u
Cl1648 s1648 0 10f
Mn1649 s1649 s1648 0 0 nch W=0.5u L=0.18u
Mp1649 s1649 s1648 vdd vdd pch W=1u L=0.18u
Cl1649 s1649 0 10f
Mn1650 s1650 s1649 0 0 nch W=0.5u L=0.18u
Mp1650 s1650 s1649 vdd vdd pch W=1u L=0.18u
Cl1650 s1650 0 10f
Mn1651 s1651 s1650 0 0 nch W=0.5u L=0.18u
Mp1651 s1651 s1650 vdd vdd pch W=1u L=0.18u
Cl1651 s1651 0 10f
Mn1652 s1652 s1651 0 0 nch W=0.5u L=0.18u
Mp1652 s1652 s1651 vdd vdd pch W=1u L=0.18u
Cl1652 s1652 0 10f
Mn1653 s1653 s1652 0 0 nch W=0.5u L=0.18u
Mp1653 s1653 s1652 vdd vdd pch W=1u L=0.18u
Cl1653 s1653 0 10f
Mn1654 s1654 s1653 0 0 nch W=0.5u L=0.18u
Mp1654 s1654 s1653 vdd vdd pch W=1u L=0.18u
Cl1654 s1654 0 10f
Mn1655 s1655 s1654 0 0 nch W=0.5u L=0.18u
Mp1655 s1655 s1654 vdd vdd pch W=1u L=0.18u
Cl1655 s1655 0 10f
Mn1656 s1656 s1655 0 0 nch W=0.5u L=0.18u
Mp1656 s1656 s1655 vdd vdd pch W=1u L=0.18u
Cl1656 s1656 0 10f
Mn1657 s1657 s1656 0 0 nch W=0.5u L=0.18u
Mp1657 s1657 s1656 vdd vdd pch W=1u L=0.18u
Cl1657 s1657 0 10f
Mn1658 s1658 s1657 0 0 nch W=0.5u L=0.18u
Mp1658 s1658 s1657 vdd vdd pch W=1u L=0.18u
Cl1658 s1658 0 10f
Mn1659 s1659 s1658 0 0 nch W=0.5u L=0.18u
Mp1659 s1659 s1658 vdd vdd pch W=1u L=0.18u
Cl1659 s1659 0 10f
Mn1660 s1660 s1659 0 0 nch W=0.5u L=0.18u
Mp1660 s1660 s1659 vdd vdd pch W=1u L=0.18u
Cl1660 s1660 0 10f
Mn1661 s1661 s1660 0 0 nch W=0.5u L=0.18u
Mp1661 s1661 s1660 vdd vdd pch W=1u L=0.18u
Cl1661 s1661 0 10f
Mn1662 s1662 s1661 0 0 nch W=0.5u L=0.18u
Mp1662 s1662 s1661 vdd vdd pch W=1u L=0.18u
Cl1662 s1662 0 10f
Mn1663 s1663 s1662 0 0 nch W=0.5u L=0.18u
Mp1663 s1663 s1662 vdd vdd pch W=1u L=0.18u
Cl1663 s1663 0 10f
Mn1664 s1664 s1663 0 0 nch W=0.5u L=0.18u
Mp1664 s1664 s1663 vdd vdd pch W=1u L=0.18u
Cl1664 s1664 0 10f
Mn1665 s1665 s1664 0 0 nch W=0.5u L=0.18u
Mp1665 s1665 s1664 vdd vdd pch W=1u L=0.18u
Cl1665 s1665 0 10f
Mn1666 s1666 s1665 0 0 nch W=0.5u L=0.18u
Mp1666 s1666 s1665 vdd vdd pch W=1u L=0.18u
Cl1666 s1666 0 10f
Mn1667 s1667 s1666 0 0 nch W=0.5u L=0.18u
Mp1667 s1667 s1666 vdd vdd pch W=1u L=0.18u
Cl1667 s1667 0 10f
Mn1668 s1668 s1667 0 0 nch W=0.5u L=0.18u
Mp1668 s1668 s1667 vdd vdd pch W=1u L=0.18u
Cl1668 s1668 0 10f
Mn1669 s1669 s1668 0 0 nch W=0.5u L=0.18u
Mp1669 s1669 s1668 vdd vdd pch W=1u L=0.18u
Cl1669 s1669 0 10f
Mn1670 s1670 s1669 0 0 nch W=0.5u L=0.18u
Mp1670 s1670 s1669 vdd vdd pch W=1u L=0.18u
Cl1670 s1670 0 10f
Mn1671 s1671 s1670 0 0 nch W=0.5u L=0.18u
Mp1671 s1671 s1670 vdd vdd pch W=1u L=0.18u
Cl1671 s1671 0 10f
Mn1672 s1672 s1671 0 0 nch W=0.5u L=0.18u
Mp1672 s1672 s1671 vdd vdd pch W=1u L=0.18u
Cl1672 s1672 0 10f
Mn1673 s1673 s1672 0 0 nch W=0.5u L=0.18u
Mp1673 s1673 s1672 vdd vdd pch W=1u L=0.18u
Cl1673 s1673 0 10f
Mn1674 s1674 s1673 0 0 nch W=0.5u L=0.18u
Mp1674 s1674 s1673 vdd vdd pch W=1u L=0.18u
Cl1674 s1674 0 10f
Mn1675 s1675 s1674 0 0 nch W=0.5u L=0.18u
Mp1675 s1675 s1674 vdd vdd pch W=1u L=0.18u
Cl1675 s1675 0 10f
Mn1676 s1676 s1675 0 0 nch W=0.5u L=0.18u
Mp1676 s1676 s1675 vdd vdd pch W=1u L=0.18u
Cl1676 s1676 0 10f
Mn1677 s1677 s1676 0 0 nch W=0.5u L=0.18u
Mp1677 s1677 s1676 vdd vdd pch W=1u L=0.18u
Cl1677 s1677 0 10f
Mn1678 s1678 s1677 0 0 nch W=0.5u L=0.18u
Mp1678 s1678 s1677 vdd vdd pch W=1u L=0.18u
Cl1678 s1678 0 10f
Mn1679 s1679 s1678 0 0 nch W=0.5u L=0.18u
Mp1679 s1679 s1678 vdd vdd pch W=1u L=0.18u
Cl1679 s1679 0 10f
Mn1680 s1680 s1679 0 0 nch W=0.5u L=0.18u
Mp1680 s1680 s1679 vdd vdd pch W=1u L=0.18u
Cl1680 s1680 0 10f
Mn1681 s1681 s1680 0 0 nch W=0.5u L=0.18u
Mp1681 s1681 s1680 vdd vdd pch W=1u L=0.18u
Cl1681 s1681 0 10f
Mn1682 s1682 s1681 0 0 nch W=0.5u L=0.18u
Mp1682 s1682 s1681 vdd vdd pch W=1u L=0.18u
Cl1682 s1682 0 10f
Mn1683 s1683 s1682 0 0 nch W=0.5u L=0.18u
Mp1683 s1683 s1682 vdd vdd pch W=1u L=0.18u
Cl1683 s1683 0 10f
Mn1684 s1684 s1683 0 0 nch W=0.5u L=0.18u
Mp1684 s1684 s1683 vdd vdd pch W=1u L=0.18u
Cl1684 s1684 0 10f
Mn1685 s1685 s1684 0 0 nch W=0.5u L=0.18u
Mp1685 s1685 s1684 vdd vdd pch W=1u L=0.18u
Cl1685 s1685 0 10f
Mn1686 s1686 s1685 0 0 nch W=0.5u L=0.18u
Mp1686 s1686 s1685 vdd vdd pch W=1u L=0.18u
Cl1686 s1686 0 10f
Mn1687 s1687 s1686 0 0 nch W=0.5u L=0.18u
Mp1687 s1687 s1686 vdd vdd pch W=1u L=0.18u
Cl1687 s1687 0 10f
Mn1688 s1688 s1687 0 0 nch W=0.5u L=0.18u
Mp1688 s1688 s1687 vdd vdd pch W=1u L=0.18u
Cl1688 s1688 0 10f
Mn1689 s1689 s1688 0 0 nch W=0.5u L=0.18u
Mp1689 s1689 s1688 vdd vdd pch W=1u L=0.18u
Cl1689 s1689 0 10f
Mn1690 s1690 s1689 0 0 nch W=0.5u L=0.18u
Mp1690 s1690 s1689 vdd vdd pch W=1u L=0.18u
Cl1690 s1690 0 10f
Mn1691 s1691 s1690 0 0 nch W=0.5u L=0.18u
Mp1691 s1691 s1690 vdd vdd pch W=1u L=0.18u
Cl1691 s1691 0 10f
Mn1692 s1692 s1691 0 0 nch W=0.5u L=0.18u
Mp1692 s1692 s1691 vdd vdd pch W=1u L=0.18u
Cl1692 s1692 0 10f
Mn1693 s1693 s1692 0 0 nch W=0.5u L=0.18u
Mp1693 s1693 s1692 vdd vdd pch W=1u L=0.18u
Cl1693 s1693 0 10f
Mn1694 s1694 s1693 0 0 nch W=0.5u L=0.18u
Mp1694 s1694 s1693 vdd vdd pch W=1u L=0.18u
Cl1694 s1694 0 10f
Mn1695 s1695 s1694 0 0 nch W=0.5u L=0.18u
Mp1695 s1695 s1694 vdd vdd pch W=1u L=0.18u
Cl1695 s1695 0 10f
Mn1696 s1696 s1695 0 0 nch W=0.5u L=0.18u
Mp1696 s1696 s1695 vdd vdd pch W=1u L=0.18u
Cl1696 s1696 0 10f
Mn1697 s1697 s1696 0 0 nch W=0.5u L=0.18u
Mp1697 s1697 s1696 vdd vdd pch W=1u L=0.18u
Cl1697 s1697 0 10f
Mn1698 s1698 s1697 0 0 nch W=0.5u L=0.18u
Mp1698 s1698 s1697 vdd vdd pch W=1u L=0.18u
Cl1698 s1698 0 10f
Mn1699 s1699 s1698 0 0 nch W=0.5u L=0.18u
Mp1699 s1699 s1698 vdd vdd pch W=1u L=0.18u
Cl1699 s1699 0 10f
Mn1700 s1700 s1699 0 0 nch W=0.5u L=0.18u
Mp1700 s1700 s1699 vdd vdd pch W=1u L=0.18u
Cl1700 s1700 0 10f
Mn1701 s1701 s1700 0 0 nch W=0.5u L=0.18u
Mp1701 s1701 s1700 vdd vdd pch W=1u L=0.18u
Cl1701 s1701 0 10f
Mn1702 s1702 s1701 0 0 nch W=0.5u L=0.18u
Mp1702 s1702 s1701 vdd vdd pch W=1u L=0.18u
Cl1702 s1702 0 10f
Mn1703 s1703 s1702 0 0 nch W=0.5u L=0.18u
Mp1703 s1703 s1702 vdd vdd pch W=1u L=0.18u
Cl1703 s1703 0 10f
Mn1704 s1704 s1703 0 0 nch W=0.5u L=0.18u
Mp1704 s1704 s1703 vdd vdd pch W=1u L=0.18u
Cl1704 s1704 0 10f
Mn1705 s1705 s1704 0 0 nch W=0.5u L=0.18u
Mp1705 s1705 s1704 vdd vdd pch W=1u L=0.18u
Cl1705 s1705 0 10f
Mn1706 s1706 s1705 0 0 nch W=0.5u L=0.18u
Mp1706 s1706 s1705 vdd vdd pch W=1u L=0.18u
Cl1706 s1706 0 10f
Mn1707 s1707 s1706 0 0 nch W=0.5u L=0.18u
Mp1707 s1707 s1706 vdd vdd pch W=1u L=0.18u
Cl1707 s1707 0 10f
Mn1708 s1708 s1707 0 0 nch W=0.5u L=0.18u
Mp1708 s1708 s1707 vdd vdd pch W=1u L=0.18u
Cl1708 s1708 0 10f
Mn1709 s1709 s1708 0 0 nch W=0.5u L=0.18u
Mp1709 s1709 s1708 vdd vdd pch W=1u L=0.18u
Cl1709 s1709 0 10f
Mn1710 s1710 s1709 0 0 nch W=0.5u L=0.18u
Mp1710 s1710 s1709 vdd vdd pch W=1u L=0.18u
Cl1710 s1710 0 10f
Mn1711 s1711 s1710 0 0 nch W=0.5u L=0.18u
Mp1711 s1711 s1710 vdd vdd pch W=1u L=0.18u
Cl1711 s1711 0 10f
Mn1712 s1712 s1711 0 0 nch W=0.5u L=0.18u
Mp1712 s1712 s1711 vdd vdd pch W=1u L=0.18u
Cl1712 s1712 0 10f
Mn1713 s1713 s1712 0 0 nch W=0.5u L=0.18u
Mp1713 s1713 s1712 vdd vdd pch W=1u L=0.18u
Cl1713 s1713 0 10f
Mn1714 s1714 s1713 0 0 nch W=0.5u L=0.18u
Mp1714 s1714 s1713 vdd vdd pch W=1u L=0.18u
Cl1714 s1714 0 10f
Mn1715 s1715 s1714 0 0 nch W=0.5u L=0.18u
Mp1715 s1715 s1714 vdd vdd pch W=1u L=0.18u
Cl1715 s1715 0 10f
Mn1716 s1716 s1715 0 0 nch W=0.5u L=0.18u
Mp1716 s1716 s1715 vdd vdd pch W=1u L=0.18u
Cl1716 s1716 0 10f
Mn1717 s1717 s1716 0 0 nch W=0.5u L=0.18u
Mp1717 s1717 s1716 vdd vdd pch W=1u L=0.18u
Cl1717 s1717 0 10f
Mn1718 s1718 s1717 0 0 nch W=0.5u L=0.18u
Mp1718 s1718 s1717 vdd vdd pch W=1u L=0.18u
Cl1718 s1718 0 10f
Mn1719 s1719 s1718 0 0 nch W=0.5u L=0.18u
Mp1719 s1719 s1718 vdd vdd pch W=1u L=0.18u
Cl1719 s1719 0 10f
Mn1720 s1720 s1719 0 0 nch W=0.5u L=0.18u
Mp1720 s1720 s1719 vdd vdd pch W=1u L=0.18u
Cl1720 s1720 0 10f
Mn1721 s1721 s1720 0 0 nch W=0.5u L=0.18u
Mp1721 s1721 s1720 vdd vdd pch W=1u L=0.18u
Cl1721 s1721 0 10f
Mn1722 s1722 s1721 0 0 nch W=0.5u L=0.18u
Mp1722 s1722 s1721 vdd vdd pch W=1u L=0.18u
Cl1722 s1722 0 10f
Mn1723 s1723 s1722 0 0 nch W=0.5u L=0.18u
Mp1723 s1723 s1722 vdd vdd pch W=1u L=0.18u
Cl1723 s1723 0 10f
Mn1724 s1724 s1723 0 0 nch W=0.5u L=0.18u
Mp1724 s1724 s1723 vdd vdd pch W=1u L=0.18u
Cl1724 s1724 0 10f
Mn1725 s1725 s1724 0 0 nch W=0.5u L=0.18u
Mp1725 s1725 s1724 vdd vdd pch W=1u L=0.18u
Cl1725 s1725 0 10f
Mn1726 s1726 s1725 0 0 nch W=0.5u L=0.18u
Mp1726 s1726 s1725 vdd vdd pch W=1u L=0.18u
Cl1726 s1726 0 10f
Mn1727 s1727 s1726 0 0 nch W=0.5u L=0.18u
Mp1727 s1727 s1726 vdd vdd pch W=1u L=0.18u
Cl1727 s1727 0 10f
Mn1728 s1728 s1727 0 0 nch W=0.5u L=0.18u
Mp1728 s1728 s1727 vdd vdd pch W=1u L=0.18u
Cl1728 s1728 0 10f
Mn1729 s1729 s1728 0 0 nch W=0.5u L=0.18u
Mp1729 s1729 s1728 vdd vdd pch W=1u L=0.18u
Cl1729 s1729 0 10f
Mn1730 s1730 s1729 0 0 nch W=0.5u L=0.18u
Mp1730 s1730 s1729 vdd vdd pch W=1u L=0.18u
Cl1730 s1730 0 10f
Mn1731 s1731 s1730 0 0 nch W=0.5u L=0.18u
Mp1731 s1731 s1730 vdd vdd pch W=1u L=0.18u
Cl1731 s1731 0 10f
Mn1732 s1732 s1731 0 0 nch W=0.5u L=0.18u
Mp1732 s1732 s1731 vdd vdd pch W=1u L=0.18u
Cl1732 s1732 0 10f
Mn1733 s1733 s1732 0 0 nch W=0.5u L=0.18u
Mp1733 s1733 s1732 vdd vdd pch W=1u L=0.18u
Cl1733 s1733 0 10f
Mn1734 s1734 s1733 0 0 nch W=0.5u L=0.18u
Mp1734 s1734 s1733 vdd vdd pch W=1u L=0.18u
Cl1734 s1734 0 10f
Mn1735 s1735 s1734 0 0 nch W=0.5u L=0.18u
Mp1735 s1735 s1734 vdd vdd pch W=1u L=0.18u
Cl1735 s1735 0 10f
Mn1736 s1736 s1735 0 0 nch W=0.5u L=0.18u
Mp1736 s1736 s1735 vdd vdd pch W=1u L=0.18u
Cl1736 s1736 0 10f
Mn1737 s1737 s1736 0 0 nch W=0.5u L=0.18u
Mp1737 s1737 s1736 vdd vdd pch W=1u L=0.18u
Cl1737 s1737 0 10f
Mn1738 s1738 s1737 0 0 nch W=0.5u L=0.18u
Mp1738 s1738 s1737 vdd vdd pch W=1u L=0.18u
Cl1738 s1738 0 10f
Mn1739 s1739 s1738 0 0 nch W=0.5u L=0.18u
Mp1739 s1739 s1738 vdd vdd pch W=1u L=0.18u
Cl1739 s1739 0 10f
Mn1740 s1740 s1739 0 0 nch W=0.5u L=0.18u
Mp1740 s1740 s1739 vdd vdd pch W=1u L=0.18u
Cl1740 s1740 0 10f
Mn1741 s1741 s1740 0 0 nch W=0.5u L=0.18u
Mp1741 s1741 s1740 vdd vdd pch W=1u L=0.18u
Cl1741 s1741 0 10f
Mn1742 s1742 s1741 0 0 nch W=0.5u L=0.18u
Mp1742 s1742 s1741 vdd vdd pch W=1u L=0.18u
Cl1742 s1742 0 10f
Mn1743 s1743 s1742 0 0 nch W=0.5u L=0.18u
Mp1743 s1743 s1742 vdd vdd pch W=1u L=0.18u
Cl1743 s1743 0 10f
Mn1744 s1744 s1743 0 0 nch W=0.5u L=0.18u
Mp1744 s1744 s1743 vdd vdd pch W=1u L=0.18u
Cl1744 s1744 0 10f
Mn1745 s1745 s1744 0 0 nch W=0.5u L=0.18u
Mp1745 s1745 s1744 vdd vdd pch W=1u L=0.18u
Cl1745 s1745 0 10f
Mn1746 s1746 s1745 0 0 nch W=0.5u L=0.18u
Mp1746 s1746 s1745 vdd vdd pch W=1u L=0.18u
Cl1746 s1746 0 10f
Mn1747 s1747 s1746 0 0 nch W=0.5u L=0.18u
Mp1747 s1747 s1746 vdd vdd pch W=1u L=0.18u
Cl1747 s1747 0 10f
Mn1748 s1748 s1747 0 0 nch W=0.5u L=0.18u
Mp1748 s1748 s1747 vdd vdd pch W=1u L=0.18u
Cl1748 s1748 0 10f
Mn1749 s1749 s1748 0 0 nch W=0.5u L=0.18u
Mp1749 s1749 s1748 vdd vdd pch W=1u L=0.18u
Cl1749 s1749 0 10f
Mn1750 s1750 s1749 0 0 nch W=0.5u L=0.18u
Mp1750 s1750 s1749 vdd vdd pch W=1u L=0.18u
Cl1750 s1750 0 10f
Mn1751 s1751 s1750 0 0 nch W=0.5u L=0.18u
Mp1751 s1751 s1750 vdd vdd pch W=1u L=0.18u
Cl1751 s1751 0 10f
Mn1752 s1752 s1751 0 0 nch W=0.5u L=0.18u
Mp1752 s1752 s1751 vdd vdd pch W=1u L=0.18u
Cl1752 s1752 0 10f
Mn1753 s1753 s1752 0 0 nch W=0.5u L=0.18u
Mp1753 s1753 s1752 vdd vdd pch W=1u L=0.18u
Cl1753 s1753 0 10f
Mn1754 s1754 s1753 0 0 nch W=0.5u L=0.18u
Mp1754 s1754 s1753 vdd vdd pch W=1u L=0.18u
Cl1754 s1754 0 10f
Mn1755 s1755 s1754 0 0 nch W=0.5u L=0.18u
Mp1755 s1755 s1754 vdd vdd pch W=1u L=0.18u
Cl1755 s1755 0 10f
Mn1756 s1756 s1755 0 0 nch W=0.5u L=0.18u
Mp1756 s1756 s1755 vdd vdd pch W=1u L=0.18u
Cl1756 s1756 0 10f
Mn1757 s1757 s1756 0 0 nch W=0.5u L=0.18u
Mp1757 s1757 s1756 vdd vdd pch W=1u L=0.18u
Cl1757 s1757 0 10f
Mn1758 s1758 s1757 0 0 nch W=0.5u L=0.18u
Mp1758 s1758 s1757 vdd vdd pch W=1u L=0.18u
Cl1758 s1758 0 10f
Mn1759 s1759 s1758 0 0 nch W=0.5u L=0.18u
Mp1759 s1759 s1758 vdd vdd pch W=1u L=0.18u
Cl1759 s1759 0 10f
Mn1760 s1760 s1759 0 0 nch W=0.5u L=0.18u
Mp1760 s1760 s1759 vdd vdd pch W=1u L=0.18u
Cl1760 s1760 0 10f
Mn1761 s1761 s1760 0 0 nch W=0.5u L=0.18u
Mp1761 s1761 s1760 vdd vdd pch W=1u L=0.18u
Cl1761 s1761 0 10f
Mn1762 s1762 s1761 0 0 nch W=0.5u L=0.18u
Mp1762 s1762 s1761 vdd vdd pch W=1u L=0.18u
Cl1762 s1762 0 10f
Mn1763 s1763 s1762 0 0 nch W=0.5u L=0.18u
Mp1763 s1763 s1762 vdd vdd pch W=1u L=0.18u
Cl1763 s1763 0 10f
Mn1764 s1764 s1763 0 0 nch W=0.5u L=0.18u
Mp1764 s1764 s1763 vdd vdd pch W=1u L=0.18u
Cl1764 s1764 0 10f
Mn1765 s1765 s1764 0 0 nch W=0.5u L=0.18u
Mp1765 s1765 s1764 vdd vdd pch W=1u L=0.18u
Cl1765 s1765 0 10f
Mn1766 s1766 s1765 0 0 nch W=0.5u L=0.18u
Mp1766 s1766 s1765 vdd vdd pch W=1u L=0.18u
Cl1766 s1766 0 10f
Mn1767 s1767 s1766 0 0 nch W=0.5u L=0.18u
Mp1767 s1767 s1766 vdd vdd pch W=1u L=0.18u
Cl1767 s1767 0 10f
Mn1768 s1768 s1767 0 0 nch W=0.5u L=0.18u
Mp1768 s1768 s1767 vdd vdd pch W=1u L=0.18u
Cl1768 s1768 0 10f
Mn1769 s1769 s1768 0 0 nch W=0.5u L=0.18u
Mp1769 s1769 s1768 vdd vdd pch W=1u L=0.18u
Cl1769 s1769 0 10f
Mn1770 s1770 s1769 0 0 nch W=0.5u L=0.18u
Mp1770 s1770 s1769 vdd vdd pch W=1u L=0.18u
Cl1770 s1770 0 10f
Mn1771 s1771 s1770 0 0 nch W=0.5u L=0.18u
Mp1771 s1771 s1770 vdd vdd pch W=1u L=0.18u
Cl1771 s1771 0 10f
Mn1772 s1772 s1771 0 0 nch W=0.5u L=0.18u
Mp1772 s1772 s1771 vdd vdd pch W=1u L=0.18u
Cl1772 s1772 0 10f
Mn1773 s1773 s1772 0 0 nch W=0.5u L=0.18u
Mp1773 s1773 s1772 vdd vdd pch W=1u L=0.18u
Cl1773 s1773 0 10f
Mn1774 s1774 s1773 0 0 nch W=0.5u L=0.18u
Mp1774 s1774 s1773 vdd vdd pch W=1u L=0.18u
Cl1774 s1774 0 10f
Mn1775 s1775 s1774 0 0 nch W=0.5u L=0.18u
Mp1775 s1775 s1774 vdd vdd pch W=1u L=0.18u
Cl1775 s1775 0 10f
Mn1776 s1776 s1775 0 0 nch W=0.5u L=0.18u
Mp1776 s1776 s1775 vdd vdd pch W=1u L=0.18u
Cl1776 s1776 0 10f
Mn1777 s1777 s1776 0 0 nch W=0.5u L=0.18u
Mp1777 s1777 s1776 vdd vdd pch W=1u L=0.18u
Cl1777 s1777 0 10f
Mn1778 s1778 s1777 0 0 nch W=0.5u L=0.18u
Mp1778 s1778 s1777 vdd vdd pch W=1u L=0.18u
Cl1778 s1778 0 10f
Mn1779 s1779 s1778 0 0 nch W=0.5u L=0.18u
Mp1779 s1779 s1778 vdd vdd pch W=1u L=0.18u
Cl1779 s1779 0 10f
Mn1780 s1780 s1779 0 0 nch W=0.5u L=0.18u
Mp1780 s1780 s1779 vdd vdd pch W=1u L=0.18u
Cl1780 s1780 0 10f
Mn1781 s1781 s1780 0 0 nch W=0.5u L=0.18u
Mp1781 s1781 s1780 vdd vdd pch W=1u L=0.18u
Cl1781 s1781 0 10f
Mn1782 s1782 s1781 0 0 nch W=0.5u L=0.18u
Mp1782 s1782 s1781 vdd vdd pch W=1u L=0.18u
Cl1782 s1782 0 10f
Mn1783 s1783 s1782 0 0 nch W=0.5u L=0.18u
Mp1783 s1783 s1782 vdd vdd pch W=1u L=0.18u
Cl1783 s1783 0 10f
Mn1784 s1784 s1783 0 0 nch W=0.5u L=0.18u
Mp1784 s1784 s1783 vdd vdd pch W=1u L=0.18u
Cl1784 s1784 0 10f
Mn1785 s1785 s1784 0 0 nch W=0.5u L=0.18u
Mp1785 s1785 s1784 vdd vdd pch W=1u L=0.18u
Cl1785 s1785 0 10f
Mn1786 s1786 s1785 0 0 nch W=0.5u L=0.18u
Mp1786 s1786 s1785 vdd vdd pch W=1u L=0.18u
Cl1786 s1786 0 10f
Mn1787 s1787 s1786 0 0 nch W=0.5u L=0.18u
Mp1787 s1787 s1786 vdd vdd pch W=1u L=0.18u
Cl1787 s1787 0 10f
Mn1788 s1788 s1787 0 0 nch W=0.5u L=0.18u
Mp1788 s1788 s1787 vdd vdd pch W=1u L=0.18u
Cl1788 s1788 0 10f
Mn1789 s1789 s1788 0 0 nch W=0.5u L=0.18u
Mp1789 s1789 s1788 vdd vdd pch W=1u L=0.18u
Cl1789 s1789 0 10f
Mn1790 s1790 s1789 0 0 nch W=0.5u L=0.18u
Mp1790 s1790 s1789 vdd vdd pch W=1u L=0.18u
Cl1790 s1790 0 10f
Mn1791 s1791 s1790 0 0 nch W=0.5u L=0.18u
Mp1791 s1791 s1790 vdd vdd pch W=1u L=0.18u
Cl1791 s1791 0 10f
Mn1792 s1792 s1791 0 0 nch W=0.5u L=0.18u
Mp1792 s1792 s1791 vdd vdd pch W=1u L=0.18u
Cl1792 s1792 0 10f
Mn1793 s1793 s1792 0 0 nch W=0.5u L=0.18u
Mp1793 s1793 s1792 vdd vdd pch W=1u L=0.18u
Cl1793 s1793 0 10f
Mn1794 s1794 s1793 0 0 nch W=0.5u L=0.18u
Mp1794 s1794 s1793 vdd vdd pch W=1u L=0.18u
Cl1794 s1794 0 10f
Mn1795 s1795 s1794 0 0 nch W=0.5u L=0.18u
Mp1795 s1795 s1794 vdd vdd pch W=1u L=0.18u
Cl1795 s1795 0 10f
Mn1796 s1796 s1795 0 0 nch W=0.5u L=0.18u
Mp1796 s1796 s1795 vdd vdd pch W=1u L=0.18u
Cl1796 s1796 0 10f
Mn1797 s1797 s1796 0 0 nch W=0.5u L=0.18u
Mp1797 s1797 s1796 vdd vdd pch W=1u L=0.18u
Cl1797 s1797 0 10f
Mn1798 s1798 s1797 0 0 nch W=0.5u L=0.18u
Mp1798 s1798 s1797 vdd vdd pch W=1u L=0.18u
Cl1798 s1798 0 10f
Mn1799 s1799 s1798 0 0 nch W=0.5u L=0.18u
Mp1799 s1799 s1798 vdd vdd pch W=1u L=0.18u
Cl1799 s1799 0 10f
Mn1800 s1800 s1799 0 0 nch W=0.5u L=0.18u
Mp1800 s1800 s1799 vdd vdd pch W=1u L=0.18u
Cl1800 s1800 0 10f
Mn1801 s1801 s1800 0 0 nch W=0.5u L=0.18u
Mp1801 s1801 s1800 vdd vdd pch W=1u L=0.18u
Cl1801 s1801 0 10f
Mn1802 s1802 s1801 0 0 nch W=0.5u L=0.18u
Mp1802 s1802 s1801 vdd vdd pch W=1u L=0.18u
Cl1802 s1802 0 10f
Mn1803 s1803 s1802 0 0 nch W=0.5u L=0.18u
Mp1803 s1803 s1802 vdd vdd pch W=1u L=0.18u
Cl1803 s1803 0 10f
Mn1804 s1804 s1803 0 0 nch W=0.5u L=0.18u
Mp1804 s1804 s1803 vdd vdd pch W=1u L=0.18u
Cl1804 s1804 0 10f
Mn1805 s1805 s1804 0 0 nch W=0.5u L=0.18u
Mp1805 s1805 s1804 vdd vdd pch W=1u L=0.18u
Cl1805 s1805 0 10f
Mn1806 s1806 s1805 0 0 nch W=0.5u L=0.18u
Mp1806 s1806 s1805 vdd vdd pch W=1u L=0.18u
Cl1806 s1806 0 10f
Mn1807 s1807 s1806 0 0 nch W=0.5u L=0.18u
Mp1807 s1807 s1806 vdd vdd pch W=1u L=0.18u
Cl1807 s1807 0 10f
Mn1808 s1808 s1807 0 0 nch W=0.5u L=0.18u
Mp1808 s1808 s1807 vdd vdd pch W=1u L=0.18u
Cl1808 s1808 0 10f
Mn1809 s1809 s1808 0 0 nch W=0.5u L=0.18u
Mp1809 s1809 s1808 vdd vdd pch W=1u L=0.18u
Cl1809 s1809 0 10f
Mn1810 s1810 s1809 0 0 nch W=0.5u L=0.18u
Mp1810 s1810 s1809 vdd vdd pch W=1u L=0.18u
Cl1810 s1810 0 10f
Mn1811 s1811 s1810 0 0 nch W=0.5u L=0.18u
Mp1811 s1811 s1810 vdd vdd pch W=1u L=0.18u
Cl1811 s1811 0 10f
Mn1812 s1812 s1811 0 0 nch W=0.5u L=0.18u
Mp1812 s1812 s1811 vdd vdd pch W=1u L=0.18u
Cl1812 s1812 0 10f
Mn1813 s1813 s1812 0 0 nch W=0.5u L=0.18u
Mp1813 s1813 s1812 vdd vdd pch W=1u L=0.18u
Cl1813 s1813 0 10f
Mn1814 s1814 s1813 0 0 nch W=0.5u L=0.18u
Mp1814 s1814 s1813 vdd vdd pch W=1u L=0.18u
Cl1814 s1814 0 10f
Mn1815 s1815 s1814 0 0 nch W=0.5u L=0.18u
Mp1815 s1815 s1814 vdd vdd pch W=1u L=0.18u
Cl1815 s1815 0 10f
Mn1816 s1816 s1815 0 0 nch W=0.5u L=0.18u
Mp1816 s1816 s1815 vdd vdd pch W=1u L=0.18u
Cl1816 s1816 0 10f
Mn1817 s1817 s1816 0 0 nch W=0.5u L=0.18u
Mp1817 s1817 s1816 vdd vdd pch W=1u L=0.18u
Cl1817 s1817 0 10f
Mn1818 s1818 s1817 0 0 nch W=0.5u L=0.18u
Mp1818 s1818 s1817 vdd vdd pch W=1u L=0.18u
Cl1818 s1818 0 10f
Mn1819 s1819 s1818 0 0 nch W=0.5u L=0.18u
Mp1819 s1819 s1818 vdd vdd pch W=1u L=0.18u
Cl1819 s1819 0 10f
Mn1820 s1820 s1819 0 0 nch W=0.5u L=0.18u
Mp1820 s1820 s1819 vdd vdd pch W=1u L=0.18u
Cl1820 s1820 0 10f
Mn1821 s1821 s1820 0 0 nch W=0.5u L=0.18u
Mp1821 s1821 s1820 vdd vdd pch W=1u L=0.18u
Cl1821 s1821 0 10f
Mn1822 s1822 s1821 0 0 nch W=0.5u L=0.18u
Mp1822 s1822 s1821 vdd vdd pch W=1u L=0.18u
Cl1822 s1822 0 10f
Mn1823 s1823 s1822 0 0 nch W=0.5u L=0.18u
Mp1823 s1823 s1822 vdd vdd pch W=1u L=0.18u
Cl1823 s1823 0 10f
Mn1824 s1824 s1823 0 0 nch W=0.5u L=0.18u
Mp1824 s1824 s1823 vdd vdd pch W=1u L=0.18u
Cl1824 s1824 0 10f
Mn1825 s1825 s1824 0 0 nch W=0.5u L=0.18u
Mp1825 s1825 s1824 vdd vdd pch W=1u L=0.18u
Cl1825 s1825 0 10f
Mn1826 s1826 s1825 0 0 nch W=0.5u L=0.18u
Mp1826 s1826 s1825 vdd vdd pch W=1u L=0.18u
Cl1826 s1826 0 10f
Mn1827 s1827 s1826 0 0 nch W=0.5u L=0.18u
Mp1827 s1827 s1826 vdd vdd pch W=1u L=0.18u
Cl1827 s1827 0 10f
Mn1828 s1828 s1827 0 0 nch W=0.5u L=0.18u
Mp1828 s1828 s1827 vdd vdd pch W=1u L=0.18u
Cl1828 s1828 0 10f
Mn1829 s1829 s1828 0 0 nch W=0.5u L=0.18u
Mp1829 s1829 s1828 vdd vdd pch W=1u L=0.18u
Cl1829 s1829 0 10f
Mn1830 s1830 s1829 0 0 nch W=0.5u L=0.18u
Mp1830 s1830 s1829 vdd vdd pch W=1u L=0.18u
Cl1830 s1830 0 10f
Mn1831 s1831 s1830 0 0 nch W=0.5u L=0.18u
Mp1831 s1831 s1830 vdd vdd pch W=1u L=0.18u
Cl1831 s1831 0 10f
Mn1832 s1832 s1831 0 0 nch W=0.5u L=0.18u
Mp1832 s1832 s1831 vdd vdd pch W=1u L=0.18u
Cl1832 s1832 0 10f
Mn1833 s1833 s1832 0 0 nch W=0.5u L=0.18u
Mp1833 s1833 s1832 vdd vdd pch W=1u L=0.18u
Cl1833 s1833 0 10f
Mn1834 s1834 s1833 0 0 nch W=0.5u L=0.18u
Mp1834 s1834 s1833 vdd vdd pch W=1u L=0.18u
Cl1834 s1834 0 10f
Mn1835 s1835 s1834 0 0 nch W=0.5u L=0.18u
Mp1835 s1835 s1834 vdd vdd pch W=1u L=0.18u
Cl1835 s1835 0 10f
Mn1836 s1836 s1835 0 0 nch W=0.5u L=0.18u
Mp1836 s1836 s1835 vdd vdd pch W=1u L=0.18u
Cl1836 s1836 0 10f
Mn1837 s1837 s1836 0 0 nch W=0.5u L=0.18u
Mp1837 s1837 s1836 vdd vdd pch W=1u L=0.18u
Cl1837 s1837 0 10f
Mn1838 s1838 s1837 0 0 nch W=0.5u L=0.18u
Mp1838 s1838 s1837 vdd vdd pch W=1u L=0.18u
Cl1838 s1838 0 10f
Mn1839 s1839 s1838 0 0 nch W=0.5u L=0.18u
Mp1839 s1839 s1838 vdd vdd pch W=1u L=0.18u
Cl1839 s1839 0 10f
Mn1840 s1840 s1839 0 0 nch W=0.5u L=0.18u
Mp1840 s1840 s1839 vdd vdd pch W=1u L=0.18u
Cl1840 s1840 0 10f
Mn1841 s1841 s1840 0 0 nch W=0.5u L=0.18u
Mp1841 s1841 s1840 vdd vdd pch W=1u L=0.18u
Cl1841 s1841 0 10f
Mn1842 s1842 s1841 0 0 nch W=0.5u L=0.18u
Mp1842 s1842 s1841 vdd vdd pch W=1u L=0.18u
Cl1842 s1842 0 10f
Mn1843 s1843 s1842 0 0 nch W=0.5u L=0.18u
Mp1843 s1843 s1842 vdd vdd pch W=1u L=0.18u
Cl1843 s1843 0 10f
Mn1844 s1844 s1843 0 0 nch W=0.5u L=0.18u
Mp1844 s1844 s1843 vdd vdd pch W=1u L=0.18u
Cl1844 s1844 0 10f
Mn1845 s1845 s1844 0 0 nch W=0.5u L=0.18u
Mp1845 s1845 s1844 vdd vdd pch W=1u L=0.18u
Cl1845 s1845 0 10f
Mn1846 s1846 s1845 0 0 nch W=0.5u L=0.18u
Mp1846 s1846 s1845 vdd vdd pch W=1u L=0.18u
Cl1846 s1846 0 10f
Mn1847 s1847 s1846 0 0 nch W=0.5u L=0.18u
Mp1847 s1847 s1846 vdd vdd pch W=1u L=0.18u
Cl1847 s1847 0 10f
Mn1848 s1848 s1847 0 0 nch W=0.5u L=0.18u
Mp1848 s1848 s1847 vdd vdd pch W=1u L=0.18u
Cl1848 s1848 0 10f
Mn1849 s1849 s1848 0 0 nch W=0.5u L=0.18u
Mp1849 s1849 s1848 vdd vdd pch W=1u L=0.18u
Cl1849 s1849 0 10f
Mn1850 s1850 s1849 0 0 nch W=0.5u L=0.18u
Mp1850 s1850 s1849 vdd vdd pch W=1u L=0.18u
Cl1850 s1850 0 10f
Mn1851 s1851 s1850 0 0 nch W=0.5u L=0.18u
Mp1851 s1851 s1850 vdd vdd pch W=1u L=0.18u
Cl1851 s1851 0 10f
Mn1852 s1852 s1851 0 0 nch W=0.5u L=0.18u
Mp1852 s1852 s1851 vdd vdd pch W=1u L=0.18u
Cl1852 s1852 0 10f
Mn1853 s1853 s1852 0 0 nch W=0.5u L=0.18u
Mp1853 s1853 s1852 vdd vdd pch W=1u L=0.18u
Cl1853 s1853 0 10f
Mn1854 s1854 s1853 0 0 nch W=0.5u L=0.18u
Mp1854 s1854 s1853 vdd vdd pch W=1u L=0.18u
Cl1854 s1854 0 10f
Mn1855 s1855 s1854 0 0 nch W=0.5u L=0.18u
Mp1855 s1855 s1854 vdd vdd pch W=1u L=0.18u
Cl1855 s1855 0 10f
Mn1856 s1856 s1855 0 0 nch W=0.5u L=0.18u
Mp1856 s1856 s1855 vdd vdd pch W=1u L=0.18u
Cl1856 s1856 0 10f
Mn1857 s1857 s1856 0 0 nch W=0.5u L=0.18u
Mp1857 s1857 s1856 vdd vdd pch W=1u L=0.18u
Cl1857 s1857 0 10f
Mn1858 s1858 s1857 0 0 nch W=0.5u L=0.18u
Mp1858 s1858 s1857 vdd vdd pch W=1u L=0.18u
Cl1858 s1858 0 10f
Mn1859 s1859 s1858 0 0 nch W=0.5u L=0.18u
Mp1859 s1859 s1858 vdd vdd pch W=1u L=0.18u
Cl1859 s1859 0 10f
Mn1860 s1860 s1859 0 0 nch W=0.5u L=0.18u
Mp1860 s1860 s1859 vdd vdd pch W=1u L=0.18u
Cl1860 s1860 0 10f
Mn1861 s1861 s1860 0 0 nch W=0.5u L=0.18u
Mp1861 s1861 s1860 vdd vdd pch W=1u L=0.18u
Cl1861 s1861 0 10f
Mn1862 s1862 s1861 0 0 nch W=0.5u L=0.18u
Mp1862 s1862 s1861 vdd vdd pch W=1u L=0.18u
Cl1862 s1862 0 10f
Mn1863 s1863 s1862 0 0 nch W=0.5u L=0.18u
Mp1863 s1863 s1862 vdd vdd pch W=1u L=0.18u
Cl1863 s1863 0 10f
Mn1864 s1864 s1863 0 0 nch W=0.5u L=0.18u
Mp1864 s1864 s1863 vdd vdd pch W=1u L=0.18u
Cl1864 s1864 0 10f
Mn1865 s1865 s1864 0 0 nch W=0.5u L=0.18u
Mp1865 s1865 s1864 vdd vdd pch W=1u L=0.18u
Cl1865 s1865 0 10f
Mn1866 s1866 s1865 0 0 nch W=0.5u L=0.18u
Mp1866 s1866 s1865 vdd vdd pch W=1u L=0.18u
Cl1866 s1866 0 10f
Mn1867 s1867 s1866 0 0 nch W=0.5u L=0.18u
Mp1867 s1867 s1866 vdd vdd pch W=1u L=0.18u
Cl1867 s1867 0 10f
Mn1868 s1868 s1867 0 0 nch W=0.5u L=0.18u
Mp1868 s1868 s1867 vdd vdd pch W=1u L=0.18u
Cl1868 s1868 0 10f
Mn1869 s1869 s1868 0 0 nch W=0.5u L=0.18u
Mp1869 s1869 s1868 vdd vdd pch W=1u L=0.18u
Cl1869 s1869 0 10f
Mn1870 s1870 s1869 0 0 nch W=0.5u L=0.18u
Mp1870 s1870 s1869 vdd vdd pch W=1u L=0.18u
Cl1870 s1870 0 10f
Mn1871 s1871 s1870 0 0 nch W=0.5u L=0.18u
Mp1871 s1871 s1870 vdd vdd pch W=1u L=0.18u
Cl1871 s1871 0 10f
Mn1872 s1872 s1871 0 0 nch W=0.5u L=0.18u
Mp1872 s1872 s1871 vdd vdd pch W=1u L=0.18u
Cl1872 s1872 0 10f
Mn1873 s1873 s1872 0 0 nch W=0.5u L=0.18u
Mp1873 s1873 s1872 vdd vdd pch W=1u L=0.18u
Cl1873 s1873 0 10f
Mn1874 s1874 s1873 0 0 nch W=0.5u L=0.18u
Mp1874 s1874 s1873 vdd vdd pch W=1u L=0.18u
Cl1874 s1874 0 10f
Mn1875 s1875 s1874 0 0 nch W=0.5u L=0.18u
Mp1875 s1875 s1874 vdd vdd pch W=1u L=0.18u
Cl1875 s1875 0 10f
Mn1876 s1876 s1875 0 0 nch W=0.5u L=0.18u
Mp1876 s1876 s1875 vdd vdd pch W=1u L=0.18u
Cl1876 s1876 0 10f
Mn1877 s1877 s1876 0 0 nch W=0.5u L=0.18u
Mp1877 s1877 s1876 vdd vdd pch W=1u L=0.18u
Cl1877 s1877 0 10f
Mn1878 s1878 s1877 0 0 nch W=0.5u L=0.18u
Mp1878 s1878 s1877 vdd vdd pch W=1u L=0.18u
Cl1878 s1878 0 10f
Mn1879 s1879 s1878 0 0 nch W=0.5u L=0.18u
Mp1879 s1879 s1878 vdd vdd pch W=1u L=0.18u
Cl1879 s1879 0 10f
Mn1880 s1880 s1879 0 0 nch W=0.5u L=0.18u
Mp1880 s1880 s1879 vdd vdd pch W=1u L=0.18u
Cl1880 s1880 0 10f
Mn1881 s1881 s1880 0 0 nch W=0.5u L=0.18u
Mp1881 s1881 s1880 vdd vdd pch W=1u L=0.18u
Cl1881 s1881 0 10f
Mn1882 s1882 s1881 0 0 nch W=0.5u L=0.18u
Mp1882 s1882 s1881 vdd vdd pch W=1u L=0.18u
Cl1882 s1882 0 10f
Mn1883 s1883 s1882 0 0 nch W=0.5u L=0.18u
Mp1883 s1883 s1882 vdd vdd pch W=1u L=0.18u
Cl1883 s1883 0 10f
Mn1884 s1884 s1883 0 0 nch W=0.5u L=0.18u
Mp1884 s1884 s1883 vdd vdd pch W=1u L=0.18u
Cl1884 s1884 0 10f
Mn1885 s1885 s1884 0 0 nch W=0.5u L=0.18u
Mp1885 s1885 s1884 vdd vdd pch W=1u L=0.18u
Cl1885 s1885 0 10f
Mn1886 s1886 s1885 0 0 nch W=0.5u L=0.18u
Mp1886 s1886 s1885 vdd vdd pch W=1u L=0.18u
Cl1886 s1886 0 10f
Mn1887 s1887 s1886 0 0 nch W=0.5u L=0.18u
Mp1887 s1887 s1886 vdd vdd pch W=1u L=0.18u
Cl1887 s1887 0 10f
Mn1888 s1888 s1887 0 0 nch W=0.5u L=0.18u
Mp1888 s1888 s1887 vdd vdd pch W=1u L=0.18u
Cl1888 s1888 0 10f
Mn1889 s1889 s1888 0 0 nch W=0.5u L=0.18u
Mp1889 s1889 s1888 vdd vdd pch W=1u L=0.18u
Cl1889 s1889 0 10f
Mn1890 s1890 s1889 0 0 nch W=0.5u L=0.18u
Mp1890 s1890 s1889 vdd vdd pch W=1u L=0.18u
Cl1890 s1890 0 10f
Mn1891 s1891 s1890 0 0 nch W=0.5u L=0.18u
Mp1891 s1891 s1890 vdd vdd pch W=1u L=0.18u
Cl1891 s1891 0 10f
Mn1892 s1892 s1891 0 0 nch W=0.5u L=0.18u
Mp1892 s1892 s1891 vdd vdd pch W=1u L=0.18u
Cl1892 s1892 0 10f
Mn1893 s1893 s1892 0 0 nch W=0.5u L=0.18u
Mp1893 s1893 s1892 vdd vdd pch W=1u L=0.18u
Cl1893 s1893 0 10f
Mn1894 s1894 s1893 0 0 nch W=0.5u L=0.18u
Mp1894 s1894 s1893 vdd vdd pch W=1u L=0.18u
Cl1894 s1894 0 10f
Mn1895 s1895 s1894 0 0 nch W=0.5u L=0.18u
Mp1895 s1895 s1894 vdd vdd pch W=1u L=0.18u
Cl1895 s1895 0 10f
Mn1896 s1896 s1895 0 0 nch W=0.5u L=0.18u
Mp1896 s1896 s1895 vdd vdd pch W=1u L=0.18u
Cl1896 s1896 0 10f
Mn1897 s1897 s1896 0 0 nch W=0.5u L=0.18u
Mp1897 s1897 s1896 vdd vdd pch W=1u L=0.18u
Cl1897 s1897 0 10f
Mn1898 s1898 s1897 0 0 nch W=0.5u L=0.18u
Mp1898 s1898 s1897 vdd vdd pch W=1u L=0.18u
Cl1898 s1898 0 10f
Mn1899 s1899 s1898 0 0 nch W=0.5u L=0.18u
Mp1899 s1899 s1898 vdd vdd pch W=1u L=0.18u
Cl1899 s1899 0 10f
Mn1900 s1900 s1899 0 0 nch W=0.5u L=0.18u
Mp1900 s1900 s1899 vdd vdd pch W=1u L=0.18u
Cl1900 s1900 0 10f
Mn1901 s1901 s1900 0 0 nch W=0.5u L=0.18u
Mp1901 s1901 s1900 vdd vdd pch W=1u L=0.18u
Cl1901 s1901 0 10f
Mn1902 s1902 s1901 0 0 nch W=0.5u L=0.18u
Mp1902 s1902 s1901 vdd vdd pch W=1u L=0.18u
Cl1902 s1902 0 10f
Mn1903 s1903 s1902 0 0 nch W=0.5u L=0.18u
Mp1903 s1903 s1902 vdd vdd pch W=1u L=0.18u
Cl1903 s1903 0 10f
Mn1904 s1904 s1903 0 0 nch W=0.5u L=0.18u
Mp1904 s1904 s1903 vdd vdd pch W=1u L=0.18u
Cl1904 s1904 0 10f
Mn1905 s1905 s1904 0 0 nch W=0.5u L=0.18u
Mp1905 s1905 s1904 vdd vdd pch W=1u L=0.18u
Cl1905 s1905 0 10f
Mn1906 s1906 s1905 0 0 nch W=0.5u L=0.18u
Mp1906 s1906 s1905 vdd vdd pch W=1u L=0.18u
Cl1906 s1906 0 10f
Mn1907 s1907 s1906 0 0 nch W=0.5u L=0.18u
Mp1907 s1907 s1906 vdd vdd pch W=1u L=0.18u
Cl1907 s1907 0 10f
Mn1908 s1908 s1907 0 0 nch W=0.5u L=0.18u
Mp1908 s1908 s1907 vdd vdd pch W=1u L=0.18u
Cl1908 s1908 0 10f
Mn1909 s1909 s1908 0 0 nch W=0.5u L=0.18u
Mp1909 s1909 s1908 vdd vdd pch W=1u L=0.18u
Cl1909 s1909 0 10f
Mn1910 s1910 s1909 0 0 nch W=0.5u L=0.18u
Mp1910 s1910 s1909 vdd vdd pch W=1u L=0.18u
Cl1910 s1910 0 10f
Mn1911 s1911 s1910 0 0 nch W=0.5u L=0.18u
Mp1911 s1911 s1910 vdd vdd pch W=1u L=0.18u
Cl1911 s1911 0 10f
Mn1912 s1912 s1911 0 0 nch W=0.5u L=0.18u
Mp1912 s1912 s1911 vdd vdd pch W=1u L=0.18u
Cl1912 s1912 0 10f
Mn1913 s1913 s1912 0 0 nch W=0.5u L=0.18u
Mp1913 s1913 s1912 vdd vdd pch W=1u L=0.18u
Cl1913 s1913 0 10f
Mn1914 s1914 s1913 0 0 nch W=0.5u L=0.18u
Mp1914 s1914 s1913 vdd vdd pch W=1u L=0.18u
Cl1914 s1914 0 10f
Mn1915 s1915 s1914 0 0 nch W=0.5u L=0.18u
Mp1915 s1915 s1914 vdd vdd pch W=1u L=0.18u
Cl1915 s1915 0 10f
Mn1916 s1916 s1915 0 0 nch W=0.5u L=0.18u
Mp1916 s1916 s1915 vdd vdd pch W=1u L=0.18u
Cl1916 s1916 0 10f
Mn1917 s1917 s1916 0 0 nch W=0.5u L=0.18u
Mp1917 s1917 s1916 vdd vdd pch W=1u L=0.18u
Cl1917 s1917 0 10f
Mn1918 s1918 s1917 0 0 nch W=0.5u L=0.18u
Mp1918 s1918 s1917 vdd vdd pch W=1u L=0.18u
Cl1918 s1918 0 10f
Mn1919 s1919 s1918 0 0 nch W=0.5u L=0.18u
Mp1919 s1919 s1918 vdd vdd pch W=1u L=0.18u
Cl1919 s1919 0 10f
Mn1920 s1920 s1919 0 0 nch W=0.5u L=0.18u
Mp1920 s1920 s1919 vdd vdd pch W=1u L=0.18u
Cl1920 s1920 0 10f
Mn1921 s1921 s1920 0 0 nch W=0.5u L=0.18u
Mp1921 s1921 s1920 vdd vdd pch W=1u L=0.18u
Cl1921 s1921 0 10f
Mn1922 s1922 s1921 0 0 nch W=0.5u L=0.18u
Mp1922 s1922 s1921 vdd vdd pch W=1u L=0.18u
Cl1922 s1922 0 10f
Mn1923 s1923 s1922 0 0 nch W=0.5u L=0.18u
Mp1923 s1923 s1922 vdd vdd pch W=1u L=0.18u
Cl1923 s1923 0 10f
Mn1924 s1924 s1923 0 0 nch W=0.5u L=0.18u
Mp1924 s1924 s1923 vdd vdd pch W=1u L=0.18u
Cl1924 s1924 0 10f
Mn1925 s1925 s1924 0 0 nch W=0.5u L=0.18u
Mp1925 s1925 s1924 vdd vdd pch W=1u L=0.18u
Cl1925 s1925 0 10f
Mn1926 s1926 s1925 0 0 nch W=0.5u L=0.18u
Mp1926 s1926 s1925 vdd vdd pch W=1u L=0.18u
Cl1926 s1926 0 10f
Mn1927 s1927 s1926 0 0 nch W=0.5u L=0.18u
Mp1927 s1927 s1926 vdd vdd pch W=1u L=0.18u
Cl1927 s1927 0 10f
Mn1928 s1928 s1927 0 0 nch W=0.5u L=0.18u
Mp1928 s1928 s1927 vdd vdd pch W=1u L=0.18u
Cl1928 s1928 0 10f
Mn1929 s1929 s1928 0 0 nch W=0.5u L=0.18u
Mp1929 s1929 s1928 vdd vdd pch W=1u L=0.18u
Cl1929 s1929 0 10f
Mn1930 s1930 s1929 0 0 nch W=0.5u L=0.18u
Mp1930 s1930 s1929 vdd vdd pch W=1u L=0.18u
Cl1930 s1930 0 10f
Mn1931 s1931 s1930 0 0 nch W=0.5u L=0.18u
Mp1931 s1931 s1930 vdd vdd pch W=1u L=0.18u
Cl1931 s1931 0 10f
Mn1932 s1932 s1931 0 0 nch W=0.5u L=0.18u
Mp1932 s1932 s1931 vdd vdd pch W=1u L=0.18u
Cl1932 s1932 0 10f
Mn1933 s1933 s1932 0 0 nch W=0.5u L=0.18u
Mp1933 s1933 s1932 vdd vdd pch W=1u L=0.18u
Cl1933 s1933 0 10f
Mn1934 s1934 s1933 0 0 nch W=0.5u L=0.18u
Mp1934 s1934 s1933 vdd vdd pch W=1u L=0.18u
Cl1934 s1934 0 10f
Mn1935 s1935 s1934 0 0 nch W=0.5u L=0.18u
Mp1935 s1935 s1934 vdd vdd pch W=1u L=0.18u
Cl1935 s1935 0 10f
Mn1936 s1936 s1935 0 0 nch W=0.5u L=0.18u
Mp1936 s1936 s1935 vdd vdd pch W=1u L=0.18u
Cl1936 s1936 0 10f
Mn1937 s1937 s1936 0 0 nch W=0.5u L=0.18u
Mp1937 s1937 s1936 vdd vdd pch W=1u L=0.18u
Cl1937 s1937 0 10f
Mn1938 s1938 s1937 0 0 nch W=0.5u L=0.18u
Mp1938 s1938 s1937 vdd vdd pch W=1u L=0.18u
Cl1938 s1938 0 10f
Mn1939 s1939 s1938 0 0 nch W=0.5u L=0.18u
Mp1939 s1939 s1938 vdd vdd pch W=1u L=0.18u
Cl1939 s1939 0 10f
Mn1940 s1940 s1939 0 0 nch W=0.5u L=0.18u
Mp1940 s1940 s1939 vdd vdd pch W=1u L=0.18u
Cl1940 s1940 0 10f
Mn1941 s1941 s1940 0 0 nch W=0.5u L=0.18u
Mp1941 s1941 s1940 vdd vdd pch W=1u L=0.18u
Cl1941 s1941 0 10f
Mn1942 s1942 s1941 0 0 nch W=0.5u L=0.18u
Mp1942 s1942 s1941 vdd vdd pch W=1u L=0.18u
Cl1942 s1942 0 10f
Mn1943 s1943 s1942 0 0 nch W=0.5u L=0.18u
Mp1943 s1943 s1942 vdd vdd pch W=1u L=0.18u
Cl1943 s1943 0 10f
Mn1944 s1944 s1943 0 0 nch W=0.5u L=0.18u
Mp1944 s1944 s1943 vdd vdd pch W=1u L=0.18u
Cl1944 s1944 0 10f
Mn1945 s1945 s1944 0 0 nch W=0.5u L=0.18u
Mp1945 s1945 s1944 vdd vdd pch W=1u L=0.18u
Cl1945 s1945 0 10f
Mn1946 s1946 s1945 0 0 nch W=0.5u L=0.18u
Mp1946 s1946 s1945 vdd vdd pch W=1u L=0.18u
Cl1946 s1946 0 10f
Mn1947 s1947 s1946 0 0 nch W=0.5u L=0.18u
Mp1947 s1947 s1946 vdd vdd pch W=1u L=0.18u
Cl1947 s1947 0 10f
Mn1948 s1948 s1947 0 0 nch W=0.5u L=0.18u
Mp1948 s1948 s1947 vdd vdd pch W=1u L=0.18u
Cl1948 s1948 0 10f
Mn1949 s1949 s1948 0 0 nch W=0.5u L=0.18u
Mp1949 s1949 s1948 vdd vdd pch W=1u L=0.18u
Cl1949 s1949 0 10f
Mn1950 s1950 s1949 0 0 nch W=0.5u L=0.18u
Mp1950 s1950 s1949 vdd vdd pch W=1u L=0.18u
Cl1950 s1950 0 10f
Mn1951 s1951 s1950 0 0 nch W=0.5u L=0.18u
Mp1951 s1951 s1950 vdd vdd pch W=1u L=0.18u
Cl1951 s1951 0 10f
Mn1952 s1952 s1951 0 0 nch W=0.5u L=0.18u
Mp1952 s1952 s1951 vdd vdd pch W=1u L=0.18u
Cl1952 s1952 0 10f
Mn1953 s1953 s1952 0 0 nch W=0.5u L=0.18u
Mp1953 s1953 s1952 vdd vdd pch W=1u L=0.18u
Cl1953 s1953 0 10f
Mn1954 s1954 s1953 0 0 nch W=0.5u L=0.18u
Mp1954 s1954 s1953 vdd vdd pch W=1u L=0.18u
Cl1954 s1954 0 10f
Mn1955 s1955 s1954 0 0 nch W=0.5u L=0.18u
Mp1955 s1955 s1954 vdd vdd pch W=1u L=0.18u
Cl1955 s1955 0 10f
Mn1956 s1956 s1955 0 0 nch W=0.5u L=0.18u
Mp1956 s1956 s1955 vdd vdd pch W=1u L=0.18u
Cl1956 s1956 0 10f
Mn1957 s1957 s1956 0 0 nch W=0.5u L=0.18u
Mp1957 s1957 s1956 vdd vdd pch W=1u L=0.18u
Cl1957 s1957 0 10f
Mn1958 s1958 s1957 0 0 nch W=0.5u L=0.18u
Mp1958 s1958 s1957 vdd vdd pch W=1u L=0.18u
Cl1958 s1958 0 10f
Mn1959 s1959 s1958 0 0 nch W=0.5u L=0.18u
Mp1959 s1959 s1958 vdd vdd pch W=1u L=0.18u
Cl1959 s1959 0 10f
Mn1960 s1960 s1959 0 0 nch W=0.5u L=0.18u
Mp1960 s1960 s1959 vdd vdd pch W=1u L=0.18u
Cl1960 s1960 0 10f
Mn1961 s1961 s1960 0 0 nch W=0.5u L=0.18u
Mp1961 s1961 s1960 vdd vdd pch W=1u L=0.18u
Cl1961 s1961 0 10f
Mn1962 s1962 s1961 0 0 nch W=0.5u L=0.18u
Mp1962 s1962 s1961 vdd vdd pch W=1u L=0.18u
Cl1962 s1962 0 10f
Mn1963 s1963 s1962 0 0 nch W=0.5u L=0.18u
Mp1963 s1963 s1962 vdd vdd pch W=1u L=0.18u
Cl1963 s1963 0 10f
Mn1964 s1964 s1963 0 0 nch W=0.5u L=0.18u
Mp1964 s1964 s1963 vdd vdd pch W=1u L=0.18u
Cl1964 s1964 0 10f
Mn1965 s1965 s1964 0 0 nch W=0.5u L=0.18u
Mp1965 s1965 s1964 vdd vdd pch W=1u L=0.18u
Cl1965 s1965 0 10f
Mn1966 s1966 s1965 0 0 nch W=0.5u L=0.18u
Mp1966 s1966 s1965 vdd vdd pch W=1u L=0.18u
Cl1966 s1966 0 10f
Mn1967 s1967 s1966 0 0 nch W=0.5u L=0.18u
Mp1967 s1967 s1966 vdd vdd pch W=1u L=0.18u
Cl1967 s1967 0 10f
Mn1968 s1968 s1967 0 0 nch W=0.5u L=0.18u
Mp1968 s1968 s1967 vdd vdd pch W=1u L=0.18u
Cl1968 s1968 0 10f
Mn1969 s1969 s1968 0 0 nch W=0.5u L=0.18u
Mp1969 s1969 s1968 vdd vdd pch W=1u L=0.18u
Cl1969 s1969 0 10f
Mn1970 s1970 s1969 0 0 nch W=0.5u L=0.18u
Mp1970 s1970 s1969 vdd vdd pch W=1u L=0.18u
Cl1970 s1970 0 10f
Mn1971 s1971 s1970 0 0 nch W=0.5u L=0.18u
Mp1971 s1971 s1970 vdd vdd pch W=1u L=0.18u
Cl1971 s1971 0 10f
Mn1972 s1972 s1971 0 0 nch W=0.5u L=0.18u
Mp1972 s1972 s1971 vdd vdd pch W=1u L=0.18u
Cl1972 s1972 0 10f
Mn1973 s1973 s1972 0 0 nch W=0.5u L=0.18u
Mp1973 s1973 s1972 vdd vdd pch W=1u L=0.18u
Cl1973 s1973 0 10f
Mn1974 s1974 s1973 0 0 nch W=0.5u L=0.18u
Mp1974 s1974 s1973 vdd vdd pch W=1u L=0.18u
Cl1974 s1974 0 10f
Mn1975 s1975 s1974 0 0 nch W=0.5u L=0.18u
Mp1975 s1975 s1974 vdd vdd pch W=1u L=0.18u
Cl1975 s1975 0 10f
Mn1976 s1976 s1975 0 0 nch W=0.5u L=0.18u
Mp1976 s1976 s1975 vdd vdd pch W=1u L=0.18u
Cl1976 s1976 0 10f
Mn1977 s1977 s1976 0 0 nch W=0.5u L=0.18u
Mp1977 s1977 s1976 vdd vdd pch W=1u L=0.18u
Cl1977 s1977 0 10f
Mn1978 s1978 s1977 0 0 nch W=0.5u L=0.18u
Mp1978 s1978 s1977 vdd vdd pch W=1u L=0.18u
Cl1978 s1978 0 10f
Mn1979 s1979 s1978 0 0 nch W=0.5u L=0.18u
Mp1979 s1979 s1978 vdd vdd pch W=1u L=0.18u
Cl1979 s1979 0 10f
Mn1980 s1980 s1979 0 0 nch W=0.5u L=0.18u
Mp1980 s1980 s1979 vdd vdd pch W=1u L=0.18u
Cl1980 s1980 0 10f
Mn1981 s1981 s1980 0 0 nch W=0.5u L=0.18u
Mp1981 s1981 s1980 vdd vdd pch W=1u L=0.18u
Cl1981 s1981 0 10f
Mn1982 s1982 s1981 0 0 nch W=0.5u L=0.18u
Mp1982 s1982 s1981 vdd vdd pch W=1u L=0.18u
Cl1982 s1982 0 10f
Mn1983 s1983 s1982 0 0 nch W=0.5u L=0.18u
Mp1983 s1983 s1982 vdd vdd pch W=1u L=0.18u
Cl1983 s1983 0 10f
Mn1984 s1984 s1983 0 0 nch W=0.5u L=0.18u
Mp1984 s1984 s1983 vdd vdd pch W=1u L=0.18u
Cl1984 s1984 0 10f
Mn1985 s1985 s1984 0 0 nch W=0.5u L=0.18u
Mp1985 s1985 s1984 vdd vdd pch W=1u L=0.18u
Cl1985 s1985 0 10f
Mn1986 s1986 s1985 0 0 nch W=0.5u L=0.18u
Mp1986 s1986 s1985 vdd vdd pch W=1u L=0.18u
Cl1986 s1986 0 10f
Mn1987 s1987 s1986 0 0 nch W=0.5u L=0.18u
Mp1987 s1987 s1986 vdd vdd pch W=1u L=0.18u
Cl1987 s1987 0 10f
Mn1988 s1988 s1987 0 0 nch W=0.5u L=0.18u
Mp1988 s1988 s1987 vdd vdd pch W=1u L=0.18u
Cl1988 s1988 0 10f
Mn1989 s1989 s1988 0 0 nch W=0.5u L=0.18u
Mp1989 s1989 s1988 vdd vdd pch W=1u L=0.18u
Cl1989 s1989 0 10f
Mn1990 s1990 s1989 0 0 nch W=0.5u L=0.18u
Mp1990 s1990 s1989 vdd vdd pch W=1u L=0.18u
Cl1990 s1990 0 10f
Mn1991 s1991 s1990 0 0 nch W=0.5u L=0.18u
Mp1991 s1991 s1990 vdd vdd pch W=1u L=0.18u
Cl1991 s1991 0 10f
Mn1992 s1992 s1991 0 0 nch W=0.5u L=0.18u
Mp1992 s1992 s1991 vdd vdd pch W=1u L=0.18u
Cl1992 s1992 0 10f
Mn1993 s1993 s1992 0 0 nch W=0.5u L=0.18u
Mp1993 s1993 s1992 vdd vdd pch W=1u L=0.18u
Cl1993 s1993 0 10f
Mn1994 s1994 s1993 0 0 nch W=0.5u L=0.18u
Mp1994 s1994 s1993 vdd vdd pch W=1u L=0.18u
Cl1994 s1994 0 10f
Mn1995 s1995 s1994 0 0 nch W=0.5u L=0.18u
Mp1995 s1995 s1994 vdd vdd pch W=1u L=0.18u
Cl1995 s1995 0 10f
Mn1996 s1996 s1995 0 0 nch W=0.5u L=0.18u
Mp1996 s1996 s1995 vdd vdd pch W=1u L=0.18u
Cl1996 s1996 0 10f
Mn1997 s1997 s1996 0 0 nch W=0.5u L=0.18u
Mp1997 s1997 s1996 vdd vdd pch W=1u L=0.18u
Cl1997 s1997 0 10f
Mn1998 s1998 s1997 0 0 nch W=0.5u L=0.18u
Mp1998 s1998 s1997 vdd vdd pch W=1u L=0.18u
Cl1998 s1998 0 10f
Mn1999 s1999 s1998 0 0 nch W=0.5u L=0.18u
Mp1999 s1999 s1998 vdd vdd pch W=1u L=0.18u
Cl1999 s1999 0 10f
Mn2000 s2000 s1999 0 0 nch W=0.5u L=0.18u
Mp2000 s2000 s1999 vdd vdd pch W=1u L=0.18u
Cl2000 s2000 0 10f
Mn2001 s2001 s2000 0 0 nch W=0.5u L=0.18u
Mp2001 s2001 s2000 vdd vdd pch W=1u L=0.18u
Cl2001 s2001 0 10f
Mn2002 s2002 s2001 0 0 nch W=0.5u L=0.18u
Mp2002 s2002 s2001 vdd vdd pch W=1u L=0.18u
Cl2002 s2002 0 10f
Mn2003 s2003 s2002 0 0 nch W=0.5u L=0.18u
Mp2003 s2003 s2002 vdd vdd pch W=1u L=0.18u
Cl2003 s2003 0 10f
Mn2004 s2004 s2003 0 0 nch W=0.5u L=0.18u
Mp2004 s2004 s2003 vdd vdd pch W=1u L=0.18u
Cl2004 s2004 0 10f
Mn2005 s2005 s2004 0 0 nch W=0.5u L=0.18u
Mp2005 s2005 s2004 vdd vdd pch W=1u L=0.18u
Cl2005 s2005 0 10f
Mn2006 s2006 s2005 0 0 nch W=0.5u L=0.18u
Mp2006 s2006 s2005 vdd vdd pch W=1u L=0.18u
Cl2006 s2006 0 10f
Mn2007 s2007 s2006 0 0 nch W=0.5u L=0.18u
Mp2007 s2007 s2006 vdd vdd pch W=1u L=0.18u
Cl2007 s2007 0 10f
Mn2008 s2008 s2007 0 0 nch W=0.5u L=0.18u
Mp2008 s2008 s2007 vdd vdd pch W=1u L=0.18u
Cl2008 s2008 0 10f
Mn2009 s2009 s2008 0 0 nch W=0.5u L=0.18u
Mp2009 s2009 s2008 vdd vdd pch W=1u L=0.18u
Cl2009 s2009 0 10f
Mn2010 s2010 s2009 0 0 nch W=0.5u L=0.18u
Mp2010 s2010 s2009 vdd vdd pch W=1u L=0.18u
Cl2010 s2010 0 10f
Mn2011 s2011 s2010 0 0 nch W=0.5u L=0.18u
Mp2011 s2011 s2010 vdd vdd pch W=1u L=0.18u
Cl2011 s2011 0 10f
Mn2012 s2012 s2011 0 0 nch W=0.5u L=0.18u
Mp2012 s2012 s2011 vdd vdd pch W=1u L=0.18u
Cl2012 s2012 0 10f
Mn2013 s2013 s2012 0 0 nch W=0.5u L=0.18u
Mp2013 s2013 s2012 vdd vdd pch W=1u L=0.18u
Cl2013 s2013 0 10f
Mn2014 s2014 s2013 0 0 nch W=0.5u L=0.18u
Mp2014 s2014 s2013 vdd vdd pch W=1u L=0.18u
Cl2014 s2014 0 10f
Mn2015 s2015 s2014 0 0 nch W=0.5u L=0.18u
Mp2015 s2015 s2014 vdd vdd pch W=1u L=0.18u
Cl2015 s2015 0 10f
Mn2016 s2016 s2015 0 0 nch W=0.5u L=0.18u
Mp2016 s2016 s2015 vdd vdd pch W=1u L=0.18u
Cl2016 s2016 0 10f
Mn2017 s2017 s2016 0 0 nch W=0.5u L=0.18u
Mp2017 s2017 s2016 vdd vdd pch W=1u L=0.18u
Cl2017 s2017 0 10f
Mn2018 s2018 s2017 0 0 nch W=0.5u L=0.18u
Mp2018 s2018 s2017 vdd vdd pch W=1u L=0.18u
Cl2018 s2018 0 10f
Mn2019 s2019 s2018 0 0 nch W=0.5u L=0.18u
Mp2019 s2019 s2018 vdd vdd pch W=1u L=0.18u
Cl2019 s2019 0 10f
Mn2020 s2020 s2019 0 0 nch W=0.5u L=0.18u
Mp2020 s2020 s2019 vdd vdd pch W=1u L=0.18u
Cl2020 s2020 0 10f
Mn2021 s2021 s2020 0 0 nch W=0.5u L=0.18u
Mp2021 s2021 s2020 vdd vdd pch W=1u L=0.18u
Cl2021 s2021 0 10f
Mn2022 s2022 s2021 0 0 nch W=0.5u L=0.18u
Mp2022 s2022 s2021 vdd vdd pch W=1u L=0.18u
Cl2022 s2022 0 10f
Mn2023 s2023 s2022 0 0 nch W=0.5u L=0.18u
Mp2023 s2023 s2022 vdd vdd pch W=1u L=0.18u
Cl2023 s2023 0 10f
Mn2024 s2024 s2023 0 0 nch W=0.5u L=0.18u
Mp2024 s2024 s2023 vdd vdd pch W=1u L=0.18u
Cl2024 s2024 0 10f
Mn2025 s2025 s2024 0 0 nch W=0.5u L=0.18u
Mp2025 s2025 s2024 vdd vdd pch W=1u L=0.18u
Cl2025 s2025 0 10f
Mn2026 s2026 s2025 0 0 nch W=0.5u L=0.18u
Mp2026 s2026 s2025 vdd vdd pch W=1u L=0.18u
Cl2026 s2026 0 10f
Mn2027 s2027 s2026 0 0 nch W=0.5u L=0.18u
Mp2027 s2027 s2026 vdd vdd pch W=1u L=0.18u
Cl2027 s2027 0 10f
Mn2028 s2028 s2027 0 0 nch W=0.5u L=0.18u
Mp2028 s2028 s2027 vdd vdd pch W=1u L=0.18u
Cl2028 s2028 0 10f
Mn2029 s2029 s2028 0 0 nch W=0.5u L=0.18u
Mp2029 s2029 s2028 vdd vdd pch W=1u L=0.18u
Cl2029 s2029 0 10f
Mn2030 s2030 s2029 0 0 nch W=0.5u L=0.18u
Mp2030 s2030 s2029 vdd vdd pch W=1u L=0.18u
Cl2030 s2030 0 10f
Mn2031 s2031 s2030 0 0 nch W=0.5u L=0.18u
Mp2031 s2031 s2030 vdd vdd pch W=1u L=0.18u
Cl2031 s2031 0 10f
Mn2032 s2032 s2031 0 0 nch W=0.5u L=0.18u
Mp2032 s2032 s2031 vdd vdd pch W=1u L=0.18u
Cl2032 s2032 0 10f
Mn2033 s2033 s2032 0 0 nch W=0.5u L=0.18u
Mp2033 s2033 s2032 vdd vdd pch W=1u L=0.18u
Cl2033 s2033 0 10f
Mn2034 s2034 s2033 0 0 nch W=0.5u L=0.18u
Mp2034 s2034 s2033 vdd vdd pch W=1u L=0.18u
Cl2034 s2034 0 10f
Mn2035 s2035 s2034 0 0 nch W=0.5u L=0.18u
Mp2035 s2035 s2034 vdd vdd pch W=1u L=0.18u
Cl2035 s2035 0 10f
Mn2036 s2036 s2035 0 0 nch W=0.5u L=0.18u
Mp2036 s2036 s2035 vdd vdd pch W=1u L=0.18u
Cl2036 s2036 0 10f
Mn2037 s2037 s2036 0 0 nch W=0.5u L=0.18u
Mp2037 s2037 s2036 vdd vdd pch W=1u L=0.18u
Cl2037 s2037 0 10f
Mn2038 s2038 s2037 0 0 nch W=0.5u L=0.18u
Mp2038 s2038 s2037 vdd vdd pch W=1u L=0.18u
Cl2038 s2038 0 10f
Mn2039 s2039 s2038 0 0 nch W=0.5u L=0.18u
Mp2039 s2039 s2038 vdd vdd pch W=1u L=0.18u
Cl2039 s2039 0 10f
Mn2040 s2040 s2039 0 0 nch W=0.5u L=0.18u
Mp2040 s2040 s2039 vdd vdd pch W=1u L=0.18u
Cl2040 s2040 0 10f
Mn2041 s2041 s2040 0 0 nch W=0.5u L=0.18u
Mp2041 s2041 s2040 vdd vdd pch W=1u L=0.18u
Cl2041 s2041 0 10f
Mn2042 s2042 s2041 0 0 nch W=0.5u L=0.18u
Mp2042 s2042 s2041 vdd vdd pch W=1u L=0.18u
Cl2042 s2042 0 10f
Mn2043 s2043 s2042 0 0 nch W=0.5u L=0.18u
Mp2043 s2043 s2042 vdd vdd pch W=1u L=0.18u
Cl2043 s2043 0 10f
Mn2044 s2044 s2043 0 0 nch W=0.5u L=0.18u
Mp2044 s2044 s2043 vdd vdd pch W=1u L=0.18u
Cl2044 s2044 0 10f
Mn2045 s2045 s2044 0 0 nch W=0.5u L=0.18u
Mp2045 s2045 s2044 vdd vdd pch W=1u L=0.18u
Cl2045 s2045 0 10f
Mn2046 s2046 s2045 0 0 nch W=0.5u L=0.18u
Mp2046 s2046 s2045 vdd vdd pch W=1u L=0.18u
Cl2046 s2046 0 10f
Mn2047 s2047 s2046 0 0 nch W=0.5u L=0.18u
Mp2047 s2047 s2046 vdd vdd pch W=1u L=0.18u
Cl2047 s2047 0 10f
Mn2048 s2048 s2047 0 0 nch W=0.5u L=0.18u
Mp2048 s2048 s2047 vdd vdd pch W=1u L=0.18u
Cl2048 s2048 0 10f
Mn2049 s2049 s2048 0 0 nch W=0.5u L=0.18u
Mp2049 s2049 s2048 vdd vdd pch W=1u L=0.18u
Cl2049 s2049 0 10f
Mn2050 s2050 s2049 0 0 nch W=0.5u L=0.18u
Mp2050 s2050 s2049 vdd vdd pch W=1u L=0.18u
Cl2050 s2050 0 10f
Mn2051 s2051 s2050 0 0 nch W=0.5u L=0.18u
Mp2051 s2051 s2050 vdd vdd pch W=1u L=0.18u
Cl2051 s2051 0 10f
Mn2052 s2052 s2051 0 0 nch W=0.5u L=0.18u
Mp2052 s2052 s2051 vdd vdd pch W=1u L=0.18u
Cl2052 s2052 0 10f
Mn2053 s2053 s2052 0 0 nch W=0.5u L=0.18u
Mp2053 s2053 s2052 vdd vdd pch W=1u L=0.18u
Cl2053 s2053 0 10f
Mn2054 s2054 s2053 0 0 nch W=0.5u L=0.18u
Mp2054 s2054 s2053 vdd vdd pch W=1u L=0.18u
Cl2054 s2054 0 10f
Mn2055 s2055 s2054 0 0 nch W=0.5u L=0.18u
Mp2055 s2055 s2054 vdd vdd pch W=1u L=0.18u
Cl2055 s2055 0 10f
Mn2056 s2056 s2055 0 0 nch W=0.5u L=0.18u
Mp2056 s2056 s2055 vdd vdd pch W=1u L=0.18u
Cl2056 s2056 0 10f
Mn2057 s2057 s2056 0 0 nch W=0.5u L=0.18u
Mp2057 s2057 s2056 vdd vdd pch W=1u L=0.18u
Cl2057 s2057 0 10f
Mn2058 s2058 s2057 0 0 nch W=0.5u L=0.18u
Mp2058 s2058 s2057 vdd vdd pch W=1u L=0.18u
Cl2058 s2058 0 10f
Mn2059 s2059 s2058 0 0 nch W=0.5u L=0.18u
Mp2059 s2059 s2058 vdd vdd pch W=1u L=0.18u
Cl2059 s2059 0 10f
Mn2060 s2060 s2059 0 0 nch W=0.5u L=0.18u
Mp2060 s2060 s2059 vdd vdd pch W=1u L=0.18u
Cl2060 s2060 0 10f
Mn2061 s2061 s2060 0 0 nch W=0.5u L=0.18u
Mp2061 s2061 s2060 vdd vdd pch W=1u L=0.18u
Cl2061 s2061 0 10f
Mn2062 s2062 s2061 0 0 nch W=0.5u L=0.18u
Mp2062 s2062 s2061 vdd vdd pch W=1u L=0.18u
Cl2062 s2062 0 10f
Mn2063 s2063 s2062 0 0 nch W=0.5u L=0.18u
Mp2063 s2063 s2062 vdd vdd pch W=1u L=0.18u
Cl2063 s2063 0 10f
Mn2064 s2064 s2063 0 0 nch W=0.5u L=0.18u
Mp2064 s2064 s2063 vdd vdd pch W=1u L=0.18u
Cl2064 s2064 0 10f
Mn2065 s2065 s2064 0 0 nch W=0.5u L=0.18u
Mp2065 s2065 s2064 vdd vdd pch W=1u L=0.18u
Cl2065 s2065 0 10f
Mn2066 s2066 s2065 0 0 nch W=0.5u L=0.18u
Mp2066 s2066 s2065 vdd vdd pch W=1u L=0.18u
Cl2066 s2066 0 10f
Mn2067 s2067 s2066 0 0 nch W=0.5u L=0.18u
Mp2067 s2067 s2066 vdd vdd pch W=1u L=0.18u
Cl2067 s2067 0 10f
Mn2068 s2068 s2067 0 0 nch W=0.5u L=0.18u
Mp2068 s2068 s2067 vdd vdd pch W=1u L=0.18u
Cl2068 s2068 0 10f
Mn2069 s2069 s2068 0 0 nch W=0.5u L=0.18u
Mp2069 s2069 s2068 vdd vdd pch W=1u L=0.18u
Cl2069 s2069 0 10f
Mn2070 s2070 s2069 0 0 nch W=0.5u L=0.18u
Mp2070 s2070 s2069 vdd vdd pch W=1u L=0.18u
Cl2070 s2070 0 10f
Mn2071 s2071 s2070 0 0 nch W=0.5u L=0.18u
Mp2071 s2071 s2070 vdd vdd pch W=1u L=0.18u
Cl2071 s2071 0 10f
Mn2072 s2072 s2071 0 0 nch W=0.5u L=0.18u
Mp2072 s2072 s2071 vdd vdd pch W=1u L=0.18u
Cl2072 s2072 0 10f
Mn2073 s2073 s2072 0 0 nch W=0.5u L=0.18u
Mp2073 s2073 s2072 vdd vdd pch W=1u L=0.18u
Cl2073 s2073 0 10f
Mn2074 s2074 s2073 0 0 nch W=0.5u L=0.18u
Mp2074 s2074 s2073 vdd vdd pch W=1u L=0.18u
Cl2074 s2074 0 10f
Mn2075 s2075 s2074 0 0 nch W=0.5u L=0.18u
Mp2075 s2075 s2074 vdd vdd pch W=1u L=0.18u
Cl2075 s2075 0 10f
Mn2076 s2076 s2075 0 0 nch W=0.5u L=0.18u
Mp2076 s2076 s2075 vdd vdd pch W=1u L=0.18u
Cl2076 s2076 0 10f
Mn2077 s2077 s2076 0 0 nch W=0.5u L=0.18u
Mp2077 s2077 s2076 vdd vdd pch W=1u L=0.18u
Cl2077 s2077 0 10f
Mn2078 s2078 s2077 0 0 nch W=0.5u L=0.18u
Mp2078 s2078 s2077 vdd vdd pch W=1u L=0.18u
Cl2078 s2078 0 10f
Mn2079 s2079 s2078 0 0 nch W=0.5u L=0.18u
Mp2079 s2079 s2078 vdd vdd pch W=1u L=0.18u
Cl2079 s2079 0 10f
Mn2080 s2080 s2079 0 0 nch W=0.5u L=0.18u
Mp2080 s2080 s2079 vdd vdd pch W=1u L=0.18u
Cl2080 s2080 0 10f
Mn2081 s2081 s2080 0 0 nch W=0.5u L=0.18u
Mp2081 s2081 s2080 vdd vdd pch W=1u L=0.18u
Cl2081 s2081 0 10f
Mn2082 s2082 s2081 0 0 nch W=0.5u L=0.18u
Mp2082 s2082 s2081 vdd vdd pch W=1u L=0.18u
Cl2082 s2082 0 10f
Mn2083 s2083 s2082 0 0 nch W=0.5u L=0.18u
Mp2083 s2083 s2082 vdd vdd pch W=1u L=0.18u
Cl2083 s2083 0 10f
Mn2084 s2084 s2083 0 0 nch W=0.5u L=0.18u
Mp2084 s2084 s2083 vdd vdd pch W=1u L=0.18u
Cl2084 s2084 0 10f
Mn2085 s2085 s2084 0 0 nch W=0.5u L=0.18u
Mp2085 s2085 s2084 vdd vdd pch W=1u L=0.18u
Cl2085 s2085 0 10f
Mn2086 s2086 s2085 0 0 nch W=0.5u L=0.18u
Mp2086 s2086 s2085 vdd vdd pch W=1u L=0.18u
Cl2086 s2086 0 10f
Mn2087 s2087 s2086 0 0 nch W=0.5u L=0.18u
Mp2087 s2087 s2086 vdd vdd pch W=1u L=0.18u
Cl2087 s2087 0 10f
Mn2088 s2088 s2087 0 0 nch W=0.5u L=0.18u
Mp2088 s2088 s2087 vdd vdd pch W=1u L=0.18u
Cl2088 s2088 0 10f
Mn2089 s2089 s2088 0 0 nch W=0.5u L=0.18u
Mp2089 s2089 s2088 vdd vdd pch W=1u L=0.18u
Cl2089 s2089 0 10f
Mn2090 s2090 s2089 0 0 nch W=0.5u L=0.18u
Mp2090 s2090 s2089 vdd vdd pch W=1u L=0.18u
Cl2090 s2090 0 10f
Mn2091 s2091 s2090 0 0 nch W=0.5u L=0.18u
Mp2091 s2091 s2090 vdd vdd pch W=1u L=0.18u
Cl2091 s2091 0 10f
Mn2092 s2092 s2091 0 0 nch W=0.5u L=0.18u
Mp2092 s2092 s2091 vdd vdd pch W=1u L=0.18u
Cl2092 s2092 0 10f
Mn2093 s2093 s2092 0 0 nch W=0.5u L=0.18u
Mp2093 s2093 s2092 vdd vdd pch W=1u L=0.18u
Cl2093 s2093 0 10f
Mn2094 s2094 s2093 0 0 nch W=0.5u L=0.18u
Mp2094 s2094 s2093 vdd vdd pch W=1u L=0.18u
Cl2094 s2094 0 10f
Mn2095 s2095 s2094 0 0 nch W=0.5u L=0.18u
Mp2095 s2095 s2094 vdd vdd pch W=1u L=0.18u
Cl2095 s2095 0 10f
Mn2096 s2096 s2095 0 0 nch W=0.5u L=0.18u
Mp2096 s2096 s2095 vdd vdd pch W=1u L=0.18u
Cl2096 s2096 0 10f
Mn2097 s2097 s2096 0 0 nch W=0.5u L=0.18u
Mp2097 s2097 s2096 vdd vdd pch W=1u L=0.18u
Cl2097 s2097 0 10f
Mn2098 s2098 s2097 0 0 nch W=0.5u L=0.18u
Mp2098 s2098 s2097 vdd vdd pch W=1u L=0.18u
Cl2098 s2098 0 10f
Mn2099 s2099 s2098 0 0 nch W=0.5u L=0.18u
Mp2099 s2099 s2098 vdd vdd pch W=1u L=0.18u
Cl2099 s2099 0 10f
Mn2100 s2100 s2099 0 0 nch W=0.5u L=0.18u
Mp2100 s2100 s2099 vdd vdd pch W=1u L=0.18u
Cl2100 s2100 0 10f
Mn2101 s2101 s2100 0 0 nch W=0.5u L=0.18u
Mp2101 s2101 s2100 vdd vdd pch W=1u L=0.18u
Cl2101 s2101 0 10f
Mn2102 s2102 s2101 0 0 nch W=0.5u L=0.18u
Mp2102 s2102 s2101 vdd vdd pch W=1u L=0.18u
Cl2102 s2102 0 10f
Mn2103 s2103 s2102 0 0 nch W=0.5u L=0.18u
Mp2103 s2103 s2102 vdd vdd pch W=1u L=0.18u
Cl2103 s2103 0 10f
Mn2104 s2104 s2103 0 0 nch W=0.5u L=0.18u
Mp2104 s2104 s2103 vdd vdd pch W=1u L=0.18u
Cl2104 s2104 0 10f
Mn2105 s2105 s2104 0 0 nch W=0.5u L=0.18u
Mp2105 s2105 s2104 vdd vdd pch W=1u L=0.18u
Cl2105 s2105 0 10f
Mn2106 s2106 s2105 0 0 nch W=0.5u L=0.18u
Mp2106 s2106 s2105 vdd vdd pch W=1u L=0.18u
Cl2106 s2106 0 10f
Mn2107 s2107 s2106 0 0 nch W=0.5u L=0.18u
Mp2107 s2107 s2106 vdd vdd pch W=1u L=0.18u
Cl2107 s2107 0 10f
Mn2108 s2108 s2107 0 0 nch W=0.5u L=0.18u
Mp2108 s2108 s2107 vdd vdd pch W=1u L=0.18u
Cl2108 s2108 0 10f
Mn2109 s2109 s2108 0 0 nch W=0.5u L=0.18u
Mp2109 s2109 s2108 vdd vdd pch W=1u L=0.18u
Cl2109 s2109 0 10f
Mn2110 s2110 s2109 0 0 nch W=0.5u L=0.18u
Mp2110 s2110 s2109 vdd vdd pch W=1u L=0.18u
Cl2110 s2110 0 10f
Mn2111 s2111 s2110 0 0 nch W=0.5u L=0.18u
Mp2111 s2111 s2110 vdd vdd pch W=1u L=0.18u
Cl2111 s2111 0 10f
Mn2112 s2112 s2111 0 0 nch W=0.5u L=0.18u
Mp2112 s2112 s2111 vdd vdd pch W=1u L=0.18u
Cl2112 s2112 0 10f
Mn2113 s2113 s2112 0 0 nch W=0.5u L=0.18u
Mp2113 s2113 s2112 vdd vdd pch W=1u L=0.18u
Cl2113 s2113 0 10f
Mn2114 s2114 s2113 0 0 nch W=0.5u L=0.18u
Mp2114 s2114 s2113 vdd vdd pch W=1u L=0.18u
Cl2114 s2114 0 10f
Mn2115 s2115 s2114 0 0 nch W=0.5u L=0.18u
Mp2115 s2115 s2114 vdd vdd pch W=1u L=0.18u
Cl2115 s2115 0 10f
Mn2116 s2116 s2115 0 0 nch W=0.5u L=0.18u
Mp2116 s2116 s2115 vdd vdd pch W=1u L=0.18u
Cl2116 s2116 0 10f
Mn2117 s2117 s2116 0 0 nch W=0.5u L=0.18u
Mp2117 s2117 s2116 vdd vdd pch W=1u L=0.18u
Cl2117 s2117 0 10f
Mn2118 s2118 s2117 0 0 nch W=0.5u L=0.18u
Mp2118 s2118 s2117 vdd vdd pch W=1u L=0.18u
Cl2118 s2118 0 10f
Mn2119 s2119 s2118 0 0 nch W=0.5u L=0.18u
Mp2119 s2119 s2118 vdd vdd pch W=1u L=0.18u
Cl2119 s2119 0 10f
Mn2120 s2120 s2119 0 0 nch W=0.5u L=0.18u
Mp2120 s2120 s2119 vdd vdd pch W=1u L=0.18u
Cl2120 s2120 0 10f
Mn2121 s2121 s2120 0 0 nch W=0.5u L=0.18u
Mp2121 s2121 s2120 vdd vdd pch W=1u L=0.18u
Cl2121 s2121 0 10f
Mn2122 s2122 s2121 0 0 nch W=0.5u L=0.18u
Mp2122 s2122 s2121 vdd vdd pch W=1u L=0.18u
Cl2122 s2122 0 10f
Mn2123 s2123 s2122 0 0 nch W=0.5u L=0.18u
Mp2123 s2123 s2122 vdd vdd pch W=1u L=0.18u
Cl2123 s2123 0 10f
Mn2124 s2124 s2123 0 0 nch W=0.5u L=0.18u
Mp2124 s2124 s2123 vdd vdd pch W=1u L=0.18u
Cl2124 s2124 0 10f
Mn2125 s2125 s2124 0 0 nch W=0.5u L=0.18u
Mp2125 s2125 s2124 vdd vdd pch W=1u L=0.18u
Cl2125 s2125 0 10f
Mn2126 s2126 s2125 0 0 nch W=0.5u L=0.18u
Mp2126 s2126 s2125 vdd vdd pch W=1u L=0.18u
Cl2126 s2126 0 10f
Mn2127 s2127 s2126 0 0 nch W=0.5u L=0.18u
Mp2127 s2127 s2126 vdd vdd pch W=1u L=0.18u
Cl2127 s2127 0 10f
Mn2128 s2128 s2127 0 0 nch W=0.5u L=0.18u
Mp2128 s2128 s2127 vdd vdd pch W=1u L=0.18u
Cl2128 s2128 0 10f
Mn2129 s2129 s2128 0 0 nch W=0.5u L=0.18u
Mp2129 s2129 s2128 vdd vdd pch W=1u L=0.18u
Cl2129 s2129 0 10f
Mn2130 s2130 s2129 0 0 nch W=0.5u L=0.18u
Mp2130 s2130 s2129 vdd vdd pch W=1u L=0.18u
Cl2130 s2130 0 10f
Mn2131 s2131 s2130 0 0 nch W=0.5u L=0.18u
Mp2131 s2131 s2130 vdd vdd pch W=1u L=0.18u
Cl2131 s2131 0 10f
Mn2132 s2132 s2131 0 0 nch W=0.5u L=0.18u
Mp2132 s2132 s2131 vdd vdd pch W=1u L=0.18u
Cl2132 s2132 0 10f
Mn2133 s2133 s2132 0 0 nch W=0.5u L=0.18u
Mp2133 s2133 s2132 vdd vdd pch W=1u L=0.18u
Cl2133 s2133 0 10f
Mn2134 s2134 s2133 0 0 nch W=0.5u L=0.18u
Mp2134 s2134 s2133 vdd vdd pch W=1u L=0.18u
Cl2134 s2134 0 10f
Mn2135 s2135 s2134 0 0 nch W=0.5u L=0.18u
Mp2135 s2135 s2134 vdd vdd pch W=1u L=0.18u
Cl2135 s2135 0 10f
Mn2136 s2136 s2135 0 0 nch W=0.5u L=0.18u
Mp2136 s2136 s2135 vdd vdd pch W=1u L=0.18u
Cl2136 s2136 0 10f
Mn2137 s2137 s2136 0 0 nch W=0.5u L=0.18u
Mp2137 s2137 s2136 vdd vdd pch W=1u L=0.18u
Cl2137 s2137 0 10f
Mn2138 s2138 s2137 0 0 nch W=0.5u L=0.18u
Mp2138 s2138 s2137 vdd vdd pch W=1u L=0.18u
Cl2138 s2138 0 10f
Mn2139 s2139 s2138 0 0 nch W=0.5u L=0.18u
Mp2139 s2139 s2138 vdd vdd pch W=1u L=0.18u
Cl2139 s2139 0 10f
Mn2140 s2140 s2139 0 0 nch W=0.5u L=0.18u
Mp2140 s2140 s2139 vdd vdd pch W=1u L=0.18u
Cl2140 s2140 0 10f
Mn2141 s2141 s2140 0 0 nch W=0.5u L=0.18u
Mp2141 s2141 s2140 vdd vdd pch W=1u L=0.18u
Cl2141 s2141 0 10f
Mn2142 s2142 s2141 0 0 nch W=0.5u L=0.18u
Mp2142 s2142 s2141 vdd vdd pch W=1u L=0.18u
Cl2142 s2142 0 10f
Mn2143 s2143 s2142 0 0 nch W=0.5u L=0.18u
Mp2143 s2143 s2142 vdd vdd pch W=1u L=0.18u
Cl2143 s2143 0 10f
Mn2144 s2144 s2143 0 0 nch W=0.5u L=0.18u
Mp2144 s2144 s2143 vdd vdd pch W=1u L=0.18u
Cl2144 s2144 0 10f
Mn2145 s2145 s2144 0 0 nch W=0.5u L=0.18u
Mp2145 s2145 s2144 vdd vdd pch W=1u L=0.18u
Cl2145 s2145 0 10f
Mn2146 s2146 s2145 0 0 nch W=0.5u L=0.18u
Mp2146 s2146 s2145 vdd vdd pch W=1u L=0.18u
Cl2146 s2146 0 10f
Mn2147 s2147 s2146 0 0 nch W=0.5u L=0.18u
Mp2147 s2147 s2146 vdd vdd pch W=1u L=0.18u
Cl2147 s2147 0 10f
Mn2148 s2148 s2147 0 0 nch W=0.5u L=0.18u
Mp2148 s2148 s2147 vdd vdd pch W=1u L=0.18u
Cl2148 s2148 0 10f
Mn2149 s2149 s2148 0 0 nch W=0.5u L=0.18u
Mp2149 s2149 s2148 vdd vdd pch W=1u L=0.18u
Cl2149 s2149 0 10f
Mn2150 s2150 s2149 0 0 nch W=0.5u L=0.18u
Mp2150 s2150 s2149 vdd vdd pch W=1u L=0.18u
Cl2150 s2150 0 10f
Mn2151 s2151 s2150 0 0 nch W=0.5u L=0.18u
Mp2151 s2151 s2150 vdd vdd pch W=1u L=0.18u
Cl2151 s2151 0 10f
Mn2152 s2152 s2151 0 0 nch W=0.5u L=0.18u
Mp2152 s2152 s2151 vdd vdd pch W=1u L=0.18u
Cl2152 s2152 0 10f
Mn2153 s2153 s2152 0 0 nch W=0.5u L=0.18u
Mp2153 s2153 s2152 vdd vdd pch W=1u L=0.18u
Cl2153 s2153 0 10f
Mn2154 s2154 s2153 0 0 nch W=0.5u L=0.18u
Mp2154 s2154 s2153 vdd vdd pch W=1u L=0.18u
Cl2154 s2154 0 10f
Mn2155 s2155 s2154 0 0 nch W=0.5u L=0.18u
Mp2155 s2155 s2154 vdd vdd pch W=1u L=0.18u
Cl2155 s2155 0 10f
Mn2156 s2156 s2155 0 0 nch W=0.5u L=0.18u
Mp2156 s2156 s2155 vdd vdd pch W=1u L=0.18u
Cl2156 s2156 0 10f
Mn2157 s2157 s2156 0 0 nch W=0.5u L=0.18u
Mp2157 s2157 s2156 vdd vdd pch W=1u L=0.18u
Cl2157 s2157 0 10f
Mn2158 s2158 s2157 0 0 nch W=0.5u L=0.18u
Mp2158 s2158 s2157 vdd vdd pch W=1u L=0.18u
Cl2158 s2158 0 10f
Mn2159 s2159 s2158 0 0 nch W=0.5u L=0.18u
Mp2159 s2159 s2158 vdd vdd pch W=1u L=0.18u
Cl2159 s2159 0 10f
Mn2160 s2160 s2159 0 0 nch W=0.5u L=0.18u
Mp2160 s2160 s2159 vdd vdd pch W=1u L=0.18u
Cl2160 s2160 0 10f
Mn2161 s2161 s2160 0 0 nch W=0.5u L=0.18u
Mp2161 s2161 s2160 vdd vdd pch W=1u L=0.18u
Cl2161 s2161 0 10f
Mn2162 s2162 s2161 0 0 nch W=0.5u L=0.18u
Mp2162 s2162 s2161 vdd vdd pch W=1u L=0.18u
Cl2162 s2162 0 10f
Mn2163 s2163 s2162 0 0 nch W=0.5u L=0.18u
Mp2163 s2163 s2162 vdd vdd pch W=1u L=0.18u
Cl2163 s2163 0 10f
Mn2164 s2164 s2163 0 0 nch W=0.5u L=0.18u
Mp2164 s2164 s2163 vdd vdd pch W=1u L=0.18u
Cl2164 s2164 0 10f
Mn2165 s2165 s2164 0 0 nch W=0.5u L=0.18u
Mp2165 s2165 s2164 vdd vdd pch W=1u L=0.18u
Cl2165 s2165 0 10f
Mn2166 s2166 s2165 0 0 nch W=0.5u L=0.18u
Mp2166 s2166 s2165 vdd vdd pch W=1u L=0.18u
Cl2166 s2166 0 10f
Mn2167 s2167 s2166 0 0 nch W=0.5u L=0.18u
Mp2167 s2167 s2166 vdd vdd pch W=1u L=0.18u
Cl2167 s2167 0 10f
Mn2168 s2168 s2167 0 0 nch W=0.5u L=0.18u
Mp2168 s2168 s2167 vdd vdd pch W=1u L=0.18u
Cl2168 s2168 0 10f
Mn2169 s2169 s2168 0 0 nch W=0.5u L=0.18u
Mp2169 s2169 s2168 vdd vdd pch W=1u L=0.18u
Cl2169 s2169 0 10f
Mn2170 s2170 s2169 0 0 nch W=0.5u L=0.18u
Mp2170 s2170 s2169 vdd vdd pch W=1u L=0.18u
Cl2170 s2170 0 10f
Mn2171 s2171 s2170 0 0 nch W=0.5u L=0.18u
Mp2171 s2171 s2170 vdd vdd pch W=1u L=0.18u
Cl2171 s2171 0 10f
Mn2172 s2172 s2171 0 0 nch W=0.5u L=0.18u
Mp2172 s2172 s2171 vdd vdd pch W=1u L=0.18u
Cl2172 s2172 0 10f
Mn2173 s2173 s2172 0 0 nch W=0.5u L=0.18u
Mp2173 s2173 s2172 vdd vdd pch W=1u L=0.18u
Cl2173 s2173 0 10f
Mn2174 s2174 s2173 0 0 nch W=0.5u L=0.18u
Mp2174 s2174 s2173 vdd vdd pch W=1u L=0.18u
Cl2174 s2174 0 10f
Mn2175 s2175 s2174 0 0 nch W=0.5u L=0.18u
Mp2175 s2175 s2174 vdd vdd pch W=1u L=0.18u
Cl2175 s2175 0 10f
Mn2176 s2176 s2175 0 0 nch W=0.5u L=0.18u
Mp2176 s2176 s2175 vdd vdd pch W=1u L=0.18u
Cl2176 s2176 0 10f
Mn2177 s2177 s2176 0 0 nch W=0.5u L=0.18u
Mp2177 s2177 s2176 vdd vdd pch W=1u L=0.18u
Cl2177 s2177 0 10f
Mn2178 s2178 s2177 0 0 nch W=0.5u L=0.18u
Mp2178 s2178 s2177 vdd vdd pch W=1u L=0.18u
Cl2178 s2178 0 10f
Mn2179 s2179 s2178 0 0 nch W=0.5u L=0.18u
Mp2179 s2179 s2178 vdd vdd pch W=1u L=0.18u
Cl2179 s2179 0 10f
Mn2180 s2180 s2179 0 0 nch W=0.5u L=0.18u
Mp2180 s2180 s2179 vdd vdd pch W=1u L=0.18u
Cl2180 s2180 0 10f
Mn2181 s2181 s2180 0 0 nch W=0.5u L=0.18u
Mp2181 s2181 s2180 vdd vdd pch W=1u L=0.18u
Cl2181 s2181 0 10f
Mn2182 s2182 s2181 0 0 nch W=0.5u L=0.18u
Mp2182 s2182 s2181 vdd vdd pch W=1u L=0.18u
Cl2182 s2182 0 10f
Mn2183 s2183 s2182 0 0 nch W=0.5u L=0.18u
Mp2183 s2183 s2182 vdd vdd pch W=1u L=0.18u
Cl2183 s2183 0 10f
Mn2184 s2184 s2183 0 0 nch W=0.5u L=0.18u
Mp2184 s2184 s2183 vdd vdd pch W=1u L=0.18u
Cl2184 s2184 0 10f
Mn2185 s2185 s2184 0 0 nch W=0.5u L=0.18u
Mp2185 s2185 s2184 vdd vdd pch W=1u L=0.18u
Cl2185 s2185 0 10f
Mn2186 s2186 s2185 0 0 nch W=0.5u L=0.18u
Mp2186 s2186 s2185 vdd vdd pch W=1u L=0.18u
Cl2186 s2186 0 10f
Mn2187 s2187 s2186 0 0 nch W=0.5u L=0.18u
Mp2187 s2187 s2186 vdd vdd pch W=1u L=0.18u
Cl2187 s2187 0 10f
Mn2188 s2188 s2187 0 0 nch W=0.5u L=0.18u
Mp2188 s2188 s2187 vdd vdd pch W=1u L=0.18u
Cl2188 s2188 0 10f
Mn2189 s2189 s2188 0 0 nch W=0.5u L=0.18u
Mp2189 s2189 s2188 vdd vdd pch W=1u L=0.18u
Cl2189 s2189 0 10f
Mn2190 s2190 s2189 0 0 nch W=0.5u L=0.18u
Mp2190 s2190 s2189 vdd vdd pch W=1u L=0.18u
Cl2190 s2190 0 10f
Mn2191 s2191 s2190 0 0 nch W=0.5u L=0.18u
Mp2191 s2191 s2190 vdd vdd pch W=1u L=0.18u
Cl2191 s2191 0 10f
Mn2192 s2192 s2191 0 0 nch W=0.5u L=0.18u
Mp2192 s2192 s2191 vdd vdd pch W=1u L=0.18u
Cl2192 s2192 0 10f
Mn2193 s2193 s2192 0 0 nch W=0.5u L=0.18u
Mp2193 s2193 s2192 vdd vdd pch W=1u L=0.18u
Cl2193 s2193 0 10f
Mn2194 s2194 s2193 0 0 nch W=0.5u L=0.18u
Mp2194 s2194 s2193 vdd vdd pch W=1u L=0.18u
Cl2194 s2194 0 10f
Mn2195 s2195 s2194 0 0 nch W=0.5u L=0.18u
Mp2195 s2195 s2194 vdd vdd pch W=1u L=0.18u
Cl2195 s2195 0 10f
Mn2196 s2196 s2195 0 0 nch W=0.5u L=0.18u
Mp2196 s2196 s2195 vdd vdd pch W=1u L=0.18u
Cl2196 s2196 0 10f
Mn2197 s2197 s2196 0 0 nch W=0.5u L=0.18u
Mp2197 s2197 s2196 vdd vdd pch W=1u L=0.18u
Cl2197 s2197 0 10f
Mn2198 s2198 s2197 0 0 nch W=0.5u L=0.18u
Mp2198 s2198 s2197 vdd vdd pch W=1u L=0.18u
Cl2198 s2198 0 10f
Mn2199 s2199 s2198 0 0 nch W=0.5u L=0.18u
Mp2199 s2199 s2198 vdd vdd pch W=1u L=0.18u
Cl2199 s2199 0 10f
Mn2200 s2200 s2199 0 0 nch W=0.5u L=0.18u
Mp2200 s2200 s2199 vdd vdd pch W=1u L=0.18u
Cl2200 s2200 0 10f
Mn2201 s2201 s2200 0 0 nch W=0.5u L=0.18u
Mp2201 s2201 s2200 vdd vdd pch W=1u L=0.18u
Cl2201 s2201 0 10f
Mn2202 s2202 s2201 0 0 nch W=0.5u L=0.18u
Mp2202 s2202 s2201 vdd vdd pch W=1u L=0.18u
Cl2202 s2202 0 10f
Mn2203 s2203 s2202 0 0 nch W=0.5u L=0.18u
Mp2203 s2203 s2202 vdd vdd pch W=1u L=0.18u
Cl2203 s2203 0 10f
Mn2204 s2204 s2203 0 0 nch W=0.5u L=0.18u
Mp2204 s2204 s2203 vdd vdd pch W=1u L=0.18u
Cl2204 s2204 0 10f
Mn2205 s2205 s2204 0 0 nch W=0.5u L=0.18u
Mp2205 s2205 s2204 vdd vdd pch W=1u L=0.18u
Cl2205 s2205 0 10f
Mn2206 s2206 s2205 0 0 nch W=0.5u L=0.18u
Mp2206 s2206 s2205 vdd vdd pch W=1u L=0.18u
Cl2206 s2206 0 10f
Mn2207 s2207 s2206 0 0 nch W=0.5u L=0.18u
Mp2207 s2207 s2206 vdd vdd pch W=1u L=0.18u
Cl2207 s2207 0 10f
Mn2208 s2208 s2207 0 0 nch W=0.5u L=0.18u
Mp2208 s2208 s2207 vdd vdd pch W=1u L=0.18u
Cl2208 s2208 0 10f
Mn2209 s2209 s2208 0 0 nch W=0.5u L=0.18u
Mp2209 s2209 s2208 vdd vdd pch W=1u L=0.18u
Cl2209 s2209 0 10f
Mn2210 s2210 s2209 0 0 nch W=0.5u L=0.18u
Mp2210 s2210 s2209 vdd vdd pch W=1u L=0.18u
Cl2210 s2210 0 10f
Mn2211 s2211 s2210 0 0 nch W=0.5u L=0.18u
Mp2211 s2211 s2210 vdd vdd pch W=1u L=0.18u
Cl2211 s2211 0 10f
Mn2212 s2212 s2211 0 0 nch W=0.5u L=0.18u
Mp2212 s2212 s2211 vdd vdd pch W=1u L=0.18u
Cl2212 s2212 0 10f
Mn2213 s2213 s2212 0 0 nch W=0.5u L=0.18u
Mp2213 s2213 s2212 vdd vdd pch W=1u L=0.18u
Cl2213 s2213 0 10f
Mn2214 s2214 s2213 0 0 nch W=0.5u L=0.18u
Mp2214 s2214 s2213 vdd vdd pch W=1u L=0.18u
Cl2214 s2214 0 10f
Mn2215 s2215 s2214 0 0 nch W=0.5u L=0.18u
Mp2215 s2215 s2214 vdd vdd pch W=1u L=0.18u
Cl2215 s2215 0 10f
Mn2216 s2216 s2215 0 0 nch W=0.5u L=0.18u
Mp2216 s2216 s2215 vdd vdd pch W=1u L=0.18u
Cl2216 s2216 0 10f
Mn2217 s2217 s2216 0 0 nch W=0.5u L=0.18u
Mp2217 s2217 s2216 vdd vdd pch W=1u L=0.18u
Cl2217 s2217 0 10f
Mn2218 s2218 s2217 0 0 nch W=0.5u L=0.18u
Mp2218 s2218 s2217 vdd vdd pch W=1u L=0.18u
Cl2218 s2218 0 10f
Mn2219 s2219 s2218 0 0 nch W=0.5u L=0.18u
Mp2219 s2219 s2218 vdd vdd pch W=1u L=0.18u
Cl2219 s2219 0 10f
Mn2220 s2220 s2219 0 0 nch W=0.5u L=0.18u
Mp2220 s2220 s2219 vdd vdd pch W=1u L=0.18u
Cl2220 s2220 0 10f
Mn2221 s2221 s2220 0 0 nch W=0.5u L=0.18u
Mp2221 s2221 s2220 vdd vdd pch W=1u L=0.18u
Cl2221 s2221 0 10f
Mn2222 s2222 s2221 0 0 nch W=0.5u L=0.18u
Mp2222 s2222 s2221 vdd vdd pch W=1u L=0.18u
Cl2222 s2222 0 10f
Mn2223 s2223 s2222 0 0 nch W=0.5u L=0.18u
Mp2223 s2223 s2222 vdd vdd pch W=1u L=0.18u
Cl2223 s2223 0 10f
Mn2224 s2224 s2223 0 0 nch W=0.5u L=0.18u
Mp2224 s2224 s2223 vdd vdd pch W=1u L=0.18u
Cl2224 s2224 0 10f
Mn2225 s2225 s2224 0 0 nch W=0.5u L=0.18u
Mp2225 s2225 s2224 vdd vdd pch W=1u L=0.18u
Cl2225 s2225 0 10f
Mn2226 s2226 s2225 0 0 nch W=0.5u L=0.18u
Mp2226 s2226 s2225 vdd vdd pch W=1u L=0.18u
Cl2226 s2226 0 10f
Mn2227 s2227 s2226 0 0 nch W=0.5u L=0.18u
Mp2227 s2227 s2226 vdd vdd pch W=1u L=0.18u
Cl2227 s2227 0 10f
Mn2228 s2228 s2227 0 0 nch W=0.5u L=0.18u
Mp2228 s2228 s2227 vdd vdd pch W=1u L=0.18u
Cl2228 s2228 0 10f
Mn2229 s2229 s2228 0 0 nch W=0.5u L=0.18u
Mp2229 s2229 s2228 vdd vdd pch W=1u L=0.18u
Cl2229 s2229 0 10f
Mn2230 s2230 s2229 0 0 nch W=0.5u L=0.18u
Mp2230 s2230 s2229 vdd vdd pch W=1u L=0.18u
Cl2230 s2230 0 10f
Mn2231 s2231 s2230 0 0 nch W=0.5u L=0.18u
Mp2231 s2231 s2230 vdd vdd pch W=1u L=0.18u
Cl2231 s2231 0 10f
Mn2232 s2232 s2231 0 0 nch W=0.5u L=0.18u
Mp2232 s2232 s2231 vdd vdd pch W=1u L=0.18u
Cl2232 s2232 0 10f
Mn2233 s2233 s2232 0 0 nch W=0.5u L=0.18u
Mp2233 s2233 s2232 vdd vdd pch W=1u L=0.18u
Cl2233 s2233 0 10f
Mn2234 s2234 s2233 0 0 nch W=0.5u L=0.18u
Mp2234 s2234 s2233 vdd vdd pch W=1u L=0.18u
Cl2234 s2234 0 10f
Mn2235 s2235 s2234 0 0 nch W=0.5u L=0.18u
Mp2235 s2235 s2234 vdd vdd pch W=1u L=0.18u
Cl2235 s2235 0 10f
Mn2236 s2236 s2235 0 0 nch W=0.5u L=0.18u
Mp2236 s2236 s2235 vdd vdd pch W=1u L=0.18u
Cl2236 s2236 0 10f
Mn2237 s2237 s2236 0 0 nch W=0.5u L=0.18u
Mp2237 s2237 s2236 vdd vdd pch W=1u L=0.18u
Cl2237 s2237 0 10f
Mn2238 s2238 s2237 0 0 nch W=0.5u L=0.18u
Mp2238 s2238 s2237 vdd vdd pch W=1u L=0.18u
Cl2238 s2238 0 10f
Mn2239 s2239 s2238 0 0 nch W=0.5u L=0.18u
Mp2239 s2239 s2238 vdd vdd pch W=1u L=0.18u
Cl2239 s2239 0 10f
Mn2240 s2240 s2239 0 0 nch W=0.5u L=0.18u
Mp2240 s2240 s2239 vdd vdd pch W=1u L=0.18u
Cl2240 s2240 0 10f
Mn2241 s2241 s2240 0 0 nch W=0.5u L=0.18u
Mp2241 s2241 s2240 vdd vdd pch W=1u L=0.18u
Cl2241 s2241 0 10f
Mn2242 s2242 s2241 0 0 nch W=0.5u L=0.18u
Mp2242 s2242 s2241 vdd vdd pch W=1u L=0.18u
Cl2242 s2242 0 10f
Mn2243 s2243 s2242 0 0 nch W=0.5u L=0.18u
Mp2243 s2243 s2242 vdd vdd pch W=1u L=0.18u
Cl2243 s2243 0 10f
Mn2244 s2244 s2243 0 0 nch W=0.5u L=0.18u
Mp2244 s2244 s2243 vdd vdd pch W=1u L=0.18u
Cl2244 s2244 0 10f
Mn2245 s2245 s2244 0 0 nch W=0.5u L=0.18u
Mp2245 s2245 s2244 vdd vdd pch W=1u L=0.18u
Cl2245 s2245 0 10f
Mn2246 s2246 s2245 0 0 nch W=0.5u L=0.18u
Mp2246 s2246 s2245 vdd vdd pch W=1u L=0.18u
Cl2246 s2246 0 10f
Mn2247 s2247 s2246 0 0 nch W=0.5u L=0.18u
Mp2247 s2247 s2246 vdd vdd pch W=1u L=0.18u
Cl2247 s2247 0 10f
Mn2248 s2248 s2247 0 0 nch W=0.5u L=0.18u
Mp2248 s2248 s2247 vdd vdd pch W=1u L=0.18u
Cl2248 s2248 0 10f
Mn2249 s2249 s2248 0 0 nch W=0.5u L=0.18u
Mp2249 s2249 s2248 vdd vdd pch W=1u L=0.18u
Cl2249 s2249 0 10f
Mn2250 s2250 s2249 0 0 nch W=0.5u L=0.18u
Mp2250 s2250 s2249 vdd vdd pch W=1u L=0.18u
Cl2250 s2250 0 10f
Mn2251 s2251 s2250 0 0 nch W=0.5u L=0.18u
Mp2251 s2251 s2250 vdd vdd pch W=1u L=0.18u
Cl2251 s2251 0 10f
Mn2252 s2252 s2251 0 0 nch W=0.5u L=0.18u
Mp2252 s2252 s2251 vdd vdd pch W=1u L=0.18u
Cl2252 s2252 0 10f
Mn2253 s2253 s2252 0 0 nch W=0.5u L=0.18u
Mp2253 s2253 s2252 vdd vdd pch W=1u L=0.18u
Cl2253 s2253 0 10f
Mn2254 s2254 s2253 0 0 nch W=0.5u L=0.18u
Mp2254 s2254 s2253 vdd vdd pch W=1u L=0.18u
Cl2254 s2254 0 10f
Mn2255 s2255 s2254 0 0 nch W=0.5u L=0.18u
Mp2255 s2255 s2254 vdd vdd pch W=1u L=0.18u
Cl2255 s2255 0 10f
Mn2256 s2256 s2255 0 0 nch W=0.5u L=0.18u
Mp2256 s2256 s2255 vdd vdd pch W=1u L=0.18u
Cl2256 s2256 0 10f
Mn2257 s2257 s2256 0 0 nch W=0.5u L=0.18u
Mp2257 s2257 s2256 vdd vdd pch W=1u L=0.18u
Cl2257 s2257 0 10f
Mn2258 s2258 s2257 0 0 nch W=0.5u L=0.18u
Mp2258 s2258 s2257 vdd vdd pch W=1u L=0.18u
Cl2258 s2258 0 10f
Mn2259 s2259 s2258 0 0 nch W=0.5u L=0.18u
Mp2259 s2259 s2258 vdd vdd pch W=1u L=0.18u
Cl2259 s2259 0 10f
Mn2260 s2260 s2259 0 0 nch W=0.5u L=0.18u
Mp2260 s2260 s2259 vdd vdd pch W=1u L=0.18u
Cl2260 s2260 0 10f
Mn2261 s2261 s2260 0 0 nch W=0.5u L=0.18u
Mp2261 s2261 s2260 vdd vdd pch W=1u L=0.18u
Cl2261 s2261 0 10f
Mn2262 s2262 s2261 0 0 nch W=0.5u L=0.18u
Mp2262 s2262 s2261 vdd vdd pch W=1u L=0.18u
Cl2262 s2262 0 10f
Mn2263 s2263 s2262 0 0 nch W=0.5u L=0.18u
Mp2263 s2263 s2262 vdd vdd pch W=1u L=0.18u
Cl2263 s2263 0 10f
Mn2264 s2264 s2263 0 0 nch W=0.5u L=0.18u
Mp2264 s2264 s2263 vdd vdd pch W=1u L=0.18u
Cl2264 s2264 0 10f
Mn2265 s2265 s2264 0 0 nch W=0.5u L=0.18u
Mp2265 s2265 s2264 vdd vdd pch W=1u L=0.18u
Cl2265 s2265 0 10f
Mn2266 s2266 s2265 0 0 nch W=0.5u L=0.18u
Mp2266 s2266 s2265 vdd vdd pch W=1u L=0.18u
Cl2266 s2266 0 10f
Mn2267 s2267 s2266 0 0 nch W=0.5u L=0.18u
Mp2267 s2267 s2266 vdd vdd pch W=1u L=0.18u
Cl2267 s2267 0 10f
Mn2268 s2268 s2267 0 0 nch W=0.5u L=0.18u
Mp2268 s2268 s2267 vdd vdd pch W=1u L=0.18u
Cl2268 s2268 0 10f
Mn2269 s2269 s2268 0 0 nch W=0.5u L=0.18u
Mp2269 s2269 s2268 vdd vdd pch W=1u L=0.18u
Cl2269 s2269 0 10f
Mn2270 s2270 s2269 0 0 nch W=0.5u L=0.18u
Mp2270 s2270 s2269 vdd vdd pch W=1u L=0.18u
Cl2270 s2270 0 10f
Mn2271 s2271 s2270 0 0 nch W=0.5u L=0.18u
Mp2271 s2271 s2270 vdd vdd pch W=1u L=0.18u
Cl2271 s2271 0 10f
Mn2272 s2272 s2271 0 0 nch W=0.5u L=0.18u
Mp2272 s2272 s2271 vdd vdd pch W=1u L=0.18u
Cl2272 s2272 0 10f
Mn2273 s2273 s2272 0 0 nch W=0.5u L=0.18u
Mp2273 s2273 s2272 vdd vdd pch W=1u L=0.18u
Cl2273 s2273 0 10f
Mn2274 s2274 s2273 0 0 nch W=0.5u L=0.18u
Mp2274 s2274 s2273 vdd vdd pch W=1u L=0.18u
Cl2274 s2274 0 10f
Mn2275 s2275 s2274 0 0 nch W=0.5u L=0.18u
Mp2275 s2275 s2274 vdd vdd pch W=1u L=0.18u
Cl2275 s2275 0 10f
Mn2276 s2276 s2275 0 0 nch W=0.5u L=0.18u
Mp2276 s2276 s2275 vdd vdd pch W=1u L=0.18u
Cl2276 s2276 0 10f
Mn2277 s2277 s2276 0 0 nch W=0.5u L=0.18u
Mp2277 s2277 s2276 vdd vdd pch W=1u L=0.18u
Cl2277 s2277 0 10f
Mn2278 s2278 s2277 0 0 nch W=0.5u L=0.18u
Mp2278 s2278 s2277 vdd vdd pch W=1u L=0.18u
Cl2278 s2278 0 10f
Mn2279 s2279 s2278 0 0 nch W=0.5u L=0.18u
Mp2279 s2279 s2278 vdd vdd pch W=1u L=0.18u
Cl2279 s2279 0 10f
Mn2280 s2280 s2279 0 0 nch W=0.5u L=0.18u
Mp2280 s2280 s2279 vdd vdd pch W=1u L=0.18u
Cl2280 s2280 0 10f
Mn2281 s2281 s2280 0 0 nch W=0.5u L=0.18u
Mp2281 s2281 s2280 vdd vdd pch W=1u L=0.18u
Cl2281 s2281 0 10f
Mn2282 s2282 s2281 0 0 nch W=0.5u L=0.18u
Mp2282 s2282 s2281 vdd vdd pch W=1u L=0.18u
Cl2282 s2282 0 10f
Mn2283 s2283 s2282 0 0 nch W=0.5u L=0.18u
Mp2283 s2283 s2282 vdd vdd pch W=1u L=0.18u
Cl2283 s2283 0 10f
Mn2284 s2284 s2283 0 0 nch W=0.5u L=0.18u
Mp2284 s2284 s2283 vdd vdd pch W=1u L=0.18u
Cl2284 s2284 0 10f
Mn2285 s2285 s2284 0 0 nch W=0.5u L=0.18u
Mp2285 s2285 s2284 vdd vdd pch W=1u L=0.18u
Cl2285 s2285 0 10f
Mn2286 s2286 s2285 0 0 nch W=0.5u L=0.18u
Mp2286 s2286 s2285 vdd vdd pch W=1u L=0.18u
Cl2286 s2286 0 10f
Mn2287 s2287 s2286 0 0 nch W=0.5u L=0.18u
Mp2287 s2287 s2286 vdd vdd pch W=1u L=0.18u
Cl2287 s2287 0 10f
Mn2288 s2288 s2287 0 0 nch W=0.5u L=0.18u
Mp2288 s2288 s2287 vdd vdd pch W=1u L=0.18u
Cl2288 s2288 0 10f
Mn2289 s2289 s2288 0 0 nch W=0.5u L=0.18u
Mp2289 s2289 s2288 vdd vdd pch W=1u L=0.18u
Cl2289 s2289 0 10f
Mn2290 s2290 s2289 0 0 nch W=0.5u L=0.18u
Mp2290 s2290 s2289 vdd vdd pch W=1u L=0.18u
Cl2290 s2290 0 10f
Mn2291 s2291 s2290 0 0 nch W=0.5u L=0.18u
Mp2291 s2291 s2290 vdd vdd pch W=1u L=0.18u
Cl2291 s2291 0 10f
Mn2292 s2292 s2291 0 0 nch W=0.5u L=0.18u
Mp2292 s2292 s2291 vdd vdd pch W=1u L=0.18u
Cl2292 s2292 0 10f
Mn2293 s2293 s2292 0 0 nch W=0.5u L=0.18u
Mp2293 s2293 s2292 vdd vdd pch W=1u L=0.18u
Cl2293 s2293 0 10f
Mn2294 s2294 s2293 0 0 nch W=0.5u L=0.18u
Mp2294 s2294 s2293 vdd vdd pch W=1u L=0.18u
Cl2294 s2294 0 10f
Mn2295 s2295 s2294 0 0 nch W=0.5u L=0.18u
Mp2295 s2295 s2294 vdd vdd pch W=1u L=0.18u
Cl2295 s2295 0 10f
Mn2296 s2296 s2295 0 0 nch W=0.5u L=0.18u
Mp2296 s2296 s2295 vdd vdd pch W=1u L=0.18u
Cl2296 s2296 0 10f
Mn2297 s2297 s2296 0 0 nch W=0.5u L=0.18u
Mp2297 s2297 s2296 vdd vdd pch W=1u L=0.18u
Cl2297 s2297 0 10f
Mn2298 s2298 s2297 0 0 nch W=0.5u L=0.18u
Mp2298 s2298 s2297 vdd vdd pch W=1u L=0.18u
Cl2298 s2298 0 10f
Mn2299 s2299 s2298 0 0 nch W=0.5u L=0.18u
Mp2299 s2299 s2298 vdd vdd pch W=1u L=0.18u
Cl2299 s2299 0 10f
Mn2300 s2300 s2299 0 0 nch W=0.5u L=0.18u
Mp2300 s2300 s2299 vdd vdd pch W=1u L=0.18u
Cl2300 s2300 0 10f
Mn2301 s2301 s2300 0 0 nch W=0.5u L=0.18u
Mp2301 s2301 s2300 vdd vdd pch W=1u L=0.18u
Cl2301 s2301 0 10f
Mn2302 s2302 s2301 0 0 nch W=0.5u L=0.18u
Mp2302 s2302 s2301 vdd vdd pch W=1u L=0.18u
Cl2302 s2302 0 10f
Mn2303 s2303 s2302 0 0 nch W=0.5u L=0.18u
Mp2303 s2303 s2302 vdd vdd pch W=1u L=0.18u
Cl2303 s2303 0 10f
Mn2304 s2304 s2303 0 0 nch W=0.5u L=0.18u
Mp2304 s2304 s2303 vdd vdd pch W=1u L=0.18u
Cl2304 s2304 0 10f
Mn2305 s2305 s2304 0 0 nch W=0.5u L=0.18u
Mp2305 s2305 s2304 vdd vdd pch W=1u L=0.18u
Cl2305 s2305 0 10f
Mn2306 s2306 s2305 0 0 nch W=0.5u L=0.18u
Mp2306 s2306 s2305 vdd vdd pch W=1u L=0.18u
Cl2306 s2306 0 10f
Mn2307 s2307 s2306 0 0 nch W=0.5u L=0.18u
Mp2307 s2307 s2306 vdd vdd pch W=1u L=0.18u
Cl2307 s2307 0 10f
Mn2308 s2308 s2307 0 0 nch W=0.5u L=0.18u
Mp2308 s2308 s2307 vdd vdd pch W=1u L=0.18u
Cl2308 s2308 0 10f
Mn2309 s2309 s2308 0 0 nch W=0.5u L=0.18u
Mp2309 s2309 s2308 vdd vdd pch W=1u L=0.18u
Cl2309 s2309 0 10f
Mn2310 s2310 s2309 0 0 nch W=0.5u L=0.18u
Mp2310 s2310 s2309 vdd vdd pch W=1u L=0.18u
Cl2310 s2310 0 10f
Mn2311 s2311 s2310 0 0 nch W=0.5u L=0.18u
Mp2311 s2311 s2310 vdd vdd pch W=1u L=0.18u
Cl2311 s2311 0 10f
Mn2312 s2312 s2311 0 0 nch W=0.5u L=0.18u
Mp2312 s2312 s2311 vdd vdd pch W=1u L=0.18u
Cl2312 s2312 0 10f
Mn2313 s2313 s2312 0 0 nch W=0.5u L=0.18u
Mp2313 s2313 s2312 vdd vdd pch W=1u L=0.18u
Cl2313 s2313 0 10f
Mn2314 s2314 s2313 0 0 nch W=0.5u L=0.18u
Mp2314 s2314 s2313 vdd vdd pch W=1u L=0.18u
Cl2314 s2314 0 10f
Mn2315 s2315 s2314 0 0 nch W=0.5u L=0.18u
Mp2315 s2315 s2314 vdd vdd pch W=1u L=0.18u
Cl2315 s2315 0 10f
Mn2316 s2316 s2315 0 0 nch W=0.5u L=0.18u
Mp2316 s2316 s2315 vdd vdd pch W=1u L=0.18u
Cl2316 s2316 0 10f
Mn2317 s2317 s2316 0 0 nch W=0.5u L=0.18u
Mp2317 s2317 s2316 vdd vdd pch W=1u L=0.18u
Cl2317 s2317 0 10f
Mn2318 s2318 s2317 0 0 nch W=0.5u L=0.18u
Mp2318 s2318 s2317 vdd vdd pch W=1u L=0.18u
Cl2318 s2318 0 10f
Mn2319 s2319 s2318 0 0 nch W=0.5u L=0.18u
Mp2319 s2319 s2318 vdd vdd pch W=1u L=0.18u
Cl2319 s2319 0 10f
Mn2320 s2320 s2319 0 0 nch W=0.5u L=0.18u
Mp2320 s2320 s2319 vdd vdd pch W=1u L=0.18u
Cl2320 s2320 0 10f
Mn2321 s2321 s2320 0 0 nch W=0.5u L=0.18u
Mp2321 s2321 s2320 vdd vdd pch W=1u L=0.18u
Cl2321 s2321 0 10f
Mn2322 s2322 s2321 0 0 nch W=0.5u L=0.18u
Mp2322 s2322 s2321 vdd vdd pch W=1u L=0.18u
Cl2322 s2322 0 10f
Mn2323 s2323 s2322 0 0 nch W=0.5u L=0.18u
Mp2323 s2323 s2322 vdd vdd pch W=1u L=0.18u
Cl2323 s2323 0 10f
Mn2324 s2324 s2323 0 0 nch W=0.5u L=0.18u
Mp2324 s2324 s2323 vdd vdd pch W=1u L=0.18u
Cl2324 s2324 0 10f
Mn2325 s2325 s2324 0 0 nch W=0.5u L=0.18u
Mp2325 s2325 s2324 vdd vdd pch W=1u L=0.18u
Cl2325 s2325 0 10f
Mn2326 s2326 s2325 0 0 nch W=0.5u L=0.18u
Mp2326 s2326 s2325 vdd vdd pch W=1u L=0.18u
Cl2326 s2326 0 10f
Mn2327 s2327 s2326 0 0 nch W=0.5u L=0.18u
Mp2327 s2327 s2326 vdd vdd pch W=1u L=0.18u
Cl2327 s2327 0 10f
Mn2328 s2328 s2327 0 0 nch W=0.5u L=0.18u
Mp2328 s2328 s2327 vdd vdd pch W=1u L=0.18u
Cl2328 s2328 0 10f
Mn2329 s2329 s2328 0 0 nch W=0.5u L=0.18u
Mp2329 s2329 s2328 vdd vdd pch W=1u L=0.18u
Cl2329 s2329 0 10f
Mn2330 s2330 s2329 0 0 nch W=0.5u L=0.18u
Mp2330 s2330 s2329 vdd vdd pch W=1u L=0.18u
Cl2330 s2330 0 10f
Mn2331 s2331 s2330 0 0 nch W=0.5u L=0.18u
Mp2331 s2331 s2330 vdd vdd pch W=1u L=0.18u
Cl2331 s2331 0 10f
Mn2332 s2332 s2331 0 0 nch W=0.5u L=0.18u
Mp2332 s2332 s2331 vdd vdd pch W=1u L=0.18u
Cl2332 s2332 0 10f
Mn2333 s2333 s2332 0 0 nch W=0.5u L=0.18u
Mp2333 s2333 s2332 vdd vdd pch W=1u L=0.18u
Cl2333 s2333 0 10f
Mn2334 s2334 s2333 0 0 nch W=0.5u L=0.18u
Mp2334 s2334 s2333 vdd vdd pch W=1u L=0.18u
Cl2334 s2334 0 10f
Mn2335 s2335 s2334 0 0 nch W=0.5u L=0.18u
Mp2335 s2335 s2334 vdd vdd pch W=1u L=0.18u
Cl2335 s2335 0 10f
Mn2336 s2336 s2335 0 0 nch W=0.5u L=0.18u
Mp2336 s2336 s2335 vdd vdd pch W=1u L=0.18u
Cl2336 s2336 0 10f
Mn2337 s2337 s2336 0 0 nch W=0.5u L=0.18u
Mp2337 s2337 s2336 vdd vdd pch W=1u L=0.18u
Cl2337 s2337 0 10f
Mn2338 s2338 s2337 0 0 nch W=0.5u L=0.18u
Mp2338 s2338 s2337 vdd vdd pch W=1u L=0.18u
Cl2338 s2338 0 10f
Mn2339 s2339 s2338 0 0 nch W=0.5u L=0.18u
Mp2339 s2339 s2338 vdd vdd pch W=1u L=0.18u
Cl2339 s2339 0 10f
Mn2340 s2340 s2339 0 0 nch W=0.5u L=0.18u
Mp2340 s2340 s2339 vdd vdd pch W=1u L=0.18u
Cl2340 s2340 0 10f
Mn2341 s2341 s2340 0 0 nch W=0.5u L=0.18u
Mp2341 s2341 s2340 vdd vdd pch W=1u L=0.18u
Cl2341 s2341 0 10f
Mn2342 s2342 s2341 0 0 nch W=0.5u L=0.18u
Mp2342 s2342 s2341 vdd vdd pch W=1u L=0.18u
Cl2342 s2342 0 10f
Mn2343 s2343 s2342 0 0 nch W=0.5u L=0.18u
Mp2343 s2343 s2342 vdd vdd pch W=1u L=0.18u
Cl2343 s2343 0 10f
Mn2344 s2344 s2343 0 0 nch W=0.5u L=0.18u
Mp2344 s2344 s2343 vdd vdd pch W=1u L=0.18u
Cl2344 s2344 0 10f
Mn2345 s2345 s2344 0 0 nch W=0.5u L=0.18u
Mp2345 s2345 s2344 vdd vdd pch W=1u L=0.18u
Cl2345 s2345 0 10f
Mn2346 s2346 s2345 0 0 nch W=0.5u L=0.18u
Mp2346 s2346 s2345 vdd vdd pch W=1u L=0.18u
Cl2346 s2346 0 10f
Mn2347 s2347 s2346 0 0 nch W=0.5u L=0.18u
Mp2347 s2347 s2346 vdd vdd pch W=1u L=0.18u
Cl2347 s2347 0 10f
Mn2348 s2348 s2347 0 0 nch W=0.5u L=0.18u
Mp2348 s2348 s2347 vdd vdd pch W=1u L=0.18u
Cl2348 s2348 0 10f
Mn2349 s2349 s2348 0 0 nch W=0.5u L=0.18u
Mp2349 s2349 s2348 vdd vdd pch W=1u L=0.18u
Cl2349 s2349 0 10f
Mn2350 s2350 s2349 0 0 nch W=0.5u L=0.18u
Mp2350 s2350 s2349 vdd vdd pch W=1u L=0.18u
Cl2350 s2350 0 10f
Mn2351 s2351 s2350 0 0 nch W=0.5u L=0.18u
Mp2351 s2351 s2350 vdd vdd pch W=1u L=0.18u
Cl2351 s2351 0 10f
Mn2352 s2352 s2351 0 0 nch W=0.5u L=0.18u
Mp2352 s2352 s2351 vdd vdd pch W=1u L=0.18u
Cl2352 s2352 0 10f
Mn2353 s2353 s2352 0 0 nch W=0.5u L=0.18u
Mp2353 s2353 s2352 vdd vdd pch W=1u L=0.18u
Cl2353 s2353 0 10f
Mn2354 s2354 s2353 0 0 nch W=0.5u L=0.18u
Mp2354 s2354 s2353 vdd vdd pch W=1u L=0.18u
Cl2354 s2354 0 10f
Mn2355 s2355 s2354 0 0 nch W=0.5u L=0.18u
Mp2355 s2355 s2354 vdd vdd pch W=1u L=0.18u
Cl2355 s2355 0 10f
Mn2356 s2356 s2355 0 0 nch W=0.5u L=0.18u
Mp2356 s2356 s2355 vdd vdd pch W=1u L=0.18u
Cl2356 s2356 0 10f
Mn2357 s2357 s2356 0 0 nch W=0.5u L=0.18u
Mp2357 s2357 s2356 vdd vdd pch W=1u L=0.18u
Cl2357 s2357 0 10f
Mn2358 s2358 s2357 0 0 nch W=0.5u L=0.18u
Mp2358 s2358 s2357 vdd vdd pch W=1u L=0.18u
Cl2358 s2358 0 10f
Mn2359 s2359 s2358 0 0 nch W=0.5u L=0.18u
Mp2359 s2359 s2358 vdd vdd pch W=1u L=0.18u
Cl2359 s2359 0 10f
Mn2360 s2360 s2359 0 0 nch W=0.5u L=0.18u
Mp2360 s2360 s2359 vdd vdd pch W=1u L=0.18u
Cl2360 s2360 0 10f
Mn2361 s2361 s2360 0 0 nch W=0.5u L=0.18u
Mp2361 s2361 s2360 vdd vdd pch W=1u L=0.18u
Cl2361 s2361 0 10f
Mn2362 s2362 s2361 0 0 nch W=0.5u L=0.18u
Mp2362 s2362 s2361 vdd vdd pch W=1u L=0.18u
Cl2362 s2362 0 10f
Mn2363 s2363 s2362 0 0 nch W=0.5u L=0.18u
Mp2363 s2363 s2362 vdd vdd pch W=1u L=0.18u
Cl2363 s2363 0 10f
Mn2364 s2364 s2363 0 0 nch W=0.5u L=0.18u
Mp2364 s2364 s2363 vdd vdd pch W=1u L=0.18u
Cl2364 s2364 0 10f
Mn2365 s2365 s2364 0 0 nch W=0.5u L=0.18u
Mp2365 s2365 s2364 vdd vdd pch W=1u L=0.18u
Cl2365 s2365 0 10f
Mn2366 s2366 s2365 0 0 nch W=0.5u L=0.18u
Mp2366 s2366 s2365 vdd vdd pch W=1u L=0.18u
Cl2366 s2366 0 10f
Mn2367 s2367 s2366 0 0 nch W=0.5u L=0.18u
Mp2367 s2367 s2366 vdd vdd pch W=1u L=0.18u
Cl2367 s2367 0 10f
Mn2368 s2368 s2367 0 0 nch W=0.5u L=0.18u
Mp2368 s2368 s2367 vdd vdd pch W=1u L=0.18u
Cl2368 s2368 0 10f
Mn2369 s2369 s2368 0 0 nch W=0.5u L=0.18u
Mp2369 s2369 s2368 vdd vdd pch W=1u L=0.18u
Cl2369 s2369 0 10f
Mn2370 s2370 s2369 0 0 nch W=0.5u L=0.18u
Mp2370 s2370 s2369 vdd vdd pch W=1u L=0.18u
Cl2370 s2370 0 10f
Mn2371 s2371 s2370 0 0 nch W=0.5u L=0.18u
Mp2371 s2371 s2370 vdd vdd pch W=1u L=0.18u
Cl2371 s2371 0 10f
Mn2372 s2372 s2371 0 0 nch W=0.5u L=0.18u
Mp2372 s2372 s2371 vdd vdd pch W=1u L=0.18u
Cl2372 s2372 0 10f
Mn2373 s2373 s2372 0 0 nch W=0.5u L=0.18u
Mp2373 s2373 s2372 vdd vdd pch W=1u L=0.18u
Cl2373 s2373 0 10f
Mn2374 s2374 s2373 0 0 nch W=0.5u L=0.18u
Mp2374 s2374 s2373 vdd vdd pch W=1u L=0.18u
Cl2374 s2374 0 10f
Mn2375 s2375 s2374 0 0 nch W=0.5u L=0.18u
Mp2375 s2375 s2374 vdd vdd pch W=1u L=0.18u
Cl2375 s2375 0 10f
Mn2376 s2376 s2375 0 0 nch W=0.5u L=0.18u
Mp2376 s2376 s2375 vdd vdd pch W=1u L=0.18u
Cl2376 s2376 0 10f
Mn2377 s2377 s2376 0 0 nch W=0.5u L=0.18u
Mp2377 s2377 s2376 vdd vdd pch W=1u L=0.18u
Cl2377 s2377 0 10f
Mn2378 s2378 s2377 0 0 nch W=0.5u L=0.18u
Mp2378 s2378 s2377 vdd vdd pch W=1u L=0.18u
Cl2378 s2378 0 10f
Mn2379 s2379 s2378 0 0 nch W=0.5u L=0.18u
Mp2379 s2379 s2378 vdd vdd pch W=1u L=0.18u
Cl2379 s2379 0 10f
Mn2380 s2380 s2379 0 0 nch W=0.5u L=0.18u
Mp2380 s2380 s2379 vdd vdd pch W=1u L=0.18u
Cl2380 s2380 0 10f
Mn2381 s2381 s2380 0 0 nch W=0.5u L=0.18u
Mp2381 s2381 s2380 vdd vdd pch W=1u L=0.18u
Cl2381 s2381 0 10f
Mn2382 s2382 s2381 0 0 nch W=0.5u L=0.18u
Mp2382 s2382 s2381 vdd vdd pch W=1u L=0.18u
Cl2382 s2382 0 10f
Mn2383 s2383 s2382 0 0 nch W=0.5u L=0.18u
Mp2383 s2383 s2382 vdd vdd pch W=1u L=0.18u
Cl2383 s2383 0 10f
Mn2384 s2384 s2383 0 0 nch W=0.5u L=0.18u
Mp2384 s2384 s2383 vdd vdd pch W=1u L=0.18u
Cl2384 s2384 0 10f
Mn2385 s2385 s2384 0 0 nch W=0.5u L=0.18u
Mp2385 s2385 s2384 vdd vdd pch W=1u L=0.18u
Cl2385 s2385 0 10f
Mn2386 s2386 s2385 0 0 nch W=0.5u L=0.18u
Mp2386 s2386 s2385 vdd vdd pch W=1u L=0.18u
Cl2386 s2386 0 10f
Mn2387 s2387 s2386 0 0 nch W=0.5u L=0.18u
Mp2387 s2387 s2386 vdd vdd pch W=1u L=0.18u
Cl2387 s2387 0 10f
Mn2388 s2388 s2387 0 0 nch W=0.5u L=0.18u
Mp2388 s2388 s2387 vdd vdd pch W=1u L=0.18u
Cl2388 s2388 0 10f
Mn2389 s2389 s2388 0 0 nch W=0.5u L=0.18u
Mp2389 s2389 s2388 vdd vdd pch W=1u L=0.18u
Cl2389 s2389 0 10f
Mn2390 s2390 s2389 0 0 nch W=0.5u L=0.18u
Mp2390 s2390 s2389 vdd vdd pch W=1u L=0.18u
Cl2390 s2390 0 10f
Mn2391 s2391 s2390 0 0 nch W=0.5u L=0.18u
Mp2391 s2391 s2390 vdd vdd pch W=1u L=0.18u
Cl2391 s2391 0 10f
Mn2392 s2392 s2391 0 0 nch W=0.5u L=0.18u
Mp2392 s2392 s2391 vdd vdd pch W=1u L=0.18u
Cl2392 s2392 0 10f
Mn2393 s2393 s2392 0 0 nch W=0.5u L=0.18u
Mp2393 s2393 s2392 vdd vdd pch W=1u L=0.18u
Cl2393 s2393 0 10f
Mn2394 s2394 s2393 0 0 nch W=0.5u L=0.18u
Mp2394 s2394 s2393 vdd vdd pch W=1u L=0.18u
Cl2394 s2394 0 10f
Mn2395 s2395 s2394 0 0 nch W=0.5u L=0.18u
Mp2395 s2395 s2394 vdd vdd pch W=1u L=0.18u
Cl2395 s2395 0 10f
Mn2396 s2396 s2395 0 0 nch W=0.5u L=0.18u
Mp2396 s2396 s2395 vdd vdd pch W=1u L=0.18u
Cl2396 s2396 0 10f
Mn2397 s2397 s2396 0 0 nch W=0.5u L=0.18u
Mp2397 s2397 s2396 vdd vdd pch W=1u L=0.18u
Cl2397 s2397 0 10f
Mn2398 s2398 s2397 0 0 nch W=0.5u L=0.18u
Mp2398 s2398 s2397 vdd vdd pch W=1u L=0.18u
Cl2398 s2398 0 10f
Mn2399 s2399 s2398 0 0 nch W=0.5u L=0.18u
Mp2399 s2399 s2398 vdd vdd pch W=1u L=0.18u
Cl2399 s2399 0 10f
Mn2400 s2400 s2399 0 0 nch W=0.5u L=0.18u
Mp2400 s2400 s2399 vdd vdd pch W=1u L=0.18u
Cl2400 s2400 0 10f
Mn2401 s2401 s2400 0 0 nch W=0.5u L=0.18u
Mp2401 s2401 s2400 vdd vdd pch W=1u L=0.18u
Cl2401 s2401 0 10f
Mn2402 s2402 s2401 0 0 nch W=0.5u L=0.18u
Mp2402 s2402 s2401 vdd vdd pch W=1u L=0.18u
Cl2402 s2402 0 10f
Mn2403 s2403 s2402 0 0 nch W=0.5u L=0.18u
Mp2403 s2403 s2402 vdd vdd pch W=1u L=0.18u
Cl2403 s2403 0 10f
Mn2404 s2404 s2403 0 0 nch W=0.5u L=0.18u
Mp2404 s2404 s2403 vdd vdd pch W=1u L=0.18u
Cl2404 s2404 0 10f
Mn2405 s2405 s2404 0 0 nch W=0.5u L=0.18u
Mp2405 s2405 s2404 vdd vdd pch W=1u L=0.18u
Cl2405 s2405 0 10f
Mn2406 s2406 s2405 0 0 nch W=0.5u L=0.18u
Mp2406 s2406 s2405 vdd vdd pch W=1u L=0.18u
Cl2406 s2406 0 10f
Mn2407 s2407 s2406 0 0 nch W=0.5u L=0.18u
Mp2407 s2407 s2406 vdd vdd pch W=1u L=0.18u
Cl2407 s2407 0 10f
Mn2408 s2408 s2407 0 0 nch W=0.5u L=0.18u
Mp2408 s2408 s2407 vdd vdd pch W=1u L=0.18u
Cl2408 s2408 0 10f
Mn2409 s2409 s2408 0 0 nch W=0.5u L=0.18u
Mp2409 s2409 s2408 vdd vdd pch W=1u L=0.18u
Cl2409 s2409 0 10f
Mn2410 s2410 s2409 0 0 nch W=0.5u L=0.18u
Mp2410 s2410 s2409 vdd vdd pch W=1u L=0.18u
Cl2410 s2410 0 10f
Mn2411 s2411 s2410 0 0 nch W=0.5u L=0.18u
Mp2411 s2411 s2410 vdd vdd pch W=1u L=0.18u
Cl2411 s2411 0 10f
Mn2412 s2412 s2411 0 0 nch W=0.5u L=0.18u
Mp2412 s2412 s2411 vdd vdd pch W=1u L=0.18u
Cl2412 s2412 0 10f
Mn2413 s2413 s2412 0 0 nch W=0.5u L=0.18u
Mp2413 s2413 s2412 vdd vdd pch W=1u L=0.18u
Cl2413 s2413 0 10f
Mn2414 s2414 s2413 0 0 nch W=0.5u L=0.18u
Mp2414 s2414 s2413 vdd vdd pch W=1u L=0.18u
Cl2414 s2414 0 10f
Mn2415 s2415 s2414 0 0 nch W=0.5u L=0.18u
Mp2415 s2415 s2414 vdd vdd pch W=1u L=0.18u
Cl2415 s2415 0 10f
Mn2416 s2416 s2415 0 0 nch W=0.5u L=0.18u
Mp2416 s2416 s2415 vdd vdd pch W=1u L=0.18u
Cl2416 s2416 0 10f
Mn2417 s2417 s2416 0 0 nch W=0.5u L=0.18u
Mp2417 s2417 s2416 vdd vdd pch W=1u L=0.18u
Cl2417 s2417 0 10f
Mn2418 s2418 s2417 0 0 nch W=0.5u L=0.18u
Mp2418 s2418 s2417 vdd vdd pch W=1u L=0.18u
Cl2418 s2418 0 10f
Mn2419 s2419 s2418 0 0 nch W=0.5u L=0.18u
Mp2419 s2419 s2418 vdd vdd pch W=1u L=0.18u
Cl2419 s2419 0 10f
Mn2420 s2420 s2419 0 0 nch W=0.5u L=0.18u
Mp2420 s2420 s2419 vdd vdd pch W=1u L=0.18u
Cl2420 s2420 0 10f
Mn2421 s2421 s2420 0 0 nch W=0.5u L=0.18u
Mp2421 s2421 s2420 vdd vdd pch W=1u L=0.18u
Cl2421 s2421 0 10f
Mn2422 s2422 s2421 0 0 nch W=0.5u L=0.18u
Mp2422 s2422 s2421 vdd vdd pch W=1u L=0.18u
Cl2422 s2422 0 10f
Mn2423 s2423 s2422 0 0 nch W=0.5u L=0.18u
Mp2423 s2423 s2422 vdd vdd pch W=1u L=0.18u
Cl2423 s2423 0 10f
Mn2424 s2424 s2423 0 0 nch W=0.5u L=0.18u
Mp2424 s2424 s2423 vdd vdd pch W=1u L=0.18u
Cl2424 s2424 0 10f
Mn2425 s2425 s2424 0 0 nch W=0.5u L=0.18u
Mp2425 s2425 s2424 vdd vdd pch W=1u L=0.18u
Cl2425 s2425 0 10f
Mn2426 s2426 s2425 0 0 nch W=0.5u L=0.18u
Mp2426 s2426 s2425 vdd vdd pch W=1u L=0.18u
Cl2426 s2426 0 10f
Mn2427 s2427 s2426 0 0 nch W=0.5u L=0.18u
Mp2427 s2427 s2426 vdd vdd pch W=1u L=0.18u
Cl2427 s2427 0 10f
Mn2428 s2428 s2427 0 0 nch W=0.5u L=0.18u
Mp2428 s2428 s2427 vdd vdd pch W=1u L=0.18u
Cl2428 s2428 0 10f
Mn2429 s2429 s2428 0 0 nch W=0.5u L=0.18u
Mp2429 s2429 s2428 vdd vdd pch W=1u L=0.18u
Cl2429 s2429 0 10f
Mn2430 s2430 s2429 0 0 nch W=0.5u L=0.18u
Mp2430 s2430 s2429 vdd vdd pch W=1u L=0.18u
Cl2430 s2430 0 10f
Mn2431 s2431 s2430 0 0 nch W=0.5u L=0.18u
Mp2431 s2431 s2430 vdd vdd pch W=1u L=0.18u
Cl2431 s2431 0 10f
Mn2432 s2432 s2431 0 0 nch W=0.5u L=0.18u
Mp2432 s2432 s2431 vdd vdd pch W=1u L=0.18u
Cl2432 s2432 0 10f
Mn2433 s2433 s2432 0 0 nch W=0.5u L=0.18u
Mp2433 s2433 s2432 vdd vdd pch W=1u L=0.18u
Cl2433 s2433 0 10f
Mn2434 s2434 s2433 0 0 nch W=0.5u L=0.18u
Mp2434 s2434 s2433 vdd vdd pch W=1u L=0.18u
Cl2434 s2434 0 10f
Mn2435 s2435 s2434 0 0 nch W=0.5u L=0.18u
Mp2435 s2435 s2434 vdd vdd pch W=1u L=0.18u
Cl2435 s2435 0 10f
Mn2436 s2436 s2435 0 0 nch W=0.5u L=0.18u
Mp2436 s2436 s2435 vdd vdd pch W=1u L=0.18u
Cl2436 s2436 0 10f
Mn2437 s2437 s2436 0 0 nch W=0.5u L=0.18u
Mp2437 s2437 s2436 vdd vdd pch W=1u L=0.18u
Cl2437 s2437 0 10f
Mn2438 s2438 s2437 0 0 nch W=0.5u L=0.18u
Mp2438 s2438 s2437 vdd vdd pch W=1u L=0.18u
Cl2438 s2438 0 10f
Mn2439 s2439 s2438 0 0 nch W=0.5u L=0.18u
Mp2439 s2439 s2438 vdd vdd pch W=1u L=0.18u
Cl2439 s2439 0 10f
Mn2440 s2440 s2439 0 0 nch W=0.5u L=0.18u
Mp2440 s2440 s2439 vdd vdd pch W=1u L=0.18u
Cl2440 s2440 0 10f
Mn2441 s2441 s2440 0 0 nch W=0.5u L=0.18u
Mp2441 s2441 s2440 vdd vdd pch W=1u L=0.18u
Cl2441 s2441 0 10f
Mn2442 s2442 s2441 0 0 nch W=0.5u L=0.18u
Mp2442 s2442 s2441 vdd vdd pch W=1u L=0.18u
Cl2442 s2442 0 10f
Mn2443 s2443 s2442 0 0 nch W=0.5u L=0.18u
Mp2443 s2443 s2442 vdd vdd pch W=1u L=0.18u
Cl2443 s2443 0 10f
Mn2444 s2444 s2443 0 0 nch W=0.5u L=0.18u
Mp2444 s2444 s2443 vdd vdd pch W=1u L=0.18u
Cl2444 s2444 0 10f
Mn2445 s2445 s2444 0 0 nch W=0.5u L=0.18u
Mp2445 s2445 s2444 vdd vdd pch W=1u L=0.18u
Cl2445 s2445 0 10f
Mn2446 s2446 s2445 0 0 nch W=0.5u L=0.18u
Mp2446 s2446 s2445 vdd vdd pch W=1u L=0.18u
Cl2446 s2446 0 10f
Mn2447 s2447 s2446 0 0 nch W=0.5u L=0.18u
Mp2447 s2447 s2446 vdd vdd pch W=1u L=0.18u
Cl2447 s2447 0 10f
Mn2448 s2448 s2447 0 0 nch W=0.5u L=0.18u
Mp2448 s2448 s2447 vdd vdd pch W=1u L=0.18u
Cl2448 s2448 0 10f
Mn2449 s2449 s2448 0 0 nch W=0.5u L=0.18u
Mp2449 s2449 s2448 vdd vdd pch W=1u L=0.18u
Cl2449 s2449 0 10f
Mn2450 s2450 s2449 0 0 nch W=0.5u L=0.18u
Mp2450 s2450 s2449 vdd vdd pch W=1u L=0.18u
Cl2450 s2450 0 10f
Mn2451 s2451 s2450 0 0 nch W=0.5u L=0.18u
Mp2451 s2451 s2450 vdd vdd pch W=1u L=0.18u
Cl2451 s2451 0 10f
Mn2452 s2452 s2451 0 0 nch W=0.5u L=0.18u
Mp2452 s2452 s2451 vdd vdd pch W=1u L=0.18u
Cl2452 s2452 0 10f
Mn2453 s2453 s2452 0 0 nch W=0.5u L=0.18u
Mp2453 s2453 s2452 vdd vdd pch W=1u L=0.18u
Cl2453 s2453 0 10f
Mn2454 s2454 s2453 0 0 nch W=0.5u L=0.18u
Mp2454 s2454 s2453 vdd vdd pch W=1u L=0.18u
Cl2454 s2454 0 10f
Mn2455 s2455 s2454 0 0 nch W=0.5u L=0.18u
Mp2455 s2455 s2454 vdd vdd pch W=1u L=0.18u
Cl2455 s2455 0 10f
Mn2456 s2456 s2455 0 0 nch W=0.5u L=0.18u
Mp2456 s2456 s2455 vdd vdd pch W=1u L=0.18u
Cl2456 s2456 0 10f
Mn2457 s2457 s2456 0 0 nch W=0.5u L=0.18u
Mp2457 s2457 s2456 vdd vdd pch W=1u L=0.18u
Cl2457 s2457 0 10f
Mn2458 s2458 s2457 0 0 nch W=0.5u L=0.18u
Mp2458 s2458 s2457 vdd vdd pch W=1u L=0.18u
Cl2458 s2458 0 10f
Mn2459 s2459 s2458 0 0 nch W=0.5u L=0.18u
Mp2459 s2459 s2458 vdd vdd pch W=1u L=0.18u
Cl2459 s2459 0 10f
Mn2460 s2460 s2459 0 0 nch W=0.5u L=0.18u
Mp2460 s2460 s2459 vdd vdd pch W=1u L=0.18u
Cl2460 s2460 0 10f
Mn2461 s2461 s2460 0 0 nch W=0.5u L=0.18u
Mp2461 s2461 s2460 vdd vdd pch W=1u L=0.18u
Cl2461 s2461 0 10f
Mn2462 s2462 s2461 0 0 nch W=0.5u L=0.18u
Mp2462 s2462 s2461 vdd vdd pch W=1u L=0.18u
Cl2462 s2462 0 10f
Mn2463 s2463 s2462 0 0 nch W=0.5u L=0.18u
Mp2463 s2463 s2462 vdd vdd pch W=1u L=0.18u
Cl2463 s2463 0 10f
Mn2464 s2464 s2463 0 0 nch W=0.5u L=0.18u
Mp2464 s2464 s2463 vdd vdd pch W=1u L=0.18u
Cl2464 s2464 0 10f
Mn2465 s2465 s2464 0 0 nch W=0.5u L=0.18u
Mp2465 s2465 s2464 vdd vdd pch W=1u L=0.18u
Cl2465 s2465 0 10f
Mn2466 s2466 s2465 0 0 nch W=0.5u L=0.18u
Mp2466 s2466 s2465 vdd vdd pch W=1u L=0.18u
Cl2466 s2466 0 10f
Mn2467 s2467 s2466 0 0 nch W=0.5u L=0.18u
Mp2467 s2467 s2466 vdd vdd pch W=1u L=0.18u
Cl2467 s2467 0 10f
Mn2468 s2468 s2467 0 0 nch W=0.5u L=0.18u
Mp2468 s2468 s2467 vdd vdd pch W=1u L=0.18u
Cl2468 s2468 0 10f
Mn2469 s2469 s2468 0 0 nch W=0.5u L=0.18u
Mp2469 s2469 s2468 vdd vdd pch W=1u L=0.18u
Cl2469 s2469 0 10f
Mn2470 s2470 s2469 0 0 nch W=0.5u L=0.18u
Mp2470 s2470 s2469 vdd vdd pch W=1u L=0.18u
Cl2470 s2470 0 10f
Mn2471 s2471 s2470 0 0 nch W=0.5u L=0.18u
Mp2471 s2471 s2470 vdd vdd pch W=1u L=0.18u
Cl2471 s2471 0 10f
Mn2472 s2472 s2471 0 0 nch W=0.5u L=0.18u
Mp2472 s2472 s2471 vdd vdd pch W=1u L=0.18u
Cl2472 s2472 0 10f
Mn2473 s2473 s2472 0 0 nch W=0.5u L=0.18u
Mp2473 s2473 s2472 vdd vdd pch W=1u L=0.18u
Cl2473 s2473 0 10f
Mn2474 s2474 s2473 0 0 nch W=0.5u L=0.18u
Mp2474 s2474 s2473 vdd vdd pch W=1u L=0.18u
Cl2474 s2474 0 10f
Mn2475 s2475 s2474 0 0 nch W=0.5u L=0.18u
Mp2475 s2475 s2474 vdd vdd pch W=1u L=0.18u
Cl2475 s2475 0 10f
Mn2476 s2476 s2475 0 0 nch W=0.5u L=0.18u
Mp2476 s2476 s2475 vdd vdd pch W=1u L=0.18u
Cl2476 s2476 0 10f
Mn2477 s2477 s2476 0 0 nch W=0.5u L=0.18u
Mp2477 s2477 s2476 vdd vdd pch W=1u L=0.18u
Cl2477 s2477 0 10f
Mn2478 s2478 s2477 0 0 nch W=0.5u L=0.18u
Mp2478 s2478 s2477 vdd vdd pch W=1u L=0.18u
Cl2478 s2478 0 10f
Mn2479 s2479 s2478 0 0 nch W=0.5u L=0.18u
Mp2479 s2479 s2478 vdd vdd pch W=1u L=0.18u
Cl2479 s2479 0 10f
Mn2480 s2480 s2479 0 0 nch W=0.5u L=0.18u
Mp2480 s2480 s2479 vdd vdd pch W=1u L=0.18u
Cl2480 s2480 0 10f
Mn2481 s2481 s2480 0 0 nch W=0.5u L=0.18u
Mp2481 s2481 s2480 vdd vdd pch W=1u L=0.18u
Cl2481 s2481 0 10f
Mn2482 s2482 s2481 0 0 nch W=0.5u L=0.18u
Mp2482 s2482 s2481 vdd vdd pch W=1u L=0.18u
Cl2482 s2482 0 10f
Mn2483 s2483 s2482 0 0 nch W=0.5u L=0.18u
Mp2483 s2483 s2482 vdd vdd pch W=1u L=0.18u
Cl2483 s2483 0 10f
Mn2484 s2484 s2483 0 0 nch W=0.5u L=0.18u
Mp2484 s2484 s2483 vdd vdd pch W=1u L=0.18u
Cl2484 s2484 0 10f
Mn2485 s2485 s2484 0 0 nch W=0.5u L=0.18u
Mp2485 s2485 s2484 vdd vdd pch W=1u L=0.18u
Cl2485 s2485 0 10f
Mn2486 s2486 s2485 0 0 nch W=0.5u L=0.18u
Mp2486 s2486 s2485 vdd vdd pch W=1u L=0.18u
Cl2486 s2486 0 10f
Mn2487 s2487 s2486 0 0 nch W=0.5u L=0.18u
Mp2487 s2487 s2486 vdd vdd pch W=1u L=0.18u
Cl2487 s2487 0 10f
Mn2488 s2488 s2487 0 0 nch W=0.5u L=0.18u
Mp2488 s2488 s2487 vdd vdd pch W=1u L=0.18u
Cl2488 s2488 0 10f
Mn2489 s2489 s2488 0 0 nch W=0.5u L=0.18u
Mp2489 s2489 s2488 vdd vdd pch W=1u L=0.18u
Cl2489 s2489 0 10f
Mn2490 s2490 s2489 0 0 nch W=0.5u L=0.18u
Mp2490 s2490 s2489 vdd vdd pch W=1u L=0.18u
Cl2490 s2490 0 10f
Mn2491 s2491 s2490 0 0 nch W=0.5u L=0.18u
Mp2491 s2491 s2490 vdd vdd pch W=1u L=0.18u
Cl2491 s2491 0 10f
Mn2492 s2492 s2491 0 0 nch W=0.5u L=0.18u
Mp2492 s2492 s2491 vdd vdd pch W=1u L=0.18u
Cl2492 s2492 0 10f
Mn2493 s2493 s2492 0 0 nch W=0.5u L=0.18u
Mp2493 s2493 s2492 vdd vdd pch W=1u L=0.18u
Cl2493 s2493 0 10f
Mn2494 s2494 s2493 0 0 nch W=0.5u L=0.18u
Mp2494 s2494 s2493 vdd vdd pch W=1u L=0.18u
Cl2494 s2494 0 10f
Mn2495 s2495 s2494 0 0 nch W=0.5u L=0.18u
Mp2495 s2495 s2494 vdd vdd pch W=1u L=0.18u
Cl2495 s2495 0 10f
Mn2496 s2496 s2495 0 0 nch W=0.5u L=0.18u
Mp2496 s2496 s2495 vdd vdd pch W=1u L=0.18u
Cl2496 s2496 0 10f
Mn2497 s2497 s2496 0 0 nch W=0.5u L=0.18u
Mp2497 s2497 s2496 vdd vdd pch W=1u L=0.18u
Cl2497 s2497 0 10f
Mn2498 s2498 s2497 0 0 nch W=0.5u L=0.18u
Mp2498 s2498 s2497 vdd vdd pch W=1u L=0.18u
Cl2498 s2498 0 10f
Mn2499 s2499 s2498 0 0 nch W=0.5u L=0.18u
Mp2499 s2499 s2498 vdd vdd pch W=1u L=0.18u
Cl2499 s2499 0 10f
Mn2500 s2500 s2499 0 0 nch W=0.5u L=0.18u
Mp2500 s2500 s2499 vdd vdd pch W=1u L=0.18u
Cl2500 s2500 0 10f
Mn2501 s2501 s2500 0 0 nch W=0.5u L=0.18u
Mp2501 s2501 s2500 vdd vdd pch W=1u L=0.18u
Cl2501 s2501 0 10f
Mn2502 s2502 s2501 0 0 nch W=0.5u L=0.18u
Mp2502 s2502 s2501 vdd vdd pch W=1u L=0.18u
Cl2502 s2502 0 10f
Mn2503 s2503 s2502 0 0 nch W=0.5u L=0.18u
Mp2503 s2503 s2502 vdd vdd pch W=1u L=0.18u
Cl2503 s2503 0 10f
Mn2504 s2504 s2503 0 0 nch W=0.5u L=0.18u
Mp2504 s2504 s2503 vdd vdd pch W=1u L=0.18u
Cl2504 s2504 0 10f
Mn2505 s2505 s2504 0 0 nch W=0.5u L=0.18u
Mp2505 s2505 s2504 vdd vdd pch W=1u L=0.18u
Cl2505 s2505 0 10f
Mn2506 s2506 s2505 0 0 nch W=0.5u L=0.18u
Mp2506 s2506 s2505 vdd vdd pch W=1u L=0.18u
Cl2506 s2506 0 10f
Mn2507 s2507 s2506 0 0 nch W=0.5u L=0.18u
Mp2507 s2507 s2506 vdd vdd pch W=1u L=0.18u
Cl2507 s2507 0 10f
Mn2508 s2508 s2507 0 0 nch W=0.5u L=0.18u
Mp2508 s2508 s2507 vdd vdd pch W=1u L=0.18u
Cl2508 s2508 0 10f
Mn2509 s2509 s2508 0 0 nch W=0.5u L=0.18u
Mp2509 s2509 s2508 vdd vdd pch W=1u L=0.18u
Cl2509 s2509 0 10f
Mn2510 s2510 s2509 0 0 nch W=0.5u L=0.18u
Mp2510 s2510 s2509 vdd vdd pch W=1u L=0.18u
Cl2510 s2510 0 10f
Mn2511 s2511 s2510 0 0 nch W=0.5u L=0.18u
Mp2511 s2511 s2510 vdd vdd pch W=1u L=0.18u
Cl2511 s2511 0 10f
Mn2512 s2512 s2511 0 0 nch W=0.5u L=0.18u
Mp2512 s2512 s2511 vdd vdd pch W=1u L=0.18u
Cl2512 s2512 0 10f
Mn2513 s2513 s2512 0 0 nch W=0.5u L=0.18u
Mp2513 s2513 s2512 vdd vdd pch W=1u L=0.18u
Cl2513 s2513 0 10f
Mn2514 s2514 s2513 0 0 nch W=0.5u L=0.18u
Mp2514 s2514 s2513 vdd vdd pch W=1u L=0.18u
Cl2514 s2514 0 10f
Mn2515 s2515 s2514 0 0 nch W=0.5u L=0.18u
Mp2515 s2515 s2514 vdd vdd pch W=1u L=0.18u
Cl2515 s2515 0 10f
Mn2516 s2516 s2515 0 0 nch W=0.5u L=0.18u
Mp2516 s2516 s2515 vdd vdd pch W=1u L=0.18u
Cl2516 s2516 0 10f
Mn2517 s2517 s2516 0 0 nch W=0.5u L=0.18u
Mp2517 s2517 s2516 vdd vdd pch W=1u L=0.18u
Cl2517 s2517 0 10f
Mn2518 s2518 s2517 0 0 nch W=0.5u L=0.18u
Mp2518 s2518 s2517 vdd vdd pch W=1u L=0.18u
Cl2518 s2518 0 10f
Mn2519 s2519 s2518 0 0 nch W=0.5u L=0.18u
Mp2519 s2519 s2518 vdd vdd pch W=1u L=0.18u
Cl2519 s2519 0 10f
Mn2520 s2520 s2519 0 0 nch W=0.5u L=0.18u
Mp2520 s2520 s2519 vdd vdd pch W=1u L=0.18u
Cl2520 s2520 0 10f
Mn2521 s2521 s2520 0 0 nch W=0.5u L=0.18u
Mp2521 s2521 s2520 vdd vdd pch W=1u L=0.18u
Cl2521 s2521 0 10f
Mn2522 s2522 s2521 0 0 nch W=0.5u L=0.18u
Mp2522 s2522 s2521 vdd vdd pch W=1u L=0.18u
Cl2522 s2522 0 10f
Mn2523 s2523 s2522 0 0 nch W=0.5u L=0.18u
Mp2523 s2523 s2522 vdd vdd pch W=1u L=0.18u
Cl2523 s2523 0 10f
Mn2524 s2524 s2523 0 0 nch W=0.5u L=0.18u
Mp2524 s2524 s2523 vdd vdd pch W=1u L=0.18u
Cl2524 s2524 0 10f
Mn2525 s2525 s2524 0 0 nch W=0.5u L=0.18u
Mp2525 s2525 s2524 vdd vdd pch W=1u L=0.18u
Cl2525 s2525 0 10f
Mn2526 s2526 s2525 0 0 nch W=0.5u L=0.18u
Mp2526 s2526 s2525 vdd vdd pch W=1u L=0.18u
Cl2526 s2526 0 10f
Mn2527 s2527 s2526 0 0 nch W=0.5u L=0.18u
Mp2527 s2527 s2526 vdd vdd pch W=1u L=0.18u
Cl2527 s2527 0 10f
Mn2528 s2528 s2527 0 0 nch W=0.5u L=0.18u
Mp2528 s2528 s2527 vdd vdd pch W=1u L=0.18u
Cl2528 s2528 0 10f
Mn2529 s2529 s2528 0 0 nch W=0.5u L=0.18u
Mp2529 s2529 s2528 vdd vdd pch W=1u L=0.18u
Cl2529 s2529 0 10f
Mn2530 s2530 s2529 0 0 nch W=0.5u L=0.18u
Mp2530 s2530 s2529 vdd vdd pch W=1u L=0.18u
Cl2530 s2530 0 10f
Mn2531 s2531 s2530 0 0 nch W=0.5u L=0.18u
Mp2531 s2531 s2530 vdd vdd pch W=1u L=0.18u
Cl2531 s2531 0 10f
Mn2532 s2532 s2531 0 0 nch W=0.5u L=0.18u
Mp2532 s2532 s2531 vdd vdd pch W=1u L=0.18u
Cl2532 s2532 0 10f
Mn2533 s2533 s2532 0 0 nch W=0.5u L=0.18u
Mp2533 s2533 s2532 vdd vdd pch W=1u L=0.18u
Cl2533 s2533 0 10f
Mn2534 s2534 s2533 0 0 nch W=0.5u L=0.18u
Mp2534 s2534 s2533 vdd vdd pch W=1u L=0.18u
Cl2534 s2534 0 10f
Mn2535 s2535 s2534 0 0 nch W=0.5u L=0.18u
Mp2535 s2535 s2534 vdd vdd pch W=1u L=0.18u
Cl2535 s2535 0 10f
Mn2536 s2536 s2535 0 0 nch W=0.5u L=0.18u
Mp2536 s2536 s2535 vdd vdd pch W=1u L=0.18u
Cl2536 s2536 0 10f
Mn2537 s2537 s2536 0 0 nch W=0.5u L=0.18u
Mp2537 s2537 s2536 vdd vdd pch W=1u L=0.18u
Cl2537 s2537 0 10f
Mn2538 s2538 s2537 0 0 nch W=0.5u L=0.18u
Mp2538 s2538 s2537 vdd vdd pch W=1u L=0.18u
Cl2538 s2538 0 10f
Mn2539 s2539 s2538 0 0 nch W=0.5u L=0.18u
Mp2539 s2539 s2538 vdd vdd pch W=1u L=0.18u
Cl2539 s2539 0 10f
Mn2540 s2540 s2539 0 0 nch W=0.5u L=0.18u
Mp2540 s2540 s2539 vdd vdd pch W=1u L=0.18u
Cl2540 s2540 0 10f
Mn2541 s2541 s2540 0 0 nch W=0.5u L=0.18u
Mp2541 s2541 s2540 vdd vdd pch W=1u L=0.18u
Cl2541 s2541 0 10f
Mn2542 s2542 s2541 0 0 nch W=0.5u L=0.18u
Mp2542 s2542 s2541 vdd vdd pch W=1u L=0.18u
Cl2542 s2542 0 10f
Mn2543 s2543 s2542 0 0 nch W=0.5u L=0.18u
Mp2543 s2543 s2542 vdd vdd pch W=1u L=0.18u
Cl2543 s2543 0 10f
Mn2544 s2544 s2543 0 0 nch W=0.5u L=0.18u
Mp2544 s2544 s2543 vdd vdd pch W=1u L=0.18u
Cl2544 s2544 0 10f
Mn2545 s2545 s2544 0 0 nch W=0.5u L=0.18u
Mp2545 s2545 s2544 vdd vdd pch W=1u L=0.18u
Cl2545 s2545 0 10f
Mn2546 s2546 s2545 0 0 nch W=0.5u L=0.18u
Mp2546 s2546 s2545 vdd vdd pch W=1u L=0.18u
Cl2546 s2546 0 10f
Mn2547 s2547 s2546 0 0 nch W=0.5u L=0.18u
Mp2547 s2547 s2546 vdd vdd pch W=1u L=0.18u
Cl2547 s2547 0 10f
Mn2548 s2548 s2547 0 0 nch W=0.5u L=0.18u
Mp2548 s2548 s2547 vdd vdd pch W=1u L=0.18u
Cl2548 s2548 0 10f
Mn2549 s2549 s2548 0 0 nch W=0.5u L=0.18u
Mp2549 s2549 s2548 vdd vdd pch W=1u L=0.18u
Cl2549 s2549 0 10f
Mn2550 s2550 s2549 0 0 nch W=0.5u L=0.18u
Mp2550 s2550 s2549 vdd vdd pch W=1u L=0.18u
Cl2550 s2550 0 10f
Mn2551 s2551 s2550 0 0 nch W=0.5u L=0.18u
Mp2551 s2551 s2550 vdd vdd pch W=1u L=0.18u
Cl2551 s2551 0 10f
Mn2552 s2552 s2551 0 0 nch W=0.5u L=0.18u
Mp2552 s2552 s2551 vdd vdd pch W=1u L=0.18u
Cl2552 s2552 0 10f
Mn2553 s2553 s2552 0 0 nch W=0.5u L=0.18u
Mp2553 s2553 s2552 vdd vdd pch W=1u L=0.18u
Cl2553 s2553 0 10f
Mn2554 s2554 s2553 0 0 nch W=0.5u L=0.18u
Mp2554 s2554 s2553 vdd vdd pch W=1u L=0.18u
Cl2554 s2554 0 10f
Mn2555 s2555 s2554 0 0 nch W=0.5u L=0.18u
Mp2555 s2555 s2554 vdd vdd pch W=1u L=0.18u
Cl2555 s2555 0 10f
Mn2556 s2556 s2555 0 0 nch W=0.5u L=0.18u
Mp2556 s2556 s2555 vdd vdd pch W=1u L=0.18u
Cl2556 s2556 0 10f
Mn2557 s2557 s2556 0 0 nch W=0.5u L=0.18u
Mp2557 s2557 s2556 vdd vdd pch W=1u L=0.18u
Cl2557 s2557 0 10f
Mn2558 s2558 s2557 0 0 nch W=0.5u L=0.18u
Mp2558 s2558 s2557 vdd vdd pch W=1u L=0.18u
Cl2558 s2558 0 10f
Mn2559 s2559 s2558 0 0 nch W=0.5u L=0.18u
Mp2559 s2559 s2558 vdd vdd pch W=1u L=0.18u
Cl2559 s2559 0 10f
Mn2560 s2560 s2559 0 0 nch W=0.5u L=0.18u
Mp2560 s2560 s2559 vdd vdd pch W=1u L=0.18u
Cl2560 s2560 0 10f
Mn2561 s2561 s2560 0 0 nch W=0.5u L=0.18u
Mp2561 s2561 s2560 vdd vdd pch W=1u L=0.18u
Cl2561 s2561 0 10f
Mn2562 s2562 s2561 0 0 nch W=0.5u L=0.18u
Mp2562 s2562 s2561 vdd vdd pch W=1u L=0.18u
Cl2562 s2562 0 10f
Mn2563 s2563 s2562 0 0 nch W=0.5u L=0.18u
Mp2563 s2563 s2562 vdd vdd pch W=1u L=0.18u
Cl2563 s2563 0 10f
Mn2564 s2564 s2563 0 0 nch W=0.5u L=0.18u
Mp2564 s2564 s2563 vdd vdd pch W=1u L=0.18u
Cl2564 s2564 0 10f
Mn2565 s2565 s2564 0 0 nch W=0.5u L=0.18u
Mp2565 s2565 s2564 vdd vdd pch W=1u L=0.18u
Cl2565 s2565 0 10f
Mn2566 s2566 s2565 0 0 nch W=0.5u L=0.18u
Mp2566 s2566 s2565 vdd vdd pch W=1u L=0.18u
Cl2566 s2566 0 10f
Mn2567 s2567 s2566 0 0 nch W=0.5u L=0.18u
Mp2567 s2567 s2566 vdd vdd pch W=1u L=0.18u
Cl2567 s2567 0 10f
Mn2568 s2568 s2567 0 0 nch W=0.5u L=0.18u
Mp2568 s2568 s2567 vdd vdd pch W=1u L=0.18u
Cl2568 s2568 0 10f
Mn2569 s2569 s2568 0 0 nch W=0.5u L=0.18u
Mp2569 s2569 s2568 vdd vdd pch W=1u L=0.18u
Cl2569 s2569 0 10f
Mn2570 s2570 s2569 0 0 nch W=0.5u L=0.18u
Mp2570 s2570 s2569 vdd vdd pch W=1u L=0.18u
Cl2570 s2570 0 10f
Mn2571 s2571 s2570 0 0 nch W=0.5u L=0.18u
Mp2571 s2571 s2570 vdd vdd pch W=1u L=0.18u
Cl2571 s2571 0 10f
Mn2572 s2572 s2571 0 0 nch W=0.5u L=0.18u
Mp2572 s2572 s2571 vdd vdd pch W=1u L=0.18u
Cl2572 s2572 0 10f
Mn2573 s2573 s2572 0 0 nch W=0.5u L=0.18u
Mp2573 s2573 s2572 vdd vdd pch W=1u L=0.18u
Cl2573 s2573 0 10f
Mn2574 s2574 s2573 0 0 nch W=0.5u L=0.18u
Mp2574 s2574 s2573 vdd vdd pch W=1u L=0.18u
Cl2574 s2574 0 10f
Mn2575 s2575 s2574 0 0 nch W=0.5u L=0.18u
Mp2575 s2575 s2574 vdd vdd pch W=1u L=0.18u
Cl2575 s2575 0 10f
Mn2576 s2576 s2575 0 0 nch W=0.5u L=0.18u
Mp2576 s2576 s2575 vdd vdd pch W=1u L=0.18u
Cl2576 s2576 0 10f
Mn2577 s2577 s2576 0 0 nch W=0.5u L=0.18u
Mp2577 s2577 s2576 vdd vdd pch W=1u L=0.18u
Cl2577 s2577 0 10f
Mn2578 s2578 s2577 0 0 nch W=0.5u L=0.18u
Mp2578 s2578 s2577 vdd vdd pch W=1u L=0.18u
Cl2578 s2578 0 10f
Mn2579 s2579 s2578 0 0 nch W=0.5u L=0.18u
Mp2579 s2579 s2578 vdd vdd pch W=1u L=0.18u
Cl2579 s2579 0 10f
Mn2580 s2580 s2579 0 0 nch W=0.5u L=0.18u
Mp2580 s2580 s2579 vdd vdd pch W=1u L=0.18u
Cl2580 s2580 0 10f
Mn2581 s2581 s2580 0 0 nch W=0.5u L=0.18u
Mp2581 s2581 s2580 vdd vdd pch W=1u L=0.18u
Cl2581 s2581 0 10f
Mn2582 s2582 s2581 0 0 nch W=0.5u L=0.18u
Mp2582 s2582 s2581 vdd vdd pch W=1u L=0.18u
Cl2582 s2582 0 10f
Mn2583 s2583 s2582 0 0 nch W=0.5u L=0.18u
Mp2583 s2583 s2582 vdd vdd pch W=1u L=0.18u
Cl2583 s2583 0 10f
Mn2584 s2584 s2583 0 0 nch W=0.5u L=0.18u
Mp2584 s2584 s2583 vdd vdd pch W=1u L=0.18u
Cl2584 s2584 0 10f
Mn2585 s2585 s2584 0 0 nch W=0.5u L=0.18u
Mp2585 s2585 s2584 vdd vdd pch W=1u L=0.18u
Cl2585 s2585 0 10f
Mn2586 s2586 s2585 0 0 nch W=0.5u L=0.18u
Mp2586 s2586 s2585 vdd vdd pch W=1u L=0.18u
Cl2586 s2586 0 10f
Mn2587 s2587 s2586 0 0 nch W=0.5u L=0.18u
Mp2587 s2587 s2586 vdd vdd pch W=1u L=0.18u
Cl2587 s2587 0 10f
Mn2588 s2588 s2587 0 0 nch W=0.5u L=0.18u
Mp2588 s2588 s2587 vdd vdd pch W=1u L=0.18u
Cl2588 s2588 0 10f
Mn2589 s2589 s2588 0 0 nch W=0.5u L=0.18u
Mp2589 s2589 s2588 vdd vdd pch W=1u L=0.18u
Cl2589 s2589 0 10f
Mn2590 s2590 s2589 0 0 nch W=0.5u L=0.18u
Mp2590 s2590 s2589 vdd vdd pch W=1u L=0.18u
Cl2590 s2590 0 10f
Mn2591 s2591 s2590 0 0 nch W=0.5u L=0.18u
Mp2591 s2591 s2590 vdd vdd pch W=1u L=0.18u
Cl2591 s2591 0 10f
Mn2592 s2592 s2591 0 0 nch W=0.5u L=0.18u
Mp2592 s2592 s2591 vdd vdd pch W=1u L=0.18u
Cl2592 s2592 0 10f
Mn2593 s2593 s2592 0 0 nch W=0.5u L=0.18u
Mp2593 s2593 s2592 vdd vdd pch W=1u L=0.18u
Cl2593 s2593 0 10f
Mn2594 s2594 s2593 0 0 nch W=0.5u L=0.18u
Mp2594 s2594 s2593 vdd vdd pch W=1u L=0.18u
Cl2594 s2594 0 10f
Mn2595 s2595 s2594 0 0 nch W=0.5u L=0.18u
Mp2595 s2595 s2594 vdd vdd pch W=1u L=0.18u
Cl2595 s2595 0 10f
Mn2596 s2596 s2595 0 0 nch W=0.5u L=0.18u
Mp2596 s2596 s2595 vdd vdd pch W=1u L=0.18u
Cl2596 s2596 0 10f
Mn2597 s2597 s2596 0 0 nch W=0.5u L=0.18u
Mp2597 s2597 s2596 vdd vdd pch W=1u L=0.18u
Cl2597 s2597 0 10f
Mn2598 s2598 s2597 0 0 nch W=0.5u L=0.18u
Mp2598 s2598 s2597 vdd vdd pch W=1u L=0.18u
Cl2598 s2598 0 10f
Mn2599 s2599 s2598 0 0 nch W=0.5u L=0.18u
Mp2599 s2599 s2598 vdd vdd pch W=1u L=0.18u
Cl2599 s2599 0 10f
Mn2600 s2600 s2599 0 0 nch W=0.5u L=0.18u
Mp2600 s2600 s2599 vdd vdd pch W=1u L=0.18u
Cl2600 s2600 0 10f
Mn2601 s2601 s2600 0 0 nch W=0.5u L=0.18u
Mp2601 s2601 s2600 vdd vdd pch W=1u L=0.18u
Cl2601 s2601 0 10f
Mn2602 s2602 s2601 0 0 nch W=0.5u L=0.18u
Mp2602 s2602 s2601 vdd vdd pch W=1u L=0.18u
Cl2602 s2602 0 10f
Mn2603 s2603 s2602 0 0 nch W=0.5u L=0.18u
Mp2603 s2603 s2602 vdd vdd pch W=1u L=0.18u
Cl2603 s2603 0 10f
Mn2604 s2604 s2603 0 0 nch W=0.5u L=0.18u
Mp2604 s2604 s2603 vdd vdd pch W=1u L=0.18u
Cl2604 s2604 0 10f
Mn2605 s2605 s2604 0 0 nch W=0.5u L=0.18u
Mp2605 s2605 s2604 vdd vdd pch W=1u L=0.18u
Cl2605 s2605 0 10f
Mn2606 s2606 s2605 0 0 nch W=0.5u L=0.18u
Mp2606 s2606 s2605 vdd vdd pch W=1u L=0.18u
Cl2606 s2606 0 10f
Mn2607 s2607 s2606 0 0 nch W=0.5u L=0.18u
Mp2607 s2607 s2606 vdd vdd pch W=1u L=0.18u
Cl2607 s2607 0 10f
Mn2608 s2608 s2607 0 0 nch W=0.5u L=0.18u
Mp2608 s2608 s2607 vdd vdd pch W=1u L=0.18u
Cl2608 s2608 0 10f
Mn2609 s2609 s2608 0 0 nch W=0.5u L=0.18u
Mp2609 s2609 s2608 vdd vdd pch W=1u L=0.18u
Cl2609 s2609 0 10f
Mn2610 s2610 s2609 0 0 nch W=0.5u L=0.18u
Mp2610 s2610 s2609 vdd vdd pch W=1u L=0.18u
Cl2610 s2610 0 10f
Mn2611 s2611 s2610 0 0 nch W=0.5u L=0.18u
Mp2611 s2611 s2610 vdd vdd pch W=1u L=0.18u
Cl2611 s2611 0 10f
Mn2612 s2612 s2611 0 0 nch W=0.5u L=0.18u
Mp2612 s2612 s2611 vdd vdd pch W=1u L=0.18u
Cl2612 s2612 0 10f
Mn2613 s2613 s2612 0 0 nch W=0.5u L=0.18u
Mp2613 s2613 s2612 vdd vdd pch W=1u L=0.18u
Cl2613 s2613 0 10f
Mn2614 s2614 s2613 0 0 nch W=0.5u L=0.18u
Mp2614 s2614 s2613 vdd vdd pch W=1u L=0.18u
Cl2614 s2614 0 10f
Mn2615 s2615 s2614 0 0 nch W=0.5u L=0.18u
Mp2615 s2615 s2614 vdd vdd pch W=1u L=0.18u
Cl2615 s2615 0 10f
Mn2616 s2616 s2615 0 0 nch W=0.5u L=0.18u
Mp2616 s2616 s2615 vdd vdd pch W=1u L=0.18u
Cl2616 s2616 0 10f
Mn2617 s2617 s2616 0 0 nch W=0.5u L=0.18u
Mp2617 s2617 s2616 vdd vdd pch W=1u L=0.18u
Cl2617 s2617 0 10f
Mn2618 s2618 s2617 0 0 nch W=0.5u L=0.18u
Mp2618 s2618 s2617 vdd vdd pch W=1u L=0.18u
Cl2618 s2618 0 10f
Mn2619 s2619 s2618 0 0 nch W=0.5u L=0.18u
Mp2619 s2619 s2618 vdd vdd pch W=1u L=0.18u
Cl2619 s2619 0 10f
Mn2620 s2620 s2619 0 0 nch W=0.5u L=0.18u
Mp2620 s2620 s2619 vdd vdd pch W=1u L=0.18u
Cl2620 s2620 0 10f
Mn2621 s2621 s2620 0 0 nch W=0.5u L=0.18u
Mp2621 s2621 s2620 vdd vdd pch W=1u L=0.18u
Cl2621 s2621 0 10f
Mn2622 s2622 s2621 0 0 nch W=0.5u L=0.18u
Mp2622 s2622 s2621 vdd vdd pch W=1u L=0.18u
Cl2622 s2622 0 10f
Mn2623 s2623 s2622 0 0 nch W=0.5u L=0.18u
Mp2623 s2623 s2622 vdd vdd pch W=1u L=0.18u
Cl2623 s2623 0 10f
Mn2624 s2624 s2623 0 0 nch W=0.5u L=0.18u
Mp2624 s2624 s2623 vdd vdd pch W=1u L=0.18u
Cl2624 s2624 0 10f
Mn2625 s2625 s2624 0 0 nch W=0.5u L=0.18u
Mp2625 s2625 s2624 vdd vdd pch W=1u L=0.18u
Cl2625 s2625 0 10f
Mn2626 s2626 s2625 0 0 nch W=0.5u L=0.18u
Mp2626 s2626 s2625 vdd vdd pch W=1u L=0.18u
Cl2626 s2626 0 10f
Mn2627 s2627 s2626 0 0 nch W=0.5u L=0.18u
Mp2627 s2627 s2626 vdd vdd pch W=1u L=0.18u
Cl2627 s2627 0 10f
Mn2628 s2628 s2627 0 0 nch W=0.5u L=0.18u
Mp2628 s2628 s2627 vdd vdd pch W=1u L=0.18u
Cl2628 s2628 0 10f
Mn2629 s2629 s2628 0 0 nch W=0.5u L=0.18u
Mp2629 s2629 s2628 vdd vdd pch W=1u L=0.18u
Cl2629 s2629 0 10f
Mn2630 s2630 s2629 0 0 nch W=0.5u L=0.18u
Mp2630 s2630 s2629 vdd vdd pch W=1u L=0.18u
Cl2630 s2630 0 10f
Mn2631 s2631 s2630 0 0 nch W=0.5u L=0.18u
Mp2631 s2631 s2630 vdd vdd pch W=1u L=0.18u
Cl2631 s2631 0 10f
Mn2632 s2632 s2631 0 0 nch W=0.5u L=0.18u
Mp2632 s2632 s2631 vdd vdd pch W=1u L=0.18u
Cl2632 s2632 0 10f
Mn2633 s2633 s2632 0 0 nch W=0.5u L=0.18u
Mp2633 s2633 s2632 vdd vdd pch W=1u L=0.18u
Cl2633 s2633 0 10f
Mn2634 s2634 s2633 0 0 nch W=0.5u L=0.18u
Mp2634 s2634 s2633 vdd vdd pch W=1u L=0.18u
Cl2634 s2634 0 10f
Mn2635 s2635 s2634 0 0 nch W=0.5u L=0.18u
Mp2635 s2635 s2634 vdd vdd pch W=1u L=0.18u
Cl2635 s2635 0 10f
Mn2636 s2636 s2635 0 0 nch W=0.5u L=0.18u
Mp2636 s2636 s2635 vdd vdd pch W=1u L=0.18u
Cl2636 s2636 0 10f
Mn2637 s2637 s2636 0 0 nch W=0.5u L=0.18u
Mp2637 s2637 s2636 vdd vdd pch W=1u L=0.18u
Cl2637 s2637 0 10f
Mn2638 s2638 s2637 0 0 nch W=0.5u L=0.18u
Mp2638 s2638 s2637 vdd vdd pch W=1u L=0.18u
Cl2638 s2638 0 10f
Mn2639 s2639 s2638 0 0 nch W=0.5u L=0.18u
Mp2639 s2639 s2638 vdd vdd pch W=1u L=0.18u
Cl2639 s2639 0 10f
Mn2640 s2640 s2639 0 0 nch W=0.5u L=0.18u
Mp2640 s2640 s2639 vdd vdd pch W=1u L=0.18u
Cl2640 s2640 0 10f
Mn2641 s2641 s2640 0 0 nch W=0.5u L=0.18u
Mp2641 s2641 s2640 vdd vdd pch W=1u L=0.18u
Cl2641 s2641 0 10f
Mn2642 s2642 s2641 0 0 nch W=0.5u L=0.18u
Mp2642 s2642 s2641 vdd vdd pch W=1u L=0.18u
Cl2642 s2642 0 10f
Mn2643 s2643 s2642 0 0 nch W=0.5u L=0.18u
Mp2643 s2643 s2642 vdd vdd pch W=1u L=0.18u
Cl2643 s2643 0 10f
Mn2644 s2644 s2643 0 0 nch W=0.5u L=0.18u
Mp2644 s2644 s2643 vdd vdd pch W=1u L=0.18u
Cl2644 s2644 0 10f
Mn2645 s2645 s2644 0 0 nch W=0.5u L=0.18u
Mp2645 s2645 s2644 vdd vdd pch W=1u L=0.18u
Cl2645 s2645 0 10f
Mn2646 s2646 s2645 0 0 nch W=0.5u L=0.18u
Mp2646 s2646 s2645 vdd vdd pch W=1u L=0.18u
Cl2646 s2646 0 10f
Mn2647 s2647 s2646 0 0 nch W=0.5u L=0.18u
Mp2647 s2647 s2646 vdd vdd pch W=1u L=0.18u
Cl2647 s2647 0 10f
Mn2648 s2648 s2647 0 0 nch W=0.5u L=0.18u
Mp2648 s2648 s2647 vdd vdd pch W=1u L=0.18u
Cl2648 s2648 0 10f
Mn2649 s2649 s2648 0 0 nch W=0.5u L=0.18u
Mp2649 s2649 s2648 vdd vdd pch W=1u L=0.18u
Cl2649 s2649 0 10f
Mn2650 s2650 s2649 0 0 nch W=0.5u L=0.18u
Mp2650 s2650 s2649 vdd vdd pch W=1u L=0.18u
Cl2650 s2650 0 10f
Mn2651 s2651 s2650 0 0 nch W=0.5u L=0.18u
Mp2651 s2651 s2650 vdd vdd pch W=1u L=0.18u
Cl2651 s2651 0 10f
Mn2652 s2652 s2651 0 0 nch W=0.5u L=0.18u
Mp2652 s2652 s2651 vdd vdd pch W=1u L=0.18u
Cl2652 s2652 0 10f
Mn2653 s2653 s2652 0 0 nch W=0.5u L=0.18u
Mp2653 s2653 s2652 vdd vdd pch W=1u L=0.18u
Cl2653 s2653 0 10f
Mn2654 s2654 s2653 0 0 nch W=0.5u L=0.18u
Mp2654 s2654 s2653 vdd vdd pch W=1u L=0.18u
Cl2654 s2654 0 10f
Mn2655 s2655 s2654 0 0 nch W=0.5u L=0.18u
Mp2655 s2655 s2654 vdd vdd pch W=1u L=0.18u
Cl2655 s2655 0 10f
Mn2656 s2656 s2655 0 0 nch W=0.5u L=0.18u
Mp2656 s2656 s2655 vdd vdd pch W=1u L=0.18u
Cl2656 s2656 0 10f
Mn2657 s2657 s2656 0 0 nch W=0.5u L=0.18u
Mp2657 s2657 s2656 vdd vdd pch W=1u L=0.18u
Cl2657 s2657 0 10f
Mn2658 s2658 s2657 0 0 nch W=0.5u L=0.18u
Mp2658 s2658 s2657 vdd vdd pch W=1u L=0.18u
Cl2658 s2658 0 10f
Mn2659 s2659 s2658 0 0 nch W=0.5u L=0.18u
Mp2659 s2659 s2658 vdd vdd pch W=1u L=0.18u
Cl2659 s2659 0 10f
Mn2660 s2660 s2659 0 0 nch W=0.5u L=0.18u
Mp2660 s2660 s2659 vdd vdd pch W=1u L=0.18u
Cl2660 s2660 0 10f
Mn2661 s2661 s2660 0 0 nch W=0.5u L=0.18u
Mp2661 s2661 s2660 vdd vdd pch W=1u L=0.18u
Cl2661 s2661 0 10f
Mn2662 s2662 s2661 0 0 nch W=0.5u L=0.18u
Mp2662 s2662 s2661 vdd vdd pch W=1u L=0.18u
Cl2662 s2662 0 10f
Mn2663 s2663 s2662 0 0 nch W=0.5u L=0.18u
Mp2663 s2663 s2662 vdd vdd pch W=1u L=0.18u
Cl2663 s2663 0 10f
Mn2664 s2664 s2663 0 0 nch W=0.5u L=0.18u
Mp2664 s2664 s2663 vdd vdd pch W=1u L=0.18u
Cl2664 s2664 0 10f
Mn2665 s2665 s2664 0 0 nch W=0.5u L=0.18u
Mp2665 s2665 s2664 vdd vdd pch W=1u L=0.18u
Cl2665 s2665 0 10f
Mn2666 s2666 s2665 0 0 nch W=0.5u L=0.18u
Mp2666 s2666 s2665 vdd vdd pch W=1u L=0.18u
Cl2666 s2666 0 10f
Mn2667 s2667 s2666 0 0 nch W=0.5u L=0.18u
Mp2667 s2667 s2666 vdd vdd pch W=1u L=0.18u
Cl2667 s2667 0 10f
Mn2668 s2668 s2667 0 0 nch W=0.5u L=0.18u
Mp2668 s2668 s2667 vdd vdd pch W=1u L=0.18u
Cl2668 s2668 0 10f
Mn2669 s2669 s2668 0 0 nch W=0.5u L=0.18u
Mp2669 s2669 s2668 vdd vdd pch W=1u L=0.18u
Cl2669 s2669 0 10f
Mn2670 s2670 s2669 0 0 nch W=0.5u L=0.18u
Mp2670 s2670 s2669 vdd vdd pch W=1u L=0.18u
Cl2670 s2670 0 10f
Mn2671 s2671 s2670 0 0 nch W=0.5u L=0.18u
Mp2671 s2671 s2670 vdd vdd pch W=1u L=0.18u
Cl2671 s2671 0 10f
Mn2672 s2672 s2671 0 0 nch W=0.5u L=0.18u
Mp2672 s2672 s2671 vdd vdd pch W=1u L=0.18u
Cl2672 s2672 0 10f
Mn2673 s2673 s2672 0 0 nch W=0.5u L=0.18u
Mp2673 s2673 s2672 vdd vdd pch W=1u L=0.18u
Cl2673 s2673 0 10f
Mn2674 s2674 s2673 0 0 nch W=0.5u L=0.18u
Mp2674 s2674 s2673 vdd vdd pch W=1u L=0.18u
Cl2674 s2674 0 10f
Mn2675 s2675 s2674 0 0 nch W=0.5u L=0.18u
Mp2675 s2675 s2674 vdd vdd pch W=1u L=0.18u
Cl2675 s2675 0 10f
Mn2676 s2676 s2675 0 0 nch W=0.5u L=0.18u
Mp2676 s2676 s2675 vdd vdd pch W=1u L=0.18u
Cl2676 s2676 0 10f
Mn2677 s2677 s2676 0 0 nch W=0.5u L=0.18u
Mp2677 s2677 s2676 vdd vdd pch W=1u L=0.18u
Cl2677 s2677 0 10f
Mn2678 s2678 s2677 0 0 nch W=0.5u L=0.18u
Mp2678 s2678 s2677 vdd vdd pch W=1u L=0.18u
Cl2678 s2678 0 10f
Mn2679 s2679 s2678 0 0 nch W=0.5u L=0.18u
Mp2679 s2679 s2678 vdd vdd pch W=1u L=0.18u
Cl2679 s2679 0 10f
Mn2680 s2680 s2679 0 0 nch W=0.5u L=0.18u
Mp2680 s2680 s2679 vdd vdd pch W=1u L=0.18u
Cl2680 s2680 0 10f
Mn2681 s2681 s2680 0 0 nch W=0.5u L=0.18u
Mp2681 s2681 s2680 vdd vdd pch W=1u L=0.18u
Cl2681 s2681 0 10f
Mn2682 s2682 s2681 0 0 nch W=0.5u L=0.18u
Mp2682 s2682 s2681 vdd vdd pch W=1u L=0.18u
Cl2682 s2682 0 10f
Mn2683 s2683 s2682 0 0 nch W=0.5u L=0.18u
Mp2683 s2683 s2682 vdd vdd pch W=1u L=0.18u
Cl2683 s2683 0 10f
Mn2684 s2684 s2683 0 0 nch W=0.5u L=0.18u
Mp2684 s2684 s2683 vdd vdd pch W=1u L=0.18u
Cl2684 s2684 0 10f
Mn2685 s2685 s2684 0 0 nch W=0.5u L=0.18u
Mp2685 s2685 s2684 vdd vdd pch W=1u L=0.18u
Cl2685 s2685 0 10f
Mn2686 s2686 s2685 0 0 nch W=0.5u L=0.18u
Mp2686 s2686 s2685 vdd vdd pch W=1u L=0.18u
Cl2686 s2686 0 10f
Mn2687 s2687 s2686 0 0 nch W=0.5u L=0.18u
Mp2687 s2687 s2686 vdd vdd pch W=1u L=0.18u
Cl2687 s2687 0 10f
Mn2688 s2688 s2687 0 0 nch W=0.5u L=0.18u
Mp2688 s2688 s2687 vdd vdd pch W=1u L=0.18u
Cl2688 s2688 0 10f
Mn2689 s2689 s2688 0 0 nch W=0.5u L=0.18u
Mp2689 s2689 s2688 vdd vdd pch W=1u L=0.18u
Cl2689 s2689 0 10f
Mn2690 s2690 s2689 0 0 nch W=0.5u L=0.18u
Mp2690 s2690 s2689 vdd vdd pch W=1u L=0.18u
Cl2690 s2690 0 10f
Mn2691 s2691 s2690 0 0 nch W=0.5u L=0.18u
Mp2691 s2691 s2690 vdd vdd pch W=1u L=0.18u
Cl2691 s2691 0 10f
Mn2692 s2692 s2691 0 0 nch W=0.5u L=0.18u
Mp2692 s2692 s2691 vdd vdd pch W=1u L=0.18u
Cl2692 s2692 0 10f
Mn2693 s2693 s2692 0 0 nch W=0.5u L=0.18u
Mp2693 s2693 s2692 vdd vdd pch W=1u L=0.18u
Cl2693 s2693 0 10f
Mn2694 s2694 s2693 0 0 nch W=0.5u L=0.18u
Mp2694 s2694 s2693 vdd vdd pch W=1u L=0.18u
Cl2694 s2694 0 10f
Mn2695 s2695 s2694 0 0 nch W=0.5u L=0.18u
Mp2695 s2695 s2694 vdd vdd pch W=1u L=0.18u
Cl2695 s2695 0 10f
Mn2696 s2696 s2695 0 0 nch W=0.5u L=0.18u
Mp2696 s2696 s2695 vdd vdd pch W=1u L=0.18u
Cl2696 s2696 0 10f
Mn2697 s2697 s2696 0 0 nch W=0.5u L=0.18u
Mp2697 s2697 s2696 vdd vdd pch W=1u L=0.18u
Cl2697 s2697 0 10f
Mn2698 s2698 s2697 0 0 nch W=0.5u L=0.18u
Mp2698 s2698 s2697 vdd vdd pch W=1u L=0.18u
Cl2698 s2698 0 10f
Mn2699 s2699 s2698 0 0 nch W=0.5u L=0.18u
Mp2699 s2699 s2698 vdd vdd pch W=1u L=0.18u
Cl2699 s2699 0 10f
Mn2700 s2700 s2699 0 0 nch W=0.5u L=0.18u
Mp2700 s2700 s2699 vdd vdd pch W=1u L=0.18u
Cl2700 s2700 0 10f
Mn2701 s2701 s2700 0 0 nch W=0.5u L=0.18u
Mp2701 s2701 s2700 vdd vdd pch W=1u L=0.18u
Cl2701 s2701 0 10f
Mn2702 s2702 s2701 0 0 nch W=0.5u L=0.18u
Mp2702 s2702 s2701 vdd vdd pch W=1u L=0.18u
Cl2702 s2702 0 10f
Mn2703 s2703 s2702 0 0 nch W=0.5u L=0.18u
Mp2703 s2703 s2702 vdd vdd pch W=1u L=0.18u
Cl2703 s2703 0 10f
Mn2704 s2704 s2703 0 0 nch W=0.5u L=0.18u
Mp2704 s2704 s2703 vdd vdd pch W=1u L=0.18u
Cl2704 s2704 0 10f
Mn2705 s2705 s2704 0 0 nch W=0.5u L=0.18u
Mp2705 s2705 s2704 vdd vdd pch W=1u L=0.18u
Cl2705 s2705 0 10f
Mn2706 s2706 s2705 0 0 nch W=0.5u L=0.18u
Mp2706 s2706 s2705 vdd vdd pch W=1u L=0.18u
Cl2706 s2706 0 10f
Mn2707 s2707 s2706 0 0 nch W=0.5u L=0.18u
Mp2707 s2707 s2706 vdd vdd pch W=1u L=0.18u
Cl2707 s2707 0 10f
Mn2708 s2708 s2707 0 0 nch W=0.5u L=0.18u
Mp2708 s2708 s2707 vdd vdd pch W=1u L=0.18u
Cl2708 s2708 0 10f
Mn2709 s2709 s2708 0 0 nch W=0.5u L=0.18u
Mp2709 s2709 s2708 vdd vdd pch W=1u L=0.18u
Cl2709 s2709 0 10f
Mn2710 s2710 s2709 0 0 nch W=0.5u L=0.18u
Mp2710 s2710 s2709 vdd vdd pch W=1u L=0.18u
Cl2710 s2710 0 10f
Mn2711 s2711 s2710 0 0 nch W=0.5u L=0.18u
Mp2711 s2711 s2710 vdd vdd pch W=1u L=0.18u
Cl2711 s2711 0 10f
Mn2712 s2712 s2711 0 0 nch W=0.5u L=0.18u
Mp2712 s2712 s2711 vdd vdd pch W=1u L=0.18u
Cl2712 s2712 0 10f
Mn2713 s2713 s2712 0 0 nch W=0.5u L=0.18u
Mp2713 s2713 s2712 vdd vdd pch W=1u L=0.18u
Cl2713 s2713 0 10f
Mn2714 s2714 s2713 0 0 nch W=0.5u L=0.18u
Mp2714 s2714 s2713 vdd vdd pch W=1u L=0.18u
Cl2714 s2714 0 10f
Mn2715 s2715 s2714 0 0 nch W=0.5u L=0.18u
Mp2715 s2715 s2714 vdd vdd pch W=1u L=0.18u
Cl2715 s2715 0 10f
Mn2716 s2716 s2715 0 0 nch W=0.5u L=0.18u
Mp2716 s2716 s2715 vdd vdd pch W=1u L=0.18u
Cl2716 s2716 0 10f
Mn2717 s2717 s2716 0 0 nch W=0.5u L=0.18u
Mp2717 s2717 s2716 vdd vdd pch W=1u L=0.18u
Cl2717 s2717 0 10f
Mn2718 s2718 s2717 0 0 nch W=0.5u L=0.18u
Mp2718 s2718 s2717 vdd vdd pch W=1u L=0.18u
Cl2718 s2718 0 10f
Mn2719 s2719 s2718 0 0 nch W=0.5u L=0.18u
Mp2719 s2719 s2718 vdd vdd pch W=1u L=0.18u
Cl2719 s2719 0 10f
Mn2720 s2720 s2719 0 0 nch W=0.5u L=0.18u
Mp2720 s2720 s2719 vdd vdd pch W=1u L=0.18u
Cl2720 s2720 0 10f
Mn2721 s2721 s2720 0 0 nch W=0.5u L=0.18u
Mp2721 s2721 s2720 vdd vdd pch W=1u L=0.18u
Cl2721 s2721 0 10f
Mn2722 s2722 s2721 0 0 nch W=0.5u L=0.18u
Mp2722 s2722 s2721 vdd vdd pch W=1u L=0.18u
Cl2722 s2722 0 10f
Mn2723 s2723 s2722 0 0 nch W=0.5u L=0.18u
Mp2723 s2723 s2722 vdd vdd pch W=1u L=0.18u
Cl2723 s2723 0 10f
Mn2724 s2724 s2723 0 0 nch W=0.5u L=0.18u
Mp2724 s2724 s2723 vdd vdd pch W=1u L=0.18u
Cl2724 s2724 0 10f
Mn2725 s2725 s2724 0 0 nch W=0.5u L=0.18u
Mp2725 s2725 s2724 vdd vdd pch W=1u L=0.18u
Cl2725 s2725 0 10f
Mn2726 s2726 s2725 0 0 nch W=0.5u L=0.18u
Mp2726 s2726 s2725 vdd vdd pch W=1u L=0.18u
Cl2726 s2726 0 10f
Mn2727 s2727 s2726 0 0 nch W=0.5u L=0.18u
Mp2727 s2727 s2726 vdd vdd pch W=1u L=0.18u
Cl2727 s2727 0 10f
Mn2728 s2728 s2727 0 0 nch W=0.5u L=0.18u
Mp2728 s2728 s2727 vdd vdd pch W=1u L=0.18u
Cl2728 s2728 0 10f
Mn2729 s2729 s2728 0 0 nch W=0.5u L=0.18u
Mp2729 s2729 s2728 vdd vdd pch W=1u L=0.18u
Cl2729 s2729 0 10f
Mn2730 s2730 s2729 0 0 nch W=0.5u L=0.18u
Mp2730 s2730 s2729 vdd vdd pch W=1u L=0.18u
Cl2730 s2730 0 10f
Mn2731 s2731 s2730 0 0 nch W=0.5u L=0.18u
Mp2731 s2731 s2730 vdd vdd pch W=1u L=0.18u
Cl2731 s2731 0 10f
Mn2732 s2732 s2731 0 0 nch W=0.5u L=0.18u
Mp2732 s2732 s2731 vdd vdd pch W=1u L=0.18u
Cl2732 s2732 0 10f
Mn2733 s2733 s2732 0 0 nch W=0.5u L=0.18u
Mp2733 s2733 s2732 vdd vdd pch W=1u L=0.18u
Cl2733 s2733 0 10f
Mn2734 s2734 s2733 0 0 nch W=0.5u L=0.18u
Mp2734 s2734 s2733 vdd vdd pch W=1u L=0.18u
Cl2734 s2734 0 10f
Mn2735 s2735 s2734 0 0 nch W=0.5u L=0.18u
Mp2735 s2735 s2734 vdd vdd pch W=1u L=0.18u
Cl2735 s2735 0 10f
Mn2736 s2736 s2735 0 0 nch W=0.5u L=0.18u
Mp2736 s2736 s2735 vdd vdd pch W=1u L=0.18u
Cl2736 s2736 0 10f
Mn2737 s2737 s2736 0 0 nch W=0.5u L=0.18u
Mp2737 s2737 s2736 vdd vdd pch W=1u L=0.18u
Cl2737 s2737 0 10f
Mn2738 s2738 s2737 0 0 nch W=0.5u L=0.18u
Mp2738 s2738 s2737 vdd vdd pch W=1u L=0.18u
Cl2738 s2738 0 10f
Mn2739 s2739 s2738 0 0 nch W=0.5u L=0.18u
Mp2739 s2739 s2738 vdd vdd pch W=1u L=0.18u
Cl2739 s2739 0 10f
Mn2740 s2740 s2739 0 0 nch W=0.5u L=0.18u
Mp2740 s2740 s2739 vdd vdd pch W=1u L=0.18u
Cl2740 s2740 0 10f
Mn2741 s2741 s2740 0 0 nch W=0.5u L=0.18u
Mp2741 s2741 s2740 vdd vdd pch W=1u L=0.18u
Cl2741 s2741 0 10f
Mn2742 s2742 s2741 0 0 nch W=0.5u L=0.18u
Mp2742 s2742 s2741 vdd vdd pch W=1u L=0.18u
Cl2742 s2742 0 10f
Mn2743 s2743 s2742 0 0 nch W=0.5u L=0.18u
Mp2743 s2743 s2742 vdd vdd pch W=1u L=0.18u
Cl2743 s2743 0 10f
Mn2744 s2744 s2743 0 0 nch W=0.5u L=0.18u
Mp2744 s2744 s2743 vdd vdd pch W=1u L=0.18u
Cl2744 s2744 0 10f
Mn2745 s2745 s2744 0 0 nch W=0.5u L=0.18u
Mp2745 s2745 s2744 vdd vdd pch W=1u L=0.18u
Cl2745 s2745 0 10f
Mn2746 s2746 s2745 0 0 nch W=0.5u L=0.18u
Mp2746 s2746 s2745 vdd vdd pch W=1u L=0.18u
Cl2746 s2746 0 10f
Mn2747 s2747 s2746 0 0 nch W=0.5u L=0.18u
Mp2747 s2747 s2746 vdd vdd pch W=1u L=0.18u
Cl2747 s2747 0 10f
Mn2748 s2748 s2747 0 0 nch W=0.5u L=0.18u
Mp2748 s2748 s2747 vdd vdd pch W=1u L=0.18u
Cl2748 s2748 0 10f
Mn2749 s2749 s2748 0 0 nch W=0.5u L=0.18u
Mp2749 s2749 s2748 vdd vdd pch W=1u L=0.18u
Cl2749 s2749 0 10f
Mn2750 s2750 s2749 0 0 nch W=0.5u L=0.18u
Mp2750 s2750 s2749 vdd vdd pch W=1u L=0.18u
Cl2750 s2750 0 10f
Mn2751 s2751 s2750 0 0 nch W=0.5u L=0.18u
Mp2751 s2751 s2750 vdd vdd pch W=1u L=0.18u
Cl2751 s2751 0 10f
Mn2752 s2752 s2751 0 0 nch W=0.5u L=0.18u
Mp2752 s2752 s2751 vdd vdd pch W=1u L=0.18u
Cl2752 s2752 0 10f
Mn2753 s2753 s2752 0 0 nch W=0.5u L=0.18u
Mp2753 s2753 s2752 vdd vdd pch W=1u L=0.18u
Cl2753 s2753 0 10f
Mn2754 s2754 s2753 0 0 nch W=0.5u L=0.18u
Mp2754 s2754 s2753 vdd vdd pch W=1u L=0.18u
Cl2754 s2754 0 10f
Mn2755 s2755 s2754 0 0 nch W=0.5u L=0.18u
Mp2755 s2755 s2754 vdd vdd pch W=1u L=0.18u
Cl2755 s2755 0 10f
Mn2756 s2756 s2755 0 0 nch W=0.5u L=0.18u
Mp2756 s2756 s2755 vdd vdd pch W=1u L=0.18u
Cl2756 s2756 0 10f
Mn2757 s2757 s2756 0 0 nch W=0.5u L=0.18u
Mp2757 s2757 s2756 vdd vdd pch W=1u L=0.18u
Cl2757 s2757 0 10f
Mn2758 s2758 s2757 0 0 nch W=0.5u L=0.18u
Mp2758 s2758 s2757 vdd vdd pch W=1u L=0.18u
Cl2758 s2758 0 10f
Mn2759 s2759 s2758 0 0 nch W=0.5u L=0.18u
Mp2759 s2759 s2758 vdd vdd pch W=1u L=0.18u
Cl2759 s2759 0 10f
Mn2760 s2760 s2759 0 0 nch W=0.5u L=0.18u
Mp2760 s2760 s2759 vdd vdd pch W=1u L=0.18u
Cl2760 s2760 0 10f
Mn2761 s2761 s2760 0 0 nch W=0.5u L=0.18u
Mp2761 s2761 s2760 vdd vdd pch W=1u L=0.18u
Cl2761 s2761 0 10f
Mn2762 s2762 s2761 0 0 nch W=0.5u L=0.18u
Mp2762 s2762 s2761 vdd vdd pch W=1u L=0.18u
Cl2762 s2762 0 10f
Mn2763 s2763 s2762 0 0 nch W=0.5u L=0.18u
Mp2763 s2763 s2762 vdd vdd pch W=1u L=0.18u
Cl2763 s2763 0 10f
Mn2764 s2764 s2763 0 0 nch W=0.5u L=0.18u
Mp2764 s2764 s2763 vdd vdd pch W=1u L=0.18u
Cl2764 s2764 0 10f
Mn2765 s2765 s2764 0 0 nch W=0.5u L=0.18u
Mp2765 s2765 s2764 vdd vdd pch W=1u L=0.18u
Cl2765 s2765 0 10f
Mn2766 s2766 s2765 0 0 nch W=0.5u L=0.18u
Mp2766 s2766 s2765 vdd vdd pch W=1u L=0.18u
Cl2766 s2766 0 10f
Mn2767 s2767 s2766 0 0 nch W=0.5u L=0.18u
Mp2767 s2767 s2766 vdd vdd pch W=1u L=0.18u
Cl2767 s2767 0 10f
Mn2768 s2768 s2767 0 0 nch W=0.5u L=0.18u
Mp2768 s2768 s2767 vdd vdd pch W=1u L=0.18u
Cl2768 s2768 0 10f
Mn2769 s2769 s2768 0 0 nch W=0.5u L=0.18u
Mp2769 s2769 s2768 vdd vdd pch W=1u L=0.18u
Cl2769 s2769 0 10f
Mn2770 s2770 s2769 0 0 nch W=0.5u L=0.18u
Mp2770 s2770 s2769 vdd vdd pch W=1u L=0.18u
Cl2770 s2770 0 10f
Mn2771 s2771 s2770 0 0 nch W=0.5u L=0.18u
Mp2771 s2771 s2770 vdd vdd pch W=1u L=0.18u
Cl2771 s2771 0 10f
Mn2772 s2772 s2771 0 0 nch W=0.5u L=0.18u
Mp2772 s2772 s2771 vdd vdd pch W=1u L=0.18u
Cl2772 s2772 0 10f
Mn2773 s2773 s2772 0 0 nch W=0.5u L=0.18u
Mp2773 s2773 s2772 vdd vdd pch W=1u L=0.18u
Cl2773 s2773 0 10f
Mn2774 s2774 s2773 0 0 nch W=0.5u L=0.18u
Mp2774 s2774 s2773 vdd vdd pch W=1u L=0.18u
Cl2774 s2774 0 10f
Mn2775 s2775 s2774 0 0 nch W=0.5u L=0.18u
Mp2775 s2775 s2774 vdd vdd pch W=1u L=0.18u
Cl2775 s2775 0 10f
Mn2776 s2776 s2775 0 0 nch W=0.5u L=0.18u
Mp2776 s2776 s2775 vdd vdd pch W=1u L=0.18u
Cl2776 s2776 0 10f
Mn2777 s2777 s2776 0 0 nch W=0.5u L=0.18u
Mp2777 s2777 s2776 vdd vdd pch W=1u L=0.18u
Cl2777 s2777 0 10f
Mn2778 s2778 s2777 0 0 nch W=0.5u L=0.18u
Mp2778 s2778 s2777 vdd vdd pch W=1u L=0.18u
Cl2778 s2778 0 10f
Mn2779 s2779 s2778 0 0 nch W=0.5u L=0.18u
Mp2779 s2779 s2778 vdd vdd pch W=1u L=0.18u
Cl2779 s2779 0 10f
Mn2780 s2780 s2779 0 0 nch W=0.5u L=0.18u
Mp2780 s2780 s2779 vdd vdd pch W=1u L=0.18u
Cl2780 s2780 0 10f
Mn2781 s2781 s2780 0 0 nch W=0.5u L=0.18u
Mp2781 s2781 s2780 vdd vdd pch W=1u L=0.18u
Cl2781 s2781 0 10f
Mn2782 s2782 s2781 0 0 nch W=0.5u L=0.18u
Mp2782 s2782 s2781 vdd vdd pch W=1u L=0.18u
Cl2782 s2782 0 10f
Mn2783 s2783 s2782 0 0 nch W=0.5u L=0.18u
Mp2783 s2783 s2782 vdd vdd pch W=1u L=0.18u
Cl2783 s2783 0 10f
Mn2784 s2784 s2783 0 0 nch W=0.5u L=0.18u
Mp2784 s2784 s2783 vdd vdd pch W=1u L=0.18u
Cl2784 s2784 0 10f
Mn2785 s2785 s2784 0 0 nch W=0.5u L=0.18u
Mp2785 s2785 s2784 vdd vdd pch W=1u L=0.18u
Cl2785 s2785 0 10f
Mn2786 s2786 s2785 0 0 nch W=0.5u L=0.18u
Mp2786 s2786 s2785 vdd vdd pch W=1u L=0.18u
Cl2786 s2786 0 10f
Mn2787 s2787 s2786 0 0 nch W=0.5u L=0.18u
Mp2787 s2787 s2786 vdd vdd pch W=1u L=0.18u
Cl2787 s2787 0 10f
Mn2788 s2788 s2787 0 0 nch W=0.5u L=0.18u
Mp2788 s2788 s2787 vdd vdd pch W=1u L=0.18u
Cl2788 s2788 0 10f
Mn2789 s2789 s2788 0 0 nch W=0.5u L=0.18u
Mp2789 s2789 s2788 vdd vdd pch W=1u L=0.18u
Cl2789 s2789 0 10f
Mn2790 s2790 s2789 0 0 nch W=0.5u L=0.18u
Mp2790 s2790 s2789 vdd vdd pch W=1u L=0.18u
Cl2790 s2790 0 10f
Mn2791 s2791 s2790 0 0 nch W=0.5u L=0.18u
Mp2791 s2791 s2790 vdd vdd pch W=1u L=0.18u
Cl2791 s2791 0 10f
Mn2792 s2792 s2791 0 0 nch W=0.5u L=0.18u
Mp2792 s2792 s2791 vdd vdd pch W=1u L=0.18u
Cl2792 s2792 0 10f
Mn2793 s2793 s2792 0 0 nch W=0.5u L=0.18u
Mp2793 s2793 s2792 vdd vdd pch W=1u L=0.18u
Cl2793 s2793 0 10f
Mn2794 s2794 s2793 0 0 nch W=0.5u L=0.18u
Mp2794 s2794 s2793 vdd vdd pch W=1u L=0.18u
Cl2794 s2794 0 10f
Mn2795 s2795 s2794 0 0 nch W=0.5u L=0.18u
Mp2795 s2795 s2794 vdd vdd pch W=1u L=0.18u
Cl2795 s2795 0 10f
Mn2796 s2796 s2795 0 0 nch W=0.5u L=0.18u
Mp2796 s2796 s2795 vdd vdd pch W=1u L=0.18u
Cl2796 s2796 0 10f
Mn2797 s2797 s2796 0 0 nch W=0.5u L=0.18u
Mp2797 s2797 s2796 vdd vdd pch W=1u L=0.18u
Cl2797 s2797 0 10f
Mn2798 s2798 s2797 0 0 nch W=0.5u L=0.18u
Mp2798 s2798 s2797 vdd vdd pch W=1u L=0.18u
Cl2798 s2798 0 10f
Mn2799 s2799 s2798 0 0 nch W=0.5u L=0.18u
Mp2799 s2799 s2798 vdd vdd pch W=1u L=0.18u
Cl2799 s2799 0 10f
Mn2800 s2800 s2799 0 0 nch W=0.5u L=0.18u
Mp2800 s2800 s2799 vdd vdd pch W=1u L=0.18u
Cl2800 s2800 0 10f
Mn2801 s2801 s2800 0 0 nch W=0.5u L=0.18u
Mp2801 s2801 s2800 vdd vdd pch W=1u L=0.18u
Cl2801 s2801 0 10f
Mn2802 s2802 s2801 0 0 nch W=0.5u L=0.18u
Mp2802 s2802 s2801 vdd vdd pch W=1u L=0.18u
Cl2802 s2802 0 10f
Mn2803 s2803 s2802 0 0 nch W=0.5u L=0.18u
Mp2803 s2803 s2802 vdd vdd pch W=1u L=0.18u
Cl2803 s2803 0 10f
Mn2804 s2804 s2803 0 0 nch W=0.5u L=0.18u
Mp2804 s2804 s2803 vdd vdd pch W=1u L=0.18u
Cl2804 s2804 0 10f
Mn2805 s2805 s2804 0 0 nch W=0.5u L=0.18u
Mp2805 s2805 s2804 vdd vdd pch W=1u L=0.18u
Cl2805 s2805 0 10f
Mn2806 s2806 s2805 0 0 nch W=0.5u L=0.18u
Mp2806 s2806 s2805 vdd vdd pch W=1u L=0.18u
Cl2806 s2806 0 10f
Mn2807 s2807 s2806 0 0 nch W=0.5u L=0.18u
Mp2807 s2807 s2806 vdd vdd pch W=1u L=0.18u
Cl2807 s2807 0 10f
Mn2808 s2808 s2807 0 0 nch W=0.5u L=0.18u
Mp2808 s2808 s2807 vdd vdd pch W=1u L=0.18u
Cl2808 s2808 0 10f
Mn2809 s2809 s2808 0 0 nch W=0.5u L=0.18u
Mp2809 s2809 s2808 vdd vdd pch W=1u L=0.18u
Cl2809 s2809 0 10f
Mn2810 s2810 s2809 0 0 nch W=0.5u L=0.18u
Mp2810 s2810 s2809 vdd vdd pch W=1u L=0.18u
Cl2810 s2810 0 10f
Mn2811 s2811 s2810 0 0 nch W=0.5u L=0.18u
Mp2811 s2811 s2810 vdd vdd pch W=1u L=0.18u
Cl2811 s2811 0 10f
Mn2812 s2812 s2811 0 0 nch W=0.5u L=0.18u
Mp2812 s2812 s2811 vdd vdd pch W=1u L=0.18u
Cl2812 s2812 0 10f
Mn2813 s2813 s2812 0 0 nch W=0.5u L=0.18u
Mp2813 s2813 s2812 vdd vdd pch W=1u L=0.18u
Cl2813 s2813 0 10f
Mn2814 s2814 s2813 0 0 nch W=0.5u L=0.18u
Mp2814 s2814 s2813 vdd vdd pch W=1u L=0.18u
Cl2814 s2814 0 10f
Mn2815 s2815 s2814 0 0 nch W=0.5u L=0.18u
Mp2815 s2815 s2814 vdd vdd pch W=1u L=0.18u
Cl2815 s2815 0 10f
Mn2816 s2816 s2815 0 0 nch W=0.5u L=0.18u
Mp2816 s2816 s2815 vdd vdd pch W=1u L=0.18u
Cl2816 s2816 0 10f
Mn2817 s2817 s2816 0 0 nch W=0.5u L=0.18u
Mp2817 s2817 s2816 vdd vdd pch W=1u L=0.18u
Cl2817 s2817 0 10f
Mn2818 s2818 s2817 0 0 nch W=0.5u L=0.18u
Mp2818 s2818 s2817 vdd vdd pch W=1u L=0.18u
Cl2818 s2818 0 10f
Mn2819 s2819 s2818 0 0 nch W=0.5u L=0.18u
Mp2819 s2819 s2818 vdd vdd pch W=1u L=0.18u
Cl2819 s2819 0 10f
Mn2820 s2820 s2819 0 0 nch W=0.5u L=0.18u
Mp2820 s2820 s2819 vdd vdd pch W=1u L=0.18u
Cl2820 s2820 0 10f
Mn2821 s2821 s2820 0 0 nch W=0.5u L=0.18u
Mp2821 s2821 s2820 vdd vdd pch W=1u L=0.18u
Cl2821 s2821 0 10f
Mn2822 s2822 s2821 0 0 nch W=0.5u L=0.18u
Mp2822 s2822 s2821 vdd vdd pch W=1u L=0.18u
Cl2822 s2822 0 10f
Mn2823 s2823 s2822 0 0 nch W=0.5u L=0.18u
Mp2823 s2823 s2822 vdd vdd pch W=1u L=0.18u
Cl2823 s2823 0 10f
Mn2824 s2824 s2823 0 0 nch W=0.5u L=0.18u
Mp2824 s2824 s2823 vdd vdd pch W=1u L=0.18u
Cl2824 s2824 0 10f
Mn2825 s2825 s2824 0 0 nch W=0.5u L=0.18u
Mp2825 s2825 s2824 vdd vdd pch W=1u L=0.18u
Cl2825 s2825 0 10f
Mn2826 s2826 s2825 0 0 nch W=0.5u L=0.18u
Mp2826 s2826 s2825 vdd vdd pch W=1u L=0.18u
Cl2826 s2826 0 10f
Mn2827 s2827 s2826 0 0 nch W=0.5u L=0.18u
Mp2827 s2827 s2826 vdd vdd pch W=1u L=0.18u
Cl2827 s2827 0 10f
Mn2828 s2828 s2827 0 0 nch W=0.5u L=0.18u
Mp2828 s2828 s2827 vdd vdd pch W=1u L=0.18u
Cl2828 s2828 0 10f
Mn2829 s2829 s2828 0 0 nch W=0.5u L=0.18u
Mp2829 s2829 s2828 vdd vdd pch W=1u L=0.18u
Cl2829 s2829 0 10f
Mn2830 s2830 s2829 0 0 nch W=0.5u L=0.18u
Mp2830 s2830 s2829 vdd vdd pch W=1u L=0.18u
Cl2830 s2830 0 10f
Mn2831 s2831 s2830 0 0 nch W=0.5u L=0.18u
Mp2831 s2831 s2830 vdd vdd pch W=1u L=0.18u
Cl2831 s2831 0 10f
Mn2832 s2832 s2831 0 0 nch W=0.5u L=0.18u
Mp2832 s2832 s2831 vdd vdd pch W=1u L=0.18u
Cl2832 s2832 0 10f
Mn2833 s2833 s2832 0 0 nch W=0.5u L=0.18u
Mp2833 s2833 s2832 vdd vdd pch W=1u L=0.18u
Cl2833 s2833 0 10f
Mn2834 s2834 s2833 0 0 nch W=0.5u L=0.18u
Mp2834 s2834 s2833 vdd vdd pch W=1u L=0.18u
Cl2834 s2834 0 10f
Mn2835 s2835 s2834 0 0 nch W=0.5u L=0.18u
Mp2835 s2835 s2834 vdd vdd pch W=1u L=0.18u
Cl2835 s2835 0 10f
Mn2836 s2836 s2835 0 0 nch W=0.5u L=0.18u
Mp2836 s2836 s2835 vdd vdd pch W=1u L=0.18u
Cl2836 s2836 0 10f
Mn2837 s2837 s2836 0 0 nch W=0.5u L=0.18u
Mp2837 s2837 s2836 vdd vdd pch W=1u L=0.18u
Cl2837 s2837 0 10f
Mn2838 s2838 s2837 0 0 nch W=0.5u L=0.18u
Mp2838 s2838 s2837 vdd vdd pch W=1u L=0.18u
Cl2838 s2838 0 10f
Mn2839 s2839 s2838 0 0 nch W=0.5u L=0.18u
Mp2839 s2839 s2838 vdd vdd pch W=1u L=0.18u
Cl2839 s2839 0 10f
Mn2840 s2840 s2839 0 0 nch W=0.5u L=0.18u
Mp2840 s2840 s2839 vdd vdd pch W=1u L=0.18u
Cl2840 s2840 0 10f
Mn2841 s2841 s2840 0 0 nch W=0.5u L=0.18u
Mp2841 s2841 s2840 vdd vdd pch W=1u L=0.18u
Cl2841 s2841 0 10f
Mn2842 s2842 s2841 0 0 nch W=0.5u L=0.18u
Mp2842 s2842 s2841 vdd vdd pch W=1u L=0.18u
Cl2842 s2842 0 10f
Mn2843 s2843 s2842 0 0 nch W=0.5u L=0.18u
Mp2843 s2843 s2842 vdd vdd pch W=1u L=0.18u
Cl2843 s2843 0 10f
Mn2844 s2844 s2843 0 0 nch W=0.5u L=0.18u
Mp2844 s2844 s2843 vdd vdd pch W=1u L=0.18u
Cl2844 s2844 0 10f
Mn2845 s2845 s2844 0 0 nch W=0.5u L=0.18u
Mp2845 s2845 s2844 vdd vdd pch W=1u L=0.18u
Cl2845 s2845 0 10f
Mn2846 s2846 s2845 0 0 nch W=0.5u L=0.18u
Mp2846 s2846 s2845 vdd vdd pch W=1u L=0.18u
Cl2846 s2846 0 10f
Mn2847 s2847 s2846 0 0 nch W=0.5u L=0.18u
Mp2847 s2847 s2846 vdd vdd pch W=1u L=0.18u
Cl2847 s2847 0 10f
Mn2848 s2848 s2847 0 0 nch W=0.5u L=0.18u
Mp2848 s2848 s2847 vdd vdd pch W=1u L=0.18u
Cl2848 s2848 0 10f
Mn2849 s2849 s2848 0 0 nch W=0.5u L=0.18u
Mp2849 s2849 s2848 vdd vdd pch W=1u L=0.18u
Cl2849 s2849 0 10f
Mn2850 s2850 s2849 0 0 nch W=0.5u L=0.18u
Mp2850 s2850 s2849 vdd vdd pch W=1u L=0.18u
Cl2850 s2850 0 10f
Mn2851 s2851 s2850 0 0 nch W=0.5u L=0.18u
Mp2851 s2851 s2850 vdd vdd pch W=1u L=0.18u
Cl2851 s2851 0 10f
Mn2852 s2852 s2851 0 0 nch W=0.5u L=0.18u
Mp2852 s2852 s2851 vdd vdd pch W=1u L=0.18u
Cl2852 s2852 0 10f
Mn2853 s2853 s2852 0 0 nch W=0.5u L=0.18u
Mp2853 s2853 s2852 vdd vdd pch W=1u L=0.18u
Cl2853 s2853 0 10f
Mn2854 s2854 s2853 0 0 nch W=0.5u L=0.18u
Mp2854 s2854 s2853 vdd vdd pch W=1u L=0.18u
Cl2854 s2854 0 10f
Mn2855 s2855 s2854 0 0 nch W=0.5u L=0.18u
Mp2855 s2855 s2854 vdd vdd pch W=1u L=0.18u
Cl2855 s2855 0 10f
Mn2856 s2856 s2855 0 0 nch W=0.5u L=0.18u
Mp2856 s2856 s2855 vdd vdd pch W=1u L=0.18u
Cl2856 s2856 0 10f
Mn2857 s2857 s2856 0 0 nch W=0.5u L=0.18u
Mp2857 s2857 s2856 vdd vdd pch W=1u L=0.18u
Cl2857 s2857 0 10f
Mn2858 s2858 s2857 0 0 nch W=0.5u L=0.18u
Mp2858 s2858 s2857 vdd vdd pch W=1u L=0.18u
Cl2858 s2858 0 10f
Mn2859 s2859 s2858 0 0 nch W=0.5u L=0.18u
Mp2859 s2859 s2858 vdd vdd pch W=1u L=0.18u
Cl2859 s2859 0 10f
Mn2860 s2860 s2859 0 0 nch W=0.5u L=0.18u
Mp2860 s2860 s2859 vdd vdd pch W=1u L=0.18u
Cl2860 s2860 0 10f
Mn2861 s2861 s2860 0 0 nch W=0.5u L=0.18u
Mp2861 s2861 s2860 vdd vdd pch W=1u L=0.18u
Cl2861 s2861 0 10f
Mn2862 s2862 s2861 0 0 nch W=0.5u L=0.18u
Mp2862 s2862 s2861 vdd vdd pch W=1u L=0.18u
Cl2862 s2862 0 10f
Mn2863 s2863 s2862 0 0 nch W=0.5u L=0.18u
Mp2863 s2863 s2862 vdd vdd pch W=1u L=0.18u
Cl2863 s2863 0 10f
Mn2864 s2864 s2863 0 0 nch W=0.5u L=0.18u
Mp2864 s2864 s2863 vdd vdd pch W=1u L=0.18u
Cl2864 s2864 0 10f
Mn2865 s2865 s2864 0 0 nch W=0.5u L=0.18u
Mp2865 s2865 s2864 vdd vdd pch W=1u L=0.18u
Cl2865 s2865 0 10f
Mn2866 s2866 s2865 0 0 nch W=0.5u L=0.18u
Mp2866 s2866 s2865 vdd vdd pch W=1u L=0.18u
Cl2866 s2866 0 10f
Mn2867 s2867 s2866 0 0 nch W=0.5u L=0.18u
Mp2867 s2867 s2866 vdd vdd pch W=1u L=0.18u
Cl2867 s2867 0 10f
Mn2868 s2868 s2867 0 0 nch W=0.5u L=0.18u
Mp2868 s2868 s2867 vdd vdd pch W=1u L=0.18u
Cl2868 s2868 0 10f
Mn2869 s2869 s2868 0 0 nch W=0.5u L=0.18u
Mp2869 s2869 s2868 vdd vdd pch W=1u L=0.18u
Cl2869 s2869 0 10f
Mn2870 s2870 s2869 0 0 nch W=0.5u L=0.18u
Mp2870 s2870 s2869 vdd vdd pch W=1u L=0.18u
Cl2870 s2870 0 10f
Mn2871 s2871 s2870 0 0 nch W=0.5u L=0.18u
Mp2871 s2871 s2870 vdd vdd pch W=1u L=0.18u
Cl2871 s2871 0 10f
Mn2872 s2872 s2871 0 0 nch W=0.5u L=0.18u
Mp2872 s2872 s2871 vdd vdd pch W=1u L=0.18u
Cl2872 s2872 0 10f
Mn2873 s2873 s2872 0 0 nch W=0.5u L=0.18u
Mp2873 s2873 s2872 vdd vdd pch W=1u L=0.18u
Cl2873 s2873 0 10f
Mn2874 s2874 s2873 0 0 nch W=0.5u L=0.18u
Mp2874 s2874 s2873 vdd vdd pch W=1u L=0.18u
Cl2874 s2874 0 10f
Mn2875 s2875 s2874 0 0 nch W=0.5u L=0.18u
Mp2875 s2875 s2874 vdd vdd pch W=1u L=0.18u
Cl2875 s2875 0 10f
Mn2876 s2876 s2875 0 0 nch W=0.5u L=0.18u
Mp2876 s2876 s2875 vdd vdd pch W=1u L=0.18u
Cl2876 s2876 0 10f
Mn2877 s2877 s2876 0 0 nch W=0.5u L=0.18u
Mp2877 s2877 s2876 vdd vdd pch W=1u L=0.18u
Cl2877 s2877 0 10f
Mn2878 s2878 s2877 0 0 nch W=0.5u L=0.18u
Mp2878 s2878 s2877 vdd vdd pch W=1u L=0.18u
Cl2878 s2878 0 10f
Mn2879 s2879 s2878 0 0 nch W=0.5u L=0.18u
Mp2879 s2879 s2878 vdd vdd pch W=1u L=0.18u
Cl2879 s2879 0 10f
Mn2880 s2880 s2879 0 0 nch W=0.5u L=0.18u
Mp2880 s2880 s2879 vdd vdd pch W=1u L=0.18u
Cl2880 s2880 0 10f
Mn2881 s2881 s2880 0 0 nch W=0.5u L=0.18u
Mp2881 s2881 s2880 vdd vdd pch W=1u L=0.18u
Cl2881 s2881 0 10f
Mn2882 s2882 s2881 0 0 nch W=0.5u L=0.18u
Mp2882 s2882 s2881 vdd vdd pch W=1u L=0.18u
Cl2882 s2882 0 10f
Mn2883 s2883 s2882 0 0 nch W=0.5u L=0.18u
Mp2883 s2883 s2882 vdd vdd pch W=1u L=0.18u
Cl2883 s2883 0 10f
Mn2884 s2884 s2883 0 0 nch W=0.5u L=0.18u
Mp2884 s2884 s2883 vdd vdd pch W=1u L=0.18u
Cl2884 s2884 0 10f
Mn2885 s2885 s2884 0 0 nch W=0.5u L=0.18u
Mp2885 s2885 s2884 vdd vdd pch W=1u L=0.18u
Cl2885 s2885 0 10f
Mn2886 s2886 s2885 0 0 nch W=0.5u L=0.18u
Mp2886 s2886 s2885 vdd vdd pch W=1u L=0.18u
Cl2886 s2886 0 10f
Mn2887 s2887 s2886 0 0 nch W=0.5u L=0.18u
Mp2887 s2887 s2886 vdd vdd pch W=1u L=0.18u
Cl2887 s2887 0 10f
Mn2888 s2888 s2887 0 0 nch W=0.5u L=0.18u
Mp2888 s2888 s2887 vdd vdd pch W=1u L=0.18u
Cl2888 s2888 0 10f
Mn2889 s2889 s2888 0 0 nch W=0.5u L=0.18u
Mp2889 s2889 s2888 vdd vdd pch W=1u L=0.18u
Cl2889 s2889 0 10f
Mn2890 s2890 s2889 0 0 nch W=0.5u L=0.18u
Mp2890 s2890 s2889 vdd vdd pch W=1u L=0.18u
Cl2890 s2890 0 10f
Mn2891 s2891 s2890 0 0 nch W=0.5u L=0.18u
Mp2891 s2891 s2890 vdd vdd pch W=1u L=0.18u
Cl2891 s2891 0 10f
Mn2892 s2892 s2891 0 0 nch W=0.5u L=0.18u
Mp2892 s2892 s2891 vdd vdd pch W=1u L=0.18u
Cl2892 s2892 0 10f
Mn2893 s2893 s2892 0 0 nch W=0.5u L=0.18u
Mp2893 s2893 s2892 vdd vdd pch W=1u L=0.18u
Cl2893 s2893 0 10f
Mn2894 s2894 s2893 0 0 nch W=0.5u L=0.18u
Mp2894 s2894 s2893 vdd vdd pch W=1u L=0.18u
Cl2894 s2894 0 10f
Mn2895 s2895 s2894 0 0 nch W=0.5u L=0.18u
Mp2895 s2895 s2894 vdd vdd pch W=1u L=0.18u
Cl2895 s2895 0 10f
Mn2896 s2896 s2895 0 0 nch W=0.5u L=0.18u
Mp2896 s2896 s2895 vdd vdd pch W=1u L=0.18u
Cl2896 s2896 0 10f
Mn2897 s2897 s2896 0 0 nch W=0.5u L=0.18u
Mp2897 s2897 s2896 vdd vdd pch W=1u L=0.18u
Cl2897 s2897 0 10f
Mn2898 s2898 s2897 0 0 nch W=0.5u L=0.18u
Mp2898 s2898 s2897 vdd vdd pch W=1u L=0.18u
Cl2898 s2898 0 10f
Mn2899 s2899 s2898 0 0 nch W=0.5u L=0.18u
Mp2899 s2899 s2898 vdd vdd pch W=1u L=0.18u
Cl2899 s2899 0 10f
Mn2900 s2900 s2899 0 0 nch W=0.5u L=0.18u
Mp2900 s2900 s2899 vdd vdd pch W=1u L=0.18u
Cl2900 s2900 0 10f
Mn2901 s2901 s2900 0 0 nch W=0.5u L=0.18u
Mp2901 s2901 s2900 vdd vdd pch W=1u L=0.18u
Cl2901 s2901 0 10f
Mn2902 s2902 s2901 0 0 nch W=0.5u L=0.18u
Mp2902 s2902 s2901 vdd vdd pch W=1u L=0.18u
Cl2902 s2902 0 10f
Mn2903 s2903 s2902 0 0 nch W=0.5u L=0.18u
Mp2903 s2903 s2902 vdd vdd pch W=1u L=0.18u
Cl2903 s2903 0 10f
Mn2904 s2904 s2903 0 0 nch W=0.5u L=0.18u
Mp2904 s2904 s2903 vdd vdd pch W=1u L=0.18u
Cl2904 s2904 0 10f
Mn2905 s2905 s2904 0 0 nch W=0.5u L=0.18u
Mp2905 s2905 s2904 vdd vdd pch W=1u L=0.18u
Cl2905 s2905 0 10f
Mn2906 s2906 s2905 0 0 nch W=0.5u L=0.18u
Mp2906 s2906 s2905 vdd vdd pch W=1u L=0.18u
Cl2906 s2906 0 10f
Mn2907 s2907 s2906 0 0 nch W=0.5u L=0.18u
Mp2907 s2907 s2906 vdd vdd pch W=1u L=0.18u
Cl2907 s2907 0 10f
Mn2908 s2908 s2907 0 0 nch W=0.5u L=0.18u
Mp2908 s2908 s2907 vdd vdd pch W=1u L=0.18u
Cl2908 s2908 0 10f
Mn2909 s2909 s2908 0 0 nch W=0.5u L=0.18u
Mp2909 s2909 s2908 vdd vdd pch W=1u L=0.18u
Cl2909 s2909 0 10f
Mn2910 s2910 s2909 0 0 nch W=0.5u L=0.18u
Mp2910 s2910 s2909 vdd vdd pch W=1u L=0.18u
Cl2910 s2910 0 10f
Mn2911 s2911 s2910 0 0 nch W=0.5u L=0.18u
Mp2911 s2911 s2910 vdd vdd pch W=1u L=0.18u
Cl2911 s2911 0 10f
Mn2912 s2912 s2911 0 0 nch W=0.5u L=0.18u
Mp2912 s2912 s2911 vdd vdd pch W=1u L=0.18u
Cl2912 s2912 0 10f
Mn2913 s2913 s2912 0 0 nch W=0.5u L=0.18u
Mp2913 s2913 s2912 vdd vdd pch W=1u L=0.18u
Cl2913 s2913 0 10f
Mn2914 s2914 s2913 0 0 nch W=0.5u L=0.18u
Mp2914 s2914 s2913 vdd vdd pch W=1u L=0.18u
Cl2914 s2914 0 10f
Mn2915 s2915 s2914 0 0 nch W=0.5u L=0.18u
Mp2915 s2915 s2914 vdd vdd pch W=1u L=0.18u
Cl2915 s2915 0 10f
Mn2916 s2916 s2915 0 0 nch W=0.5u L=0.18u
Mp2916 s2916 s2915 vdd vdd pch W=1u L=0.18u
Cl2916 s2916 0 10f
Mn2917 s2917 s2916 0 0 nch W=0.5u L=0.18u
Mp2917 s2917 s2916 vdd vdd pch W=1u L=0.18u
Cl2917 s2917 0 10f
Mn2918 s2918 s2917 0 0 nch W=0.5u L=0.18u
Mp2918 s2918 s2917 vdd vdd pch W=1u L=0.18u
Cl2918 s2918 0 10f
Mn2919 s2919 s2918 0 0 nch W=0.5u L=0.18u
Mp2919 s2919 s2918 vdd vdd pch W=1u L=0.18u
Cl2919 s2919 0 10f
Mn2920 s2920 s2919 0 0 nch W=0.5u L=0.18u
Mp2920 s2920 s2919 vdd vdd pch W=1u L=0.18u
Cl2920 s2920 0 10f
Mn2921 s2921 s2920 0 0 nch W=0.5u L=0.18u
Mp2921 s2921 s2920 vdd vdd pch W=1u L=0.18u
Cl2921 s2921 0 10f
Mn2922 s2922 s2921 0 0 nch W=0.5u L=0.18u
Mp2922 s2922 s2921 vdd vdd pch W=1u L=0.18u
Cl2922 s2922 0 10f
Mn2923 s2923 s2922 0 0 nch W=0.5u L=0.18u
Mp2923 s2923 s2922 vdd vdd pch W=1u L=0.18u
Cl2923 s2923 0 10f
Mn2924 s2924 s2923 0 0 nch W=0.5u L=0.18u
Mp2924 s2924 s2923 vdd vdd pch W=1u L=0.18u
Cl2924 s2924 0 10f
Mn2925 s2925 s2924 0 0 nch W=0.5u L=0.18u
Mp2925 s2925 s2924 vdd vdd pch W=1u L=0.18u
Cl2925 s2925 0 10f
Mn2926 s2926 s2925 0 0 nch W=0.5u L=0.18u
Mp2926 s2926 s2925 vdd vdd pch W=1u L=0.18u
Cl2926 s2926 0 10f
Mn2927 s2927 s2926 0 0 nch W=0.5u L=0.18u
Mp2927 s2927 s2926 vdd vdd pch W=1u L=0.18u
Cl2927 s2927 0 10f
Mn2928 s2928 s2927 0 0 nch W=0.5u L=0.18u
Mp2928 s2928 s2927 vdd vdd pch W=1u L=0.18u
Cl2928 s2928 0 10f
Mn2929 s2929 s2928 0 0 nch W=0.5u L=0.18u
Mp2929 s2929 s2928 vdd vdd pch W=1u L=0.18u
Cl2929 s2929 0 10f
Mn2930 s2930 s2929 0 0 nch W=0.5u L=0.18u
Mp2930 s2930 s2929 vdd vdd pch W=1u L=0.18u
Cl2930 s2930 0 10f
Mn2931 s2931 s2930 0 0 nch W=0.5u L=0.18u
Mp2931 s2931 s2930 vdd vdd pch W=1u L=0.18u
Cl2931 s2931 0 10f
Mn2932 s2932 s2931 0 0 nch W=0.5u L=0.18u
Mp2932 s2932 s2931 vdd vdd pch W=1u L=0.18u
Cl2932 s2932 0 10f
Mn2933 s2933 s2932 0 0 nch W=0.5u L=0.18u
Mp2933 s2933 s2932 vdd vdd pch W=1u L=0.18u
Cl2933 s2933 0 10f
Mn2934 s2934 s2933 0 0 nch W=0.5u L=0.18u
Mp2934 s2934 s2933 vdd vdd pch W=1u L=0.18u
Cl2934 s2934 0 10f
Mn2935 s2935 s2934 0 0 nch W=0.5u L=0.18u
Mp2935 s2935 s2934 vdd vdd pch W=1u L=0.18u
Cl2935 s2935 0 10f
Mn2936 s2936 s2935 0 0 nch W=0.5u L=0.18u
Mp2936 s2936 s2935 vdd vdd pch W=1u L=0.18u
Cl2936 s2936 0 10f
Mn2937 s2937 s2936 0 0 nch W=0.5u L=0.18u
Mp2937 s2937 s2936 vdd vdd pch W=1u L=0.18u
Cl2937 s2937 0 10f
Mn2938 s2938 s2937 0 0 nch W=0.5u L=0.18u
Mp2938 s2938 s2937 vdd vdd pch W=1u L=0.18u
Cl2938 s2938 0 10f
Mn2939 s2939 s2938 0 0 nch W=0.5u L=0.18u
Mp2939 s2939 s2938 vdd vdd pch W=1u L=0.18u
Cl2939 s2939 0 10f
Mn2940 s2940 s2939 0 0 nch W=0.5u L=0.18u
Mp2940 s2940 s2939 vdd vdd pch W=1u L=0.18u
Cl2940 s2940 0 10f
Mn2941 s2941 s2940 0 0 nch W=0.5u L=0.18u
Mp2941 s2941 s2940 vdd vdd pch W=1u L=0.18u
Cl2941 s2941 0 10f
Mn2942 s2942 s2941 0 0 nch W=0.5u L=0.18u
Mp2942 s2942 s2941 vdd vdd pch W=1u L=0.18u
Cl2942 s2942 0 10f
Mn2943 s2943 s2942 0 0 nch W=0.5u L=0.18u
Mp2943 s2943 s2942 vdd vdd pch W=1u L=0.18u
Cl2943 s2943 0 10f
Mn2944 s2944 s2943 0 0 nch W=0.5u L=0.18u
Mp2944 s2944 s2943 vdd vdd pch W=1u L=0.18u
Cl2944 s2944 0 10f
Mn2945 s2945 s2944 0 0 nch W=0.5u L=0.18u
Mp2945 s2945 s2944 vdd vdd pch W=1u L=0.18u
Cl2945 s2945 0 10f
Mn2946 s2946 s2945 0 0 nch W=0.5u L=0.18u
Mp2946 s2946 s2945 vdd vdd pch W=1u L=0.18u
Cl2946 s2946 0 10f
Mn2947 s2947 s2946 0 0 nch W=0.5u L=0.18u
Mp2947 s2947 s2946 vdd vdd pch W=1u L=0.18u
Cl2947 s2947 0 10f
Mn2948 s2948 s2947 0 0 nch W=0.5u L=0.18u
Mp2948 s2948 s2947 vdd vdd pch W=1u L=0.18u
Cl2948 s2948 0 10f
Mn2949 s2949 s2948 0 0 nch W=0.5u L=0.18u
Mp2949 s2949 s2948 vdd vdd pch W=1u L=0.18u
Cl2949 s2949 0 10f
Mn2950 s2950 s2949 0 0 nch W=0.5u L=0.18u
Mp2950 s2950 s2949 vdd vdd pch W=1u L=0.18u
Cl2950 s2950 0 10f
Mn2951 s2951 s2950 0 0 nch W=0.5u L=0.18u
Mp2951 s2951 s2950 vdd vdd pch W=1u L=0.18u
Cl2951 s2951 0 10f
Mn2952 s2952 s2951 0 0 nch W=0.5u L=0.18u
Mp2952 s2952 s2951 vdd vdd pch W=1u L=0.18u
Cl2952 s2952 0 10f
Mn2953 s2953 s2952 0 0 nch W=0.5u L=0.18u
Mp2953 s2953 s2952 vdd vdd pch W=1u L=0.18u
Cl2953 s2953 0 10f
Mn2954 s2954 s2953 0 0 nch W=0.5u L=0.18u
Mp2954 s2954 s2953 vdd vdd pch W=1u L=0.18u
Cl2954 s2954 0 10f
Mn2955 s2955 s2954 0 0 nch W=0.5u L=0.18u
Mp2955 s2955 s2954 vdd vdd pch W=1u L=0.18u
Cl2955 s2955 0 10f
Mn2956 s2956 s2955 0 0 nch W=0.5u L=0.18u
Mp2956 s2956 s2955 vdd vdd pch W=1u L=0.18u
Cl2956 s2956 0 10f
Mn2957 s2957 s2956 0 0 nch W=0.5u L=0.18u
Mp2957 s2957 s2956 vdd vdd pch W=1u L=0.18u
Cl2957 s2957 0 10f
Mn2958 s2958 s2957 0 0 nch W=0.5u L=0.18u
Mp2958 s2958 s2957 vdd vdd pch W=1u L=0.18u
Cl2958 s2958 0 10f
Mn2959 s2959 s2958 0 0 nch W=0.5u L=0.18u
Mp2959 s2959 s2958 vdd vdd pch W=1u L=0.18u
Cl2959 s2959 0 10f
Mn2960 s2960 s2959 0 0 nch W=0.5u L=0.18u
Mp2960 s2960 s2959 vdd vdd pch W=1u L=0.18u
Cl2960 s2960 0 10f
Mn2961 s2961 s2960 0 0 nch W=0.5u L=0.18u
Mp2961 s2961 s2960 vdd vdd pch W=1u L=0.18u
Cl2961 s2961 0 10f
Mn2962 s2962 s2961 0 0 nch W=0.5u L=0.18u
Mp2962 s2962 s2961 vdd vdd pch W=1u L=0.18u
Cl2962 s2962 0 10f
Mn2963 s2963 s2962 0 0 nch W=0.5u L=0.18u
Mp2963 s2963 s2962 vdd vdd pch W=1u L=0.18u
Cl2963 s2963 0 10f
Mn2964 s2964 s2963 0 0 nch W=0.5u L=0.18u
Mp2964 s2964 s2963 vdd vdd pch W=1u L=0.18u
Cl2964 s2964 0 10f
Mn2965 s2965 s2964 0 0 nch W=0.5u L=0.18u
Mp2965 s2965 s2964 vdd vdd pch W=1u L=0.18u
Cl2965 s2965 0 10f
Mn2966 s2966 s2965 0 0 nch W=0.5u L=0.18u
Mp2966 s2966 s2965 vdd vdd pch W=1u L=0.18u
Cl2966 s2966 0 10f
Mn2967 s2967 s2966 0 0 nch W=0.5u L=0.18u
Mp2967 s2967 s2966 vdd vdd pch W=1u L=0.18u
Cl2967 s2967 0 10f
Mn2968 s2968 s2967 0 0 nch W=0.5u L=0.18u
Mp2968 s2968 s2967 vdd vdd pch W=1u L=0.18u
Cl2968 s2968 0 10f
Mn2969 s2969 s2968 0 0 nch W=0.5u L=0.18u
Mp2969 s2969 s2968 vdd vdd pch W=1u L=0.18u
Cl2969 s2969 0 10f
Mn2970 s2970 s2969 0 0 nch W=0.5u L=0.18u
Mp2970 s2970 s2969 vdd vdd pch W=1u L=0.18u
Cl2970 s2970 0 10f
Mn2971 s2971 s2970 0 0 nch W=0.5u L=0.18u
Mp2971 s2971 s2970 vdd vdd pch W=1u L=0.18u
Cl2971 s2971 0 10f
Mn2972 s2972 s2971 0 0 nch W=0.5u L=0.18u
Mp2972 s2972 s2971 vdd vdd pch W=1u L=0.18u
Cl2972 s2972 0 10f
Mn2973 s2973 s2972 0 0 nch W=0.5u L=0.18u
Mp2973 s2973 s2972 vdd vdd pch W=1u L=0.18u
Cl2973 s2973 0 10f
Mn2974 s2974 s2973 0 0 nch W=0.5u L=0.18u
Mp2974 s2974 s2973 vdd vdd pch W=1u L=0.18u
Cl2974 s2974 0 10f
Mn2975 s2975 s2974 0 0 nch W=0.5u L=0.18u
Mp2975 s2975 s2974 vdd vdd pch W=1u L=0.18u
Cl2975 s2975 0 10f
Mn2976 s2976 s2975 0 0 nch W=0.5u L=0.18u
Mp2976 s2976 s2975 vdd vdd pch W=1u L=0.18u
Cl2976 s2976 0 10f
Mn2977 s2977 s2976 0 0 nch W=0.5u L=0.18u
Mp2977 s2977 s2976 vdd vdd pch W=1u L=0.18u
Cl2977 s2977 0 10f
Mn2978 s2978 s2977 0 0 nch W=0.5u L=0.18u
Mp2978 s2978 s2977 vdd vdd pch W=1u L=0.18u
Cl2978 s2978 0 10f
Mn2979 s2979 s2978 0 0 nch W=0.5u L=0.18u
Mp2979 s2979 s2978 vdd vdd pch W=1u L=0.18u
Cl2979 s2979 0 10f
Mn2980 s2980 s2979 0 0 nch W=0.5u L=0.18u
Mp2980 s2980 s2979 vdd vdd pch W=1u L=0.18u
Cl2980 s2980 0 10f
Mn2981 s2981 s2980 0 0 nch W=0.5u L=0.18u
Mp2981 s2981 s2980 vdd vdd pch W=1u L=0.18u
Cl2981 s2981 0 10f
Mn2982 s2982 s2981 0 0 nch W=0.5u L=0.18u
Mp2982 s2982 s2981 vdd vdd pch W=1u L=0.18u
Cl2982 s2982 0 10f
Mn2983 s2983 s2982 0 0 nch W=0.5u L=0.18u
Mp2983 s2983 s2982 vdd vdd pch W=1u L=0.18u
Cl2983 s2983 0 10f
Mn2984 s2984 s2983 0 0 nch W=0.5u L=0.18u
Mp2984 s2984 s2983 vdd vdd pch W=1u L=0.18u
Cl2984 s2984 0 10f
Mn2985 s2985 s2984 0 0 nch W=0.5u L=0.18u
Mp2985 s2985 s2984 vdd vdd pch W=1u L=0.18u
Cl2985 s2985 0 10f
Mn2986 s2986 s2985 0 0 nch W=0.5u L=0.18u
Mp2986 s2986 s2985 vdd vdd pch W=1u L=0.18u
Cl2986 s2986 0 10f
Mn2987 s2987 s2986 0 0 nch W=0.5u L=0.18u
Mp2987 s2987 s2986 vdd vdd pch W=1u L=0.18u
Cl2987 s2987 0 10f
Mn2988 s2988 s2987 0 0 nch W=0.5u L=0.18u
Mp2988 s2988 s2987 vdd vdd pch W=1u L=0.18u
Cl2988 s2988 0 10f
Mn2989 s2989 s2988 0 0 nch W=0.5u L=0.18u
Mp2989 s2989 s2988 vdd vdd pch W=1u L=0.18u
Cl2989 s2989 0 10f
Mn2990 s2990 s2989 0 0 nch W=0.5u L=0.18u
Mp2990 s2990 s2989 vdd vdd pch W=1u L=0.18u
Cl2990 s2990 0 10f
Mn2991 s2991 s2990 0 0 nch W=0.5u L=0.18u
Mp2991 s2991 s2990 vdd vdd pch W=1u L=0.18u
Cl2991 s2991 0 10f
Mn2992 s2992 s2991 0 0 nch W=0.5u L=0.18u
Mp2992 s2992 s2991 vdd vdd pch W=1u L=0.18u
Cl2992 s2992 0 10f
Mn2993 s2993 s2992 0 0 nch W=0.5u L=0.18u
Mp2993 s2993 s2992 vdd vdd pch W=1u L=0.18u
Cl2993 s2993 0 10f
Mn2994 s2994 s2993 0 0 nch W=0.5u L=0.18u
Mp2994 s2994 s2993 vdd vdd pch W=1u L=0.18u
Cl2994 s2994 0 10f
Mn2995 s2995 s2994 0 0 nch W=0.5u L=0.18u
Mp2995 s2995 s2994 vdd vdd pch W=1u L=0.18u
Cl2995 s2995 0 10f
Mn2996 s2996 s2995 0 0 nch W=0.5u L=0.18u
Mp2996 s2996 s2995 vdd vdd pch W=1u L=0.18u
Cl2996 s2996 0 10f
Mn2997 s2997 s2996 0 0 nch W=0.5u L=0.18u
Mp2997 s2997 s2996 vdd vdd pch W=1u L=0.18u
Cl2997 s2997 0 10f
Mn2998 s2998 s2997 0 0 nch W=0.5u L=0.18u
Mp2998 s2998 s2997 vdd vdd pch W=1u L=0.18u
Cl2998 s2998 0 10f
Mn2999 s2999 s2998 0 0 nch W=0.5u L=0.18u
Mp2999 s2999 s2998 vdd vdd pch W=1u L=0.18u
Cl2999 s2999 0 10f
Mn3000 s3000 s2999 0 0 nch W=0.5u L=0.18u
Mp3000 s3000 s2999 vdd vdd pch W=1u L=0.18u
Cl3000 s3000 0 10f
Mn3001 s3001 s3000 0 0 nch W=0.5u L=0.18u
Mp3001 s3001 s3000 vdd vdd pch W=1u L=0.18u
Cl3001 s3001 0 10f
Mn3002 s3002 s3001 0 0 nch W=0.5u L=0.18u
Mp3002 s3002 s3001 vdd vdd pch W=1u L=0.18u
Cl3002 s3002 0 10f
Mn3003 s3003 s3002 0 0 nch W=0.5u L=0.18u
Mp3003 s3003 s3002 vdd vdd pch W=1u L=0.18u
Cl3003 s3003 0 10f
Mn3004 s3004 s3003 0 0 nch W=0.5u L=0.18u
Mp3004 s3004 s3003 vdd vdd pch W=1u L=0.18u
Cl3004 s3004 0 10f
Mn3005 s3005 s3004 0 0 nch W=0.5u L=0.18u
Mp3005 s3005 s3004 vdd vdd pch W=1u L=0.18u
Cl3005 s3005 0 10f
Mn3006 s3006 s3005 0 0 nch W=0.5u L=0.18u
Mp3006 s3006 s3005 vdd vdd pch W=1u L=0.18u
Cl3006 s3006 0 10f
Mn3007 s3007 s3006 0 0 nch W=0.5u L=0.18u
Mp3007 s3007 s3006 vdd vdd pch W=1u L=0.18u
Cl3007 s3007 0 10f
Mn3008 s3008 s3007 0 0 nch W=0.5u L=0.18u
Mp3008 s3008 s3007 vdd vdd pch W=1u L=0.18u
Cl3008 s3008 0 10f
Mn3009 s3009 s3008 0 0 nch W=0.5u L=0.18u
Mp3009 s3009 s3008 vdd vdd pch W=1u L=0.18u
Cl3009 s3009 0 10f
Mn3010 s3010 s3009 0 0 nch W=0.5u L=0.18u
Mp3010 s3010 s3009 vdd vdd pch W=1u L=0.18u
Cl3010 s3010 0 10f
Mn3011 s3011 s3010 0 0 nch W=0.5u L=0.18u
Mp3011 s3011 s3010 vdd vdd pch W=1u L=0.18u
Cl3011 s3011 0 10f
Mn3012 s3012 s3011 0 0 nch W=0.5u L=0.18u
Mp3012 s3012 s3011 vdd vdd pch W=1u L=0.18u
Cl3012 s3012 0 10f
Mn3013 s3013 s3012 0 0 nch W=0.5u L=0.18u
Mp3013 s3013 s3012 vdd vdd pch W=1u L=0.18u
Cl3013 s3013 0 10f
Mn3014 s3014 s3013 0 0 nch W=0.5u L=0.18u
Mp3014 s3014 s3013 vdd vdd pch W=1u L=0.18u
Cl3014 s3014 0 10f
Mn3015 s3015 s3014 0 0 nch W=0.5u L=0.18u
Mp3015 s3015 s3014 vdd vdd pch W=1u L=0.18u
Cl3015 s3015 0 10f
Mn3016 s3016 s3015 0 0 nch W=0.5u L=0.18u
Mp3016 s3016 s3015 vdd vdd pch W=1u L=0.18u
Cl3016 s3016 0 10f
Mn3017 s3017 s3016 0 0 nch W=0.5u L=0.18u
Mp3017 s3017 s3016 vdd vdd pch W=1u L=0.18u
Cl3017 s3017 0 10f
Mn3018 s3018 s3017 0 0 nch W=0.5u L=0.18u
Mp3018 s3018 s3017 vdd vdd pch W=1u L=0.18u
Cl3018 s3018 0 10f
Mn3019 s3019 s3018 0 0 nch W=0.5u L=0.18u
Mp3019 s3019 s3018 vdd vdd pch W=1u L=0.18u
Cl3019 s3019 0 10f
Mn3020 s3020 s3019 0 0 nch W=0.5u L=0.18u
Mp3020 s3020 s3019 vdd vdd pch W=1u L=0.18u
Cl3020 s3020 0 10f
Mn3021 s3021 s3020 0 0 nch W=0.5u L=0.18u
Mp3021 s3021 s3020 vdd vdd pch W=1u L=0.18u
Cl3021 s3021 0 10f
Mn3022 s3022 s3021 0 0 nch W=0.5u L=0.18u
Mp3022 s3022 s3021 vdd vdd pch W=1u L=0.18u
Cl3022 s3022 0 10f
Mn3023 s3023 s3022 0 0 nch W=0.5u L=0.18u
Mp3023 s3023 s3022 vdd vdd pch W=1u L=0.18u
Cl3023 s3023 0 10f
Mn3024 s3024 s3023 0 0 nch W=0.5u L=0.18u
Mp3024 s3024 s3023 vdd vdd pch W=1u L=0.18u
Cl3024 s3024 0 10f
Mn3025 s3025 s3024 0 0 nch W=0.5u L=0.18u
Mp3025 s3025 s3024 vdd vdd pch W=1u L=0.18u
Cl3025 s3025 0 10f
Mn3026 s3026 s3025 0 0 nch W=0.5u L=0.18u
Mp3026 s3026 s3025 vdd vdd pch W=1u L=0.18u
Cl3026 s3026 0 10f
Mn3027 s3027 s3026 0 0 nch W=0.5u L=0.18u
Mp3027 s3027 s3026 vdd vdd pch W=1u L=0.18u
Cl3027 s3027 0 10f
Mn3028 s3028 s3027 0 0 nch W=0.5u L=0.18u
Mp3028 s3028 s3027 vdd vdd pch W=1u L=0.18u
Cl3028 s3028 0 10f
Mn3029 s3029 s3028 0 0 nch W=0.5u L=0.18u
Mp3029 s3029 s3028 vdd vdd pch W=1u L=0.18u
Cl3029 s3029 0 10f
Mn3030 s3030 s3029 0 0 nch W=0.5u L=0.18u
Mp3030 s3030 s3029 vdd vdd pch W=1u L=0.18u
Cl3030 s3030 0 10f
Mn3031 s3031 s3030 0 0 nch W=0.5u L=0.18u
Mp3031 s3031 s3030 vdd vdd pch W=1u L=0.18u
Cl3031 s3031 0 10f
Mn3032 s3032 s3031 0 0 nch W=0.5u L=0.18u
Mp3032 s3032 s3031 vdd vdd pch W=1u L=0.18u
Cl3032 s3032 0 10f
Mn3033 s3033 s3032 0 0 nch W=0.5u L=0.18u
Mp3033 s3033 s3032 vdd vdd pch W=1u L=0.18u
Cl3033 s3033 0 10f
Mn3034 s3034 s3033 0 0 nch W=0.5u L=0.18u
Mp3034 s3034 s3033 vdd vdd pch W=1u L=0.18u
Cl3034 s3034 0 10f
Mn3035 s3035 s3034 0 0 nch W=0.5u L=0.18u
Mp3035 s3035 s3034 vdd vdd pch W=1u L=0.18u
Cl3035 s3035 0 10f
Mn3036 s3036 s3035 0 0 nch W=0.5u L=0.18u
Mp3036 s3036 s3035 vdd vdd pch W=1u L=0.18u
Cl3036 s3036 0 10f
Mn3037 s3037 s3036 0 0 nch W=0.5u L=0.18u
Mp3037 s3037 s3036 vdd vdd pch W=1u L=0.18u
Cl3037 s3037 0 10f
Mn3038 s3038 s3037 0 0 nch W=0.5u L=0.18u
Mp3038 s3038 s3037 vdd vdd pch W=1u L=0.18u
Cl3038 s3038 0 10f
Mn3039 s3039 s3038 0 0 nch W=0.5u L=0.18u
Mp3039 s3039 s3038 vdd vdd pch W=1u L=0.18u
Cl3039 s3039 0 10f
Mn3040 s3040 s3039 0 0 nch W=0.5u L=0.18u
Mp3040 s3040 s3039 vdd vdd pch W=1u L=0.18u
Cl3040 s3040 0 10f
Mn3041 s3041 s3040 0 0 nch W=0.5u L=0.18u
Mp3041 s3041 s3040 vdd vdd pch W=1u L=0.18u
Cl3041 s3041 0 10f
Mn3042 s3042 s3041 0 0 nch W=0.5u L=0.18u
Mp3042 s3042 s3041 vdd vdd pch W=1u L=0.18u
Cl3042 s3042 0 10f
Mn3043 s3043 s3042 0 0 nch W=0.5u L=0.18u
Mp3043 s3043 s3042 vdd vdd pch W=1u L=0.18u
Cl3043 s3043 0 10f
Mn3044 s3044 s3043 0 0 nch W=0.5u L=0.18u
Mp3044 s3044 s3043 vdd vdd pch W=1u L=0.18u
Cl3044 s3044 0 10f
Mn3045 s3045 s3044 0 0 nch W=0.5u L=0.18u
Mp3045 s3045 s3044 vdd vdd pch W=1u L=0.18u
Cl3045 s3045 0 10f
Mn3046 s3046 s3045 0 0 nch W=0.5u L=0.18u
Mp3046 s3046 s3045 vdd vdd pch W=1u L=0.18u
Cl3046 s3046 0 10f
Mn3047 s3047 s3046 0 0 nch W=0.5u L=0.18u
Mp3047 s3047 s3046 vdd vdd pch W=1u L=0.18u
Cl3047 s3047 0 10f
Mn3048 s3048 s3047 0 0 nch W=0.5u L=0.18u
Mp3048 s3048 s3047 vdd vdd pch W=1u L=0.18u
Cl3048 s3048 0 10f
Mn3049 s3049 s3048 0 0 nch W=0.5u L=0.18u
Mp3049 s3049 s3048 vdd vdd pch W=1u L=0.18u
Cl3049 s3049 0 10f
Mn3050 s3050 s3049 0 0 nch W=0.5u L=0.18u
Mp3050 s3050 s3049 vdd vdd pch W=1u L=0.18u
Cl3050 s3050 0 10f
Mn3051 s3051 s3050 0 0 nch W=0.5u L=0.18u
Mp3051 s3051 s3050 vdd vdd pch W=1u L=0.18u
Cl3051 s3051 0 10f
Mn3052 s3052 s3051 0 0 nch W=0.5u L=0.18u
Mp3052 s3052 s3051 vdd vdd pch W=1u L=0.18u
Cl3052 s3052 0 10f
Mn3053 s3053 s3052 0 0 nch W=0.5u L=0.18u
Mp3053 s3053 s3052 vdd vdd pch W=1u L=0.18u
Cl3053 s3053 0 10f
Mn3054 s3054 s3053 0 0 nch W=0.5u L=0.18u
Mp3054 s3054 s3053 vdd vdd pch W=1u L=0.18u
Cl3054 s3054 0 10f
Mn3055 s3055 s3054 0 0 nch W=0.5u L=0.18u
Mp3055 s3055 s3054 vdd vdd pch W=1u L=0.18u
Cl3055 s3055 0 10f
Mn3056 s3056 s3055 0 0 nch W=0.5u L=0.18u
Mp3056 s3056 s3055 vdd vdd pch W=1u L=0.18u
Cl3056 s3056 0 10f
Mn3057 s3057 s3056 0 0 nch W=0.5u L=0.18u
Mp3057 s3057 s3056 vdd vdd pch W=1u L=0.18u
Cl3057 s3057 0 10f
Mn3058 s3058 s3057 0 0 nch W=0.5u L=0.18u
Mp3058 s3058 s3057 vdd vdd pch W=1u L=0.18u
Cl3058 s3058 0 10f
Mn3059 s3059 s3058 0 0 nch W=0.5u L=0.18u
Mp3059 s3059 s3058 vdd vdd pch W=1u L=0.18u
Cl3059 s3059 0 10f
Mn3060 s3060 s3059 0 0 nch W=0.5u L=0.18u
Mp3060 s3060 s3059 vdd vdd pch W=1u L=0.18u
Cl3060 s3060 0 10f
Mn3061 s3061 s3060 0 0 nch W=0.5u L=0.18u
Mp3061 s3061 s3060 vdd vdd pch W=1u L=0.18u
Cl3061 s3061 0 10f
Mn3062 s3062 s3061 0 0 nch W=0.5u L=0.18u
Mp3062 s3062 s3061 vdd vdd pch W=1u L=0.18u
Cl3062 s3062 0 10f
Mn3063 s3063 s3062 0 0 nch W=0.5u L=0.18u
Mp3063 s3063 s3062 vdd vdd pch W=1u L=0.18u
Cl3063 s3063 0 10f
Mn3064 s3064 s3063 0 0 nch W=0.5u L=0.18u
Mp3064 s3064 s3063 vdd vdd pch W=1u L=0.18u
Cl3064 s3064 0 10f
Mn3065 s3065 s3064 0 0 nch W=0.5u L=0.18u
Mp3065 s3065 s3064 vdd vdd pch W=1u L=0.18u
Cl3065 s3065 0 10f
Mn3066 s3066 s3065 0 0 nch W=0.5u L=0.18u
Mp3066 s3066 s3065 vdd vdd pch W=1u L=0.18u
Cl3066 s3066 0 10f
Mn3067 s3067 s3066 0 0 nch W=0.5u L=0.18u
Mp3067 s3067 s3066 vdd vdd pch W=1u L=0.18u
Cl3067 s3067 0 10f
Mn3068 s3068 s3067 0 0 nch W=0.5u L=0.18u
Mp3068 s3068 s3067 vdd vdd pch W=1u L=0.18u
Cl3068 s3068 0 10f
Mn3069 s3069 s3068 0 0 nch W=0.5u L=0.18u
Mp3069 s3069 s3068 vdd vdd pch W=1u L=0.18u
Cl3069 s3069 0 10f
Mn3070 s3070 s3069 0 0 nch W=0.5u L=0.18u
Mp3070 s3070 s3069 vdd vdd pch W=1u L=0.18u
Cl3070 s3070 0 10f
Mn3071 s3071 s3070 0 0 nch W=0.5u L=0.18u
Mp3071 s3071 s3070 vdd vdd pch W=1u L=0.18u
Cl3071 s3071 0 10f
Mn3072 s3072 s3071 0 0 nch W=0.5u L=0.18u
Mp3072 s3072 s3071 vdd vdd pch W=1u L=0.18u
Cl3072 s3072 0 10f
Mn3073 s3073 s3072 0 0 nch W=0.5u L=0.18u
Mp3073 s3073 s3072 vdd vdd pch W=1u L=0.18u
Cl3073 s3073 0 10f
Mn3074 s3074 s3073 0 0 nch W=0.5u L=0.18u
Mp3074 s3074 s3073 vdd vdd pch W=1u L=0.18u
Cl3074 s3074 0 10f
Mn3075 s3075 s3074 0 0 nch W=0.5u L=0.18u
Mp3075 s3075 s3074 vdd vdd pch W=1u L=0.18u
Cl3075 s3075 0 10f
Mn3076 s3076 s3075 0 0 nch W=0.5u L=0.18u
Mp3076 s3076 s3075 vdd vdd pch W=1u L=0.18u
Cl3076 s3076 0 10f
Mn3077 s3077 s3076 0 0 nch W=0.5u L=0.18u
Mp3077 s3077 s3076 vdd vdd pch W=1u L=0.18u
Cl3077 s3077 0 10f
Mn3078 s3078 s3077 0 0 nch W=0.5u L=0.18u
Mp3078 s3078 s3077 vdd vdd pch W=1u L=0.18u
Cl3078 s3078 0 10f
Mn3079 s3079 s3078 0 0 nch W=0.5u L=0.18u
Mp3079 s3079 s3078 vdd vdd pch W=1u L=0.18u
Cl3079 s3079 0 10f
Mn3080 s3080 s3079 0 0 nch W=0.5u L=0.18u
Mp3080 s3080 s3079 vdd vdd pch W=1u L=0.18u
Cl3080 s3080 0 10f
Mn3081 s3081 s3080 0 0 nch W=0.5u L=0.18u
Mp3081 s3081 s3080 vdd vdd pch W=1u L=0.18u
Cl3081 s3081 0 10f
Mn3082 s3082 s3081 0 0 nch W=0.5u L=0.18u
Mp3082 s3082 s3081 vdd vdd pch W=1u L=0.18u
Cl3082 s3082 0 10f
Mn3083 s3083 s3082 0 0 nch W=0.5u L=0.18u
Mp3083 s3083 s3082 vdd vdd pch W=1u L=0.18u
Cl3083 s3083 0 10f
Mn3084 s3084 s3083 0 0 nch W=0.5u L=0.18u
Mp3084 s3084 s3083 vdd vdd pch W=1u L=0.18u
Cl3084 s3084 0 10f
Mn3085 s3085 s3084 0 0 nch W=0.5u L=0.18u
Mp3085 s3085 s3084 vdd vdd pch W=1u L=0.18u
Cl3085 s3085 0 10f
Mn3086 s3086 s3085 0 0 nch W=0.5u L=0.18u
Mp3086 s3086 s3085 vdd vdd pch W=1u L=0.18u
Cl3086 s3086 0 10f
Mn3087 s3087 s3086 0 0 nch W=0.5u L=0.18u
Mp3087 s3087 s3086 vdd vdd pch W=1u L=0.18u
Cl3087 s3087 0 10f
Mn3088 s3088 s3087 0 0 nch W=0.5u L=0.18u
Mp3088 s3088 s3087 vdd vdd pch W=1u L=0.18u
Cl3088 s3088 0 10f
Mn3089 s3089 s3088 0 0 nch W=0.5u L=0.18u
Mp3089 s3089 s3088 vdd vdd pch W=1u L=0.18u
Cl3089 s3089 0 10f
Mn3090 s3090 s3089 0 0 nch W=0.5u L=0.18u
Mp3090 s3090 s3089 vdd vdd pch W=1u L=0.18u
Cl3090 s3090 0 10f
Mn3091 s3091 s3090 0 0 nch W=0.5u L=0.18u
Mp3091 s3091 s3090 vdd vdd pch W=1u L=0.18u
Cl3091 s3091 0 10f
Mn3092 s3092 s3091 0 0 nch W=0.5u L=0.18u
Mp3092 s3092 s3091 vdd vdd pch W=1u L=0.18u
Cl3092 s3092 0 10f
Mn3093 s3093 s3092 0 0 nch W=0.5u L=0.18u
Mp3093 s3093 s3092 vdd vdd pch W=1u L=0.18u
Cl3093 s3093 0 10f
Mn3094 s3094 s3093 0 0 nch W=0.5u L=0.18u
Mp3094 s3094 s3093 vdd vdd pch W=1u L=0.18u
Cl3094 s3094 0 10f
Mn3095 s3095 s3094 0 0 nch W=0.5u L=0.18u
Mp3095 s3095 s3094 vdd vdd pch W=1u L=0.18u
Cl3095 s3095 0 10f
Mn3096 s3096 s3095 0 0 nch W=0.5u L=0.18u
Mp3096 s3096 s3095 vdd vdd pch W=1u L=0.18u
Cl3096 s3096 0 10f
Mn3097 s3097 s3096 0 0 nch W=0.5u L=0.18u
Mp3097 s3097 s3096 vdd vdd pch W=1u L=0.18u
Cl3097 s3097 0 10f
Mn3098 s3098 s3097 0 0 nch W=0.5u L=0.18u
Mp3098 s3098 s3097 vdd vdd pch W=1u L=0.18u
Cl3098 s3098 0 10f
Mn3099 s3099 s3098 0 0 nch W=0.5u L=0.18u
Mp3099 s3099 s3098 vdd vdd pch W=1u L=0.18u
Cl3099 s3099 0 10f
Mn3100 s3100 s3099 0 0 nch W=0.5u L=0.18u
Mp3100 s3100 s3099 vdd vdd pch W=1u L=0.18u
Cl3100 s3100 0 10f
Mn3101 s3101 s3100 0 0 nch W=0.5u L=0.18u
Mp3101 s3101 s3100 vdd vdd pch W=1u L=0.18u
Cl3101 s3101 0 10f
Mn3102 s3102 s3101 0 0 nch W=0.5u L=0.18u
Mp3102 s3102 s3101 vdd vdd pch W=1u L=0.18u
Cl3102 s3102 0 10f
Mn3103 s3103 s3102 0 0 nch W=0.5u L=0.18u
Mp3103 s3103 s3102 vdd vdd pch W=1u L=0.18u
Cl3103 s3103 0 10f
Mn3104 s3104 s3103 0 0 nch W=0.5u L=0.18u
Mp3104 s3104 s3103 vdd vdd pch W=1u L=0.18u
Cl3104 s3104 0 10f
Mn3105 s3105 s3104 0 0 nch W=0.5u L=0.18u
Mp3105 s3105 s3104 vdd vdd pch W=1u L=0.18u
Cl3105 s3105 0 10f
Mn3106 s3106 s3105 0 0 nch W=0.5u L=0.18u
Mp3106 s3106 s3105 vdd vdd pch W=1u L=0.18u
Cl3106 s3106 0 10f
Mn3107 s3107 s3106 0 0 nch W=0.5u L=0.18u
Mp3107 s3107 s3106 vdd vdd pch W=1u L=0.18u
Cl3107 s3107 0 10f
Mn3108 s3108 s3107 0 0 nch W=0.5u L=0.18u
Mp3108 s3108 s3107 vdd vdd pch W=1u L=0.18u
Cl3108 s3108 0 10f
Mn3109 s3109 s3108 0 0 nch W=0.5u L=0.18u
Mp3109 s3109 s3108 vdd vdd pch W=1u L=0.18u
Cl3109 s3109 0 10f
Mn3110 s3110 s3109 0 0 nch W=0.5u L=0.18u
Mp3110 s3110 s3109 vdd vdd pch W=1u L=0.18u
Cl3110 s3110 0 10f
Mn3111 s3111 s3110 0 0 nch W=0.5u L=0.18u
Mp3111 s3111 s3110 vdd vdd pch W=1u L=0.18u
Cl3111 s3111 0 10f
Mn3112 s3112 s3111 0 0 nch W=0.5u L=0.18u
Mp3112 s3112 s3111 vdd vdd pch W=1u L=0.18u
Cl3112 s3112 0 10f
Mn3113 s3113 s3112 0 0 nch W=0.5u L=0.18u
Mp3113 s3113 s3112 vdd vdd pch W=1u L=0.18u
Cl3113 s3113 0 10f
Mn3114 s3114 s3113 0 0 nch W=0.5u L=0.18u
Mp3114 s3114 s3113 vdd vdd pch W=1u L=0.18u
Cl3114 s3114 0 10f
Mn3115 s3115 s3114 0 0 nch W=0.5u L=0.18u
Mp3115 s3115 s3114 vdd vdd pch W=1u L=0.18u
Cl3115 s3115 0 10f
Mn3116 s3116 s3115 0 0 nch W=0.5u L=0.18u
Mp3116 s3116 s3115 vdd vdd pch W=1u L=0.18u
Cl3116 s3116 0 10f
Mn3117 s3117 s3116 0 0 nch W=0.5u L=0.18u
Mp3117 s3117 s3116 vdd vdd pch W=1u L=0.18u
Cl3117 s3117 0 10f
Mn3118 s3118 s3117 0 0 nch W=0.5u L=0.18u
Mp3118 s3118 s3117 vdd vdd pch W=1u L=0.18u
Cl3118 s3118 0 10f
Mn3119 s3119 s3118 0 0 nch W=0.5u L=0.18u
Mp3119 s3119 s3118 vdd vdd pch W=1u L=0.18u
Cl3119 s3119 0 10f
Mn3120 s3120 s3119 0 0 nch W=0.5u L=0.18u
Mp3120 s3120 s3119 vdd vdd pch W=1u L=0.18u
Cl3120 s3120 0 10f
Mn3121 s3121 s3120 0 0 nch W=0.5u L=0.18u
Mp3121 s3121 s3120 vdd vdd pch W=1u L=0.18u
Cl3121 s3121 0 10f
Mn3122 s3122 s3121 0 0 nch W=0.5u L=0.18u
Mp3122 s3122 s3121 vdd vdd pch W=1u L=0.18u
Cl3122 s3122 0 10f
Mn3123 s3123 s3122 0 0 nch W=0.5u L=0.18u
Mp3123 s3123 s3122 vdd vdd pch W=1u L=0.18u
Cl3123 s3123 0 10f
Mn3124 s3124 s3123 0 0 nch W=0.5u L=0.18u
Mp3124 s3124 s3123 vdd vdd pch W=1u L=0.18u
Cl3124 s3124 0 10f
Mn3125 s3125 s3124 0 0 nch W=0.5u L=0.18u
Mp3125 s3125 s3124 vdd vdd pch W=1u L=0.18u
Cl3125 s3125 0 10f
Mn3126 s3126 s3125 0 0 nch W=0.5u L=0.18u
Mp3126 s3126 s3125 vdd vdd pch W=1u L=0.18u
Cl3126 s3126 0 10f
Mn3127 s3127 s3126 0 0 nch W=0.5u L=0.18u
Mp3127 s3127 s3126 vdd vdd pch W=1u L=0.18u
Cl3127 s3127 0 10f
Mn3128 s3128 s3127 0 0 nch W=0.5u L=0.18u
Mp3128 s3128 s3127 vdd vdd pch W=1u L=0.18u
Cl3128 s3128 0 10f
Mn3129 s3129 s3128 0 0 nch W=0.5u L=0.18u
Mp3129 s3129 s3128 vdd vdd pch W=1u L=0.18u
Cl3129 s3129 0 10f
Mn3130 s3130 s3129 0 0 nch W=0.5u L=0.18u
Mp3130 s3130 s3129 vdd vdd pch W=1u L=0.18u
Cl3130 s3130 0 10f
Mn3131 s3131 s3130 0 0 nch W=0.5u L=0.18u
Mp3131 s3131 s3130 vdd vdd pch W=1u L=0.18u
Cl3131 s3131 0 10f
Mn3132 s3132 s3131 0 0 nch W=0.5u L=0.18u
Mp3132 s3132 s3131 vdd vdd pch W=1u L=0.18u
Cl3132 s3132 0 10f
Mn3133 s3133 s3132 0 0 nch W=0.5u L=0.18u
Mp3133 s3133 s3132 vdd vdd pch W=1u L=0.18u
Cl3133 s3133 0 10f
Mn3134 s3134 s3133 0 0 nch W=0.5u L=0.18u
Mp3134 s3134 s3133 vdd vdd pch W=1u L=0.18u
Cl3134 s3134 0 10f
Mn3135 s3135 s3134 0 0 nch W=0.5u L=0.18u
Mp3135 s3135 s3134 vdd vdd pch W=1u L=0.18u
Cl3135 s3135 0 10f
Mn3136 s3136 s3135 0 0 nch W=0.5u L=0.18u
Mp3136 s3136 s3135 vdd vdd pch W=1u L=0.18u
Cl3136 s3136 0 10f
Mn3137 s3137 s3136 0 0 nch W=0.5u L=0.18u
Mp3137 s3137 s3136 vdd vdd pch W=1u L=0.18u
Cl3137 s3137 0 10f
Mn3138 s3138 s3137 0 0 nch W=0.5u L=0.18u
Mp3138 s3138 s3137 vdd vdd pch W=1u L=0.18u
Cl3138 s3138 0 10f
Mn3139 s3139 s3138 0 0 nch W=0.5u L=0.18u
Mp3139 s3139 s3138 vdd vdd pch W=1u L=0.18u
Cl3139 s3139 0 10f
Mn3140 s3140 s3139 0 0 nch W=0.5u L=0.18u
Mp3140 s3140 s3139 vdd vdd pch W=1u L=0.18u
Cl3140 s3140 0 10f
Mn3141 s3141 s3140 0 0 nch W=0.5u L=0.18u
Mp3141 s3141 s3140 vdd vdd pch W=1u L=0.18u
Cl3141 s3141 0 10f
Mn3142 s3142 s3141 0 0 nch W=0.5u L=0.18u
Mp3142 s3142 s3141 vdd vdd pch W=1u L=0.18u
Cl3142 s3142 0 10f
Mn3143 s3143 s3142 0 0 nch W=0.5u L=0.18u
Mp3143 s3143 s3142 vdd vdd pch W=1u L=0.18u
Cl3143 s3143 0 10f
Mn3144 s3144 s3143 0 0 nch W=0.5u L=0.18u
Mp3144 s3144 s3143 vdd vdd pch W=1u L=0.18u
Cl3144 s3144 0 10f
Mn3145 s3145 s3144 0 0 nch W=0.5u L=0.18u
Mp3145 s3145 s3144 vdd vdd pch W=1u L=0.18u
Cl3145 s3145 0 10f
Mn3146 s3146 s3145 0 0 nch W=0.5u L=0.18u
Mp3146 s3146 s3145 vdd vdd pch W=1u L=0.18u
Cl3146 s3146 0 10f
Mn3147 s3147 s3146 0 0 nch W=0.5u L=0.18u
Mp3147 s3147 s3146 vdd vdd pch W=1u L=0.18u
Cl3147 s3147 0 10f
Mn3148 s3148 s3147 0 0 nch W=0.5u L=0.18u
Mp3148 s3148 s3147 vdd vdd pch W=1u L=0.18u
Cl3148 s3148 0 10f
Mn3149 s3149 s3148 0 0 nch W=0.5u L=0.18u
Mp3149 s3149 s3148 vdd vdd pch W=1u L=0.18u
Cl3149 s3149 0 10f
Mn3150 s3150 s3149 0 0 nch W=0.5u L=0.18u
Mp3150 s3150 s3149 vdd vdd pch W=1u L=0.18u
Cl3150 s3150 0 10f
Mn3151 s3151 s3150 0 0 nch W=0.5u L=0.18u
Mp3151 s3151 s3150 vdd vdd pch W=1u L=0.18u
Cl3151 s3151 0 10f
Mn3152 s3152 s3151 0 0 nch W=0.5u L=0.18u
Mp3152 s3152 s3151 vdd vdd pch W=1u L=0.18u
Cl3152 s3152 0 10f
Mn3153 s3153 s3152 0 0 nch W=0.5u L=0.18u
Mp3153 s3153 s3152 vdd vdd pch W=1u L=0.18u
Cl3153 s3153 0 10f
Mn3154 s3154 s3153 0 0 nch W=0.5u L=0.18u
Mp3154 s3154 s3153 vdd vdd pch W=1u L=0.18u
Cl3154 s3154 0 10f
Mn3155 s3155 s3154 0 0 nch W=0.5u L=0.18u
Mp3155 s3155 s3154 vdd vdd pch W=1u L=0.18u
Cl3155 s3155 0 10f
Mn3156 s3156 s3155 0 0 nch W=0.5u L=0.18u
Mp3156 s3156 s3155 vdd vdd pch W=1u L=0.18u
Cl3156 s3156 0 10f
Mn3157 s3157 s3156 0 0 nch W=0.5u L=0.18u
Mp3157 s3157 s3156 vdd vdd pch W=1u L=0.18u
Cl3157 s3157 0 10f
Mn3158 s3158 s3157 0 0 nch W=0.5u L=0.18u
Mp3158 s3158 s3157 vdd vdd pch W=1u L=0.18u
Cl3158 s3158 0 10f
Mn3159 s3159 s3158 0 0 nch W=0.5u L=0.18u
Mp3159 s3159 s3158 vdd vdd pch W=1u L=0.18u
Cl3159 s3159 0 10f
Mn3160 s3160 s3159 0 0 nch W=0.5u L=0.18u
Mp3160 s3160 s3159 vdd vdd pch W=1u L=0.18u
Cl3160 s3160 0 10f
Mn3161 s3161 s3160 0 0 nch W=0.5u L=0.18u
Mp3161 s3161 s3160 vdd vdd pch W=1u L=0.18u
Cl3161 s3161 0 10f
Mn3162 s3162 s3161 0 0 nch W=0.5u L=0.18u
Mp3162 s3162 s3161 vdd vdd pch W=1u L=0.18u
Cl3162 s3162 0 10f
Mn3163 s3163 s3162 0 0 nch W=0.5u L=0.18u
Mp3163 s3163 s3162 vdd vdd pch W=1u L=0.18u
Cl3163 s3163 0 10f
Mn3164 s3164 s3163 0 0 nch W=0.5u L=0.18u
Mp3164 s3164 s3163 vdd vdd pch W=1u L=0.18u
Cl3164 s3164 0 10f
Mn3165 s3165 s3164 0 0 nch W=0.5u L=0.18u
Mp3165 s3165 s3164 vdd vdd pch W=1u L=0.18u
Cl3165 s3165 0 10f
Mn3166 s3166 s3165 0 0 nch W=0.5u L=0.18u
Mp3166 s3166 s3165 vdd vdd pch W=1u L=0.18u
Cl3166 s3166 0 10f
Mn3167 s3167 s3166 0 0 nch W=0.5u L=0.18u
Mp3167 s3167 s3166 vdd vdd pch W=1u L=0.18u
Cl3167 s3167 0 10f
Mn3168 s3168 s3167 0 0 nch W=0.5u L=0.18u
Mp3168 s3168 s3167 vdd vdd pch W=1u L=0.18u
Cl3168 s3168 0 10f
Mn3169 s3169 s3168 0 0 nch W=0.5u L=0.18u
Mp3169 s3169 s3168 vdd vdd pch W=1u L=0.18u
Cl3169 s3169 0 10f
Mn3170 s3170 s3169 0 0 nch W=0.5u L=0.18u
Mp3170 s3170 s3169 vdd vdd pch W=1u L=0.18u
Cl3170 s3170 0 10f
Mn3171 s3171 s3170 0 0 nch W=0.5u L=0.18u
Mp3171 s3171 s3170 vdd vdd pch W=1u L=0.18u
Cl3171 s3171 0 10f
Mn3172 s3172 s3171 0 0 nch W=0.5u L=0.18u
Mp3172 s3172 s3171 vdd vdd pch W=1u L=0.18u
Cl3172 s3172 0 10f
Mn3173 s3173 s3172 0 0 nch W=0.5u L=0.18u
Mp3173 s3173 s3172 vdd vdd pch W=1u L=0.18u
Cl3173 s3173 0 10f
Mn3174 s3174 s3173 0 0 nch W=0.5u L=0.18u
Mp3174 s3174 s3173 vdd vdd pch W=1u L=0.18u
Cl3174 s3174 0 10f
Mn3175 s3175 s3174 0 0 nch W=0.5u L=0.18u
Mp3175 s3175 s3174 vdd vdd pch W=1u L=0.18u
Cl3175 s3175 0 10f
Mn3176 s3176 s3175 0 0 nch W=0.5u L=0.18u
Mp3176 s3176 s3175 vdd vdd pch W=1u L=0.18u
Cl3176 s3176 0 10f
Mn3177 s3177 s3176 0 0 nch W=0.5u L=0.18u
Mp3177 s3177 s3176 vdd vdd pch W=1u L=0.18u
Cl3177 s3177 0 10f
Mn3178 s3178 s3177 0 0 nch W=0.5u L=0.18u
Mp3178 s3178 s3177 vdd vdd pch W=1u L=0.18u
Cl3178 s3178 0 10f
Mn3179 s3179 s3178 0 0 nch W=0.5u L=0.18u
Mp3179 s3179 s3178 vdd vdd pch W=1u L=0.18u
Cl3179 s3179 0 10f
Mn3180 s3180 s3179 0 0 nch W=0.5u L=0.18u
Mp3180 s3180 s3179 vdd vdd pch W=1u L=0.18u
Cl3180 s3180 0 10f
Mn3181 s3181 s3180 0 0 nch W=0.5u L=0.18u
Mp3181 s3181 s3180 vdd vdd pch W=1u L=0.18u
Cl3181 s3181 0 10f
Mn3182 s3182 s3181 0 0 nch W=0.5u L=0.18u
Mp3182 s3182 s3181 vdd vdd pch W=1u L=0.18u
Cl3182 s3182 0 10f
Mn3183 s3183 s3182 0 0 nch W=0.5u L=0.18u
Mp3183 s3183 s3182 vdd vdd pch W=1u L=0.18u
Cl3183 s3183 0 10f
Mn3184 s3184 s3183 0 0 nch W=0.5u L=0.18u
Mp3184 s3184 s3183 vdd vdd pch W=1u L=0.18u
Cl3184 s3184 0 10f
Mn3185 s3185 s3184 0 0 nch W=0.5u L=0.18u
Mp3185 s3185 s3184 vdd vdd pch W=1u L=0.18u
Cl3185 s3185 0 10f
Mn3186 s3186 s3185 0 0 nch W=0.5u L=0.18u
Mp3186 s3186 s3185 vdd vdd pch W=1u L=0.18u
Cl3186 s3186 0 10f
Mn3187 s3187 s3186 0 0 nch W=0.5u L=0.18u
Mp3187 s3187 s3186 vdd vdd pch W=1u L=0.18u
Cl3187 s3187 0 10f
Mn3188 s3188 s3187 0 0 nch W=0.5u L=0.18u
Mp3188 s3188 s3187 vdd vdd pch W=1u L=0.18u
Cl3188 s3188 0 10f
Mn3189 s3189 s3188 0 0 nch W=0.5u L=0.18u
Mp3189 s3189 s3188 vdd vdd pch W=1u L=0.18u
Cl3189 s3189 0 10f
Mn3190 s3190 s3189 0 0 nch W=0.5u L=0.18u
Mp3190 s3190 s3189 vdd vdd pch W=1u L=0.18u
Cl3190 s3190 0 10f
Mn3191 s3191 s3190 0 0 nch W=0.5u L=0.18u
Mp3191 s3191 s3190 vdd vdd pch W=1u L=0.18u
Cl3191 s3191 0 10f
Mn3192 s3192 s3191 0 0 nch W=0.5u L=0.18u
Mp3192 s3192 s3191 vdd vdd pch W=1u L=0.18u
Cl3192 s3192 0 10f
Mn3193 s3193 s3192 0 0 nch W=0.5u L=0.18u
Mp3193 s3193 s3192 vdd vdd pch W=1u L=0.18u
Cl3193 s3193 0 10f
Mn3194 s3194 s3193 0 0 nch W=0.5u L=0.18u
Mp3194 s3194 s3193 vdd vdd pch W=1u L=0.18u
Cl3194 s3194 0 10f
Mn3195 s3195 s3194 0 0 nch W=0.5u L=0.18u
Mp3195 s3195 s3194 vdd vdd pch W=1u L=0.18u
Cl3195 s3195 0 10f
Mn3196 s3196 s3195 0 0 nch W=0.5u L=0.18u
Mp3196 s3196 s3195 vdd vdd pch W=1u L=0.18u
Cl3196 s3196 0 10f
Mn3197 s3197 s3196 0 0 nch W=0.5u L=0.18u
Mp3197 s3197 s3196 vdd vdd pch W=1u L=0.18u
Cl3197 s3197 0 10f
Mn3198 s3198 s3197 0 0 nch W=0.5u L=0.18u
Mp3198 s3198 s3197 vdd vdd pch W=1u L=0.18u
Cl3198 s3198 0 10f
Mn3199 s3199 s3198 0 0 nch W=0.5u L=0.18u
Mp3199 s3199 s3198 vdd vdd pch W=1u L=0.18u
Cl3199 s3199 0 10f
Mn3200 s3200 s3199 0 0 nch W=0.5u L=0.18u
Mp3200 s3200 s3199 vdd vdd pch W=1u L=0.18u
Cl3200 s3200 0 10f
Mn3201 s3201 s3200 0 0 nch W=0.5u L=0.18u
Mp3201 s3201 s3200 vdd vdd pch W=1u L=0.18u
Cl3201 s3201 0 10f
Mn3202 s3202 s3201 0 0 nch W=0.5u L=0.18u
Mp3202 s3202 s3201 vdd vdd pch W=1u L=0.18u
Cl3202 s3202 0 10f
Mn3203 s3203 s3202 0 0 nch W=0.5u L=0.18u
Mp3203 s3203 s3202 vdd vdd pch W=1u L=0.18u
Cl3203 s3203 0 10f
Mn3204 s3204 s3203 0 0 nch W=0.5u L=0.18u
Mp3204 s3204 s3203 vdd vdd pch W=1u L=0.18u
Cl3204 s3204 0 10f
Mn3205 s3205 s3204 0 0 nch W=0.5u L=0.18u
Mp3205 s3205 s3204 vdd vdd pch W=1u L=0.18u
Cl3205 s3205 0 10f
Mn3206 s3206 s3205 0 0 nch W=0.5u L=0.18u
Mp3206 s3206 s3205 vdd vdd pch W=1u L=0.18u
Cl3206 s3206 0 10f
Mn3207 s3207 s3206 0 0 nch W=0.5u L=0.18u
Mp3207 s3207 s3206 vdd vdd pch W=1u L=0.18u
Cl3207 s3207 0 10f
Mn3208 s3208 s3207 0 0 nch W=0.5u L=0.18u
Mp3208 s3208 s3207 vdd vdd pch W=1u L=0.18u
Cl3208 s3208 0 10f
Mn3209 s3209 s3208 0 0 nch W=0.5u L=0.18u
Mp3209 s3209 s3208 vdd vdd pch W=1u L=0.18u
Cl3209 s3209 0 10f
Mn3210 s3210 s3209 0 0 nch W=0.5u L=0.18u
Mp3210 s3210 s3209 vdd vdd pch W=1u L=0.18u
Cl3210 s3210 0 10f
Mn3211 s3211 s3210 0 0 nch W=0.5u L=0.18u
Mp3211 s3211 s3210 vdd vdd pch W=1u L=0.18u
Cl3211 s3211 0 10f
Mn3212 s3212 s3211 0 0 nch W=0.5u L=0.18u
Mp3212 s3212 s3211 vdd vdd pch W=1u L=0.18u
Cl3212 s3212 0 10f
Mn3213 s3213 s3212 0 0 nch W=0.5u L=0.18u
Mp3213 s3213 s3212 vdd vdd pch W=1u L=0.18u
Cl3213 s3213 0 10f
Mn3214 s3214 s3213 0 0 nch W=0.5u L=0.18u
Mp3214 s3214 s3213 vdd vdd pch W=1u L=0.18u
Cl3214 s3214 0 10f
Mn3215 s3215 s3214 0 0 nch W=0.5u L=0.18u
Mp3215 s3215 s3214 vdd vdd pch W=1u L=0.18u
Cl3215 s3215 0 10f
Mn3216 s3216 s3215 0 0 nch W=0.5u L=0.18u
Mp3216 s3216 s3215 vdd vdd pch W=1u L=0.18u
Cl3216 s3216 0 10f
Mn3217 s3217 s3216 0 0 nch W=0.5u L=0.18u
Mp3217 s3217 s3216 vdd vdd pch W=1u L=0.18u
Cl3217 s3217 0 10f
Mn3218 s3218 s3217 0 0 nch W=0.5u L=0.18u
Mp3218 s3218 s3217 vdd vdd pch W=1u L=0.18u
Cl3218 s3218 0 10f
Mn3219 s3219 s3218 0 0 nch W=0.5u L=0.18u
Mp3219 s3219 s3218 vdd vdd pch W=1u L=0.18u
Cl3219 s3219 0 10f
Mn3220 s3220 s3219 0 0 nch W=0.5u L=0.18u
Mp3220 s3220 s3219 vdd vdd pch W=1u L=0.18u
Cl3220 s3220 0 10f
Mn3221 s3221 s3220 0 0 nch W=0.5u L=0.18u
Mp3221 s3221 s3220 vdd vdd pch W=1u L=0.18u
Cl3221 s3221 0 10f
Mn3222 s3222 s3221 0 0 nch W=0.5u L=0.18u
Mp3222 s3222 s3221 vdd vdd pch W=1u L=0.18u
Cl3222 s3222 0 10f
Mn3223 s3223 s3222 0 0 nch W=0.5u L=0.18u
Mp3223 s3223 s3222 vdd vdd pch W=1u L=0.18u
Cl3223 s3223 0 10f
Mn3224 s3224 s3223 0 0 nch W=0.5u L=0.18u
Mp3224 s3224 s3223 vdd vdd pch W=1u L=0.18u
Cl3224 s3224 0 10f
Mn3225 s3225 s3224 0 0 nch W=0.5u L=0.18u
Mp3225 s3225 s3224 vdd vdd pch W=1u L=0.18u
Cl3225 s3225 0 10f
Mn3226 s3226 s3225 0 0 nch W=0.5u L=0.18u
Mp3226 s3226 s3225 vdd vdd pch W=1u L=0.18u
Cl3226 s3226 0 10f
Mn3227 s3227 s3226 0 0 nch W=0.5u L=0.18u
Mp3227 s3227 s3226 vdd vdd pch W=1u L=0.18u
Cl3227 s3227 0 10f
Mn3228 s3228 s3227 0 0 nch W=0.5u L=0.18u
Mp3228 s3228 s3227 vdd vdd pch W=1u L=0.18u
Cl3228 s3228 0 10f
Mn3229 s3229 s3228 0 0 nch W=0.5u L=0.18u
Mp3229 s3229 s3228 vdd vdd pch W=1u L=0.18u
Cl3229 s3229 0 10f
Mn3230 s3230 s3229 0 0 nch W=0.5u L=0.18u
Mp3230 s3230 s3229 vdd vdd pch W=1u L=0.18u
Cl3230 s3230 0 10f
Mn3231 s3231 s3230 0 0 nch W=0.5u L=0.18u
Mp3231 s3231 s3230 vdd vdd pch W=1u L=0.18u
Cl3231 s3231 0 10f
Mn3232 s3232 s3231 0 0 nch W=0.5u L=0.18u
Mp3232 s3232 s3231 vdd vdd pch W=1u L=0.18u
Cl3232 s3232 0 10f
Mn3233 s3233 s3232 0 0 nch W=0.5u L=0.18u
Mp3233 s3233 s3232 vdd vdd pch W=1u L=0.18u
Cl3233 s3233 0 10f
Mn3234 s3234 s3233 0 0 nch W=0.5u L=0.18u
Mp3234 s3234 s3233 vdd vdd pch W=1u L=0.18u
Cl3234 s3234 0 10f
Mn3235 s3235 s3234 0 0 nch W=0.5u L=0.18u
Mp3235 s3235 s3234 vdd vdd pch W=1u L=0.18u
Cl3235 s3235 0 10f
Mn3236 s3236 s3235 0 0 nch W=0.5u L=0.18u
Mp3236 s3236 s3235 vdd vdd pch W=1u L=0.18u
Cl3236 s3236 0 10f
Mn3237 s3237 s3236 0 0 nch W=0.5u L=0.18u
Mp3237 s3237 s3236 vdd vdd pch W=1u L=0.18u
Cl3237 s3237 0 10f
Mn3238 s3238 s3237 0 0 nch W=0.5u L=0.18u
Mp3238 s3238 s3237 vdd vdd pch W=1u L=0.18u
Cl3238 s3238 0 10f
Mn3239 s3239 s3238 0 0 nch W=0.5u L=0.18u
Mp3239 s3239 s3238 vdd vdd pch W=1u L=0.18u
Cl3239 s3239 0 10f
Mn3240 s3240 s3239 0 0 nch W=0.5u L=0.18u
Mp3240 s3240 s3239 vdd vdd pch W=1u L=0.18u
Cl3240 s3240 0 10f
Mn3241 s3241 s3240 0 0 nch W=0.5u L=0.18u
Mp3241 s3241 s3240 vdd vdd pch W=1u L=0.18u
Cl3241 s3241 0 10f
Mn3242 s3242 s3241 0 0 nch W=0.5u L=0.18u
Mp3242 s3242 s3241 vdd vdd pch W=1u L=0.18u
Cl3242 s3242 0 10f
Mn3243 s3243 s3242 0 0 nch W=0.5u L=0.18u
Mp3243 s3243 s3242 vdd vdd pch W=1u L=0.18u
Cl3243 s3243 0 10f
Mn3244 s3244 s3243 0 0 nch W=0.5u L=0.18u
Mp3244 s3244 s3243 vdd vdd pch W=1u L=0.18u
Cl3244 s3244 0 10f
Mn3245 s3245 s3244 0 0 nch W=0.5u L=0.18u
Mp3245 s3245 s3244 vdd vdd pch W=1u L=0.18u
Cl3245 s3245 0 10f
Mn3246 s3246 s3245 0 0 nch W=0.5u L=0.18u
Mp3246 s3246 s3245 vdd vdd pch W=1u L=0.18u
Cl3246 s3246 0 10f
Mn3247 s3247 s3246 0 0 nch W=0.5u L=0.18u
Mp3247 s3247 s3246 vdd vdd pch W=1u L=0.18u
Cl3247 s3247 0 10f
Mn3248 s3248 s3247 0 0 nch W=0.5u L=0.18u
Mp3248 s3248 s3247 vdd vdd pch W=1u L=0.18u
Cl3248 s3248 0 10f
Mn3249 s3249 s3248 0 0 nch W=0.5u L=0.18u
Mp3249 s3249 s3248 vdd vdd pch W=1u L=0.18u
Cl3249 s3249 0 10f
Mn3250 s3250 s3249 0 0 nch W=0.5u L=0.18u
Mp3250 s3250 s3249 vdd vdd pch W=1u L=0.18u
Cl3250 s3250 0 10f
Mn3251 s3251 s3250 0 0 nch W=0.5u L=0.18u
Mp3251 s3251 s3250 vdd vdd pch W=1u L=0.18u
Cl3251 s3251 0 10f
Mn3252 s3252 s3251 0 0 nch W=0.5u L=0.18u
Mp3252 s3252 s3251 vdd vdd pch W=1u L=0.18u
Cl3252 s3252 0 10f
Mn3253 s3253 s3252 0 0 nch W=0.5u L=0.18u
Mp3253 s3253 s3252 vdd vdd pch W=1u L=0.18u
Cl3253 s3253 0 10f
Mn3254 s3254 s3253 0 0 nch W=0.5u L=0.18u
Mp3254 s3254 s3253 vdd vdd pch W=1u L=0.18u
Cl3254 s3254 0 10f
Mn3255 s3255 s3254 0 0 nch W=0.5u L=0.18u
Mp3255 s3255 s3254 vdd vdd pch W=1u L=0.18u
Cl3255 s3255 0 10f
Mn3256 s3256 s3255 0 0 nch W=0.5u L=0.18u
Mp3256 s3256 s3255 vdd vdd pch W=1u L=0.18u
Cl3256 s3256 0 10f
Mn3257 s3257 s3256 0 0 nch W=0.5u L=0.18u
Mp3257 s3257 s3256 vdd vdd pch W=1u L=0.18u
Cl3257 s3257 0 10f
Mn3258 s3258 s3257 0 0 nch W=0.5u L=0.18u
Mp3258 s3258 s3257 vdd vdd pch W=1u L=0.18u
Cl3258 s3258 0 10f
Mn3259 s3259 s3258 0 0 nch W=0.5u L=0.18u
Mp3259 s3259 s3258 vdd vdd pch W=1u L=0.18u
Cl3259 s3259 0 10f
Mn3260 s3260 s3259 0 0 nch W=0.5u L=0.18u
Mp3260 s3260 s3259 vdd vdd pch W=1u L=0.18u
Cl3260 s3260 0 10f
Mn3261 s3261 s3260 0 0 nch W=0.5u L=0.18u
Mp3261 s3261 s3260 vdd vdd pch W=1u L=0.18u
Cl3261 s3261 0 10f
Mn3262 s3262 s3261 0 0 nch W=0.5u L=0.18u
Mp3262 s3262 s3261 vdd vdd pch W=1u L=0.18u
Cl3262 s3262 0 10f
Mn3263 s3263 s3262 0 0 nch W=0.5u L=0.18u
Mp3263 s3263 s3262 vdd vdd pch W=1u L=0.18u
Cl3263 s3263 0 10f
Mn3264 s3264 s3263 0 0 nch W=0.5u L=0.18u
Mp3264 s3264 s3263 vdd vdd pch W=1u L=0.18u
Cl3264 s3264 0 10f
Mn3265 s3265 s3264 0 0 nch W=0.5u L=0.18u
Mp3265 s3265 s3264 vdd vdd pch W=1u L=0.18u
Cl3265 s3265 0 10f
Mn3266 s3266 s3265 0 0 nch W=0.5u L=0.18u
Mp3266 s3266 s3265 vdd vdd pch W=1u L=0.18u
Cl3266 s3266 0 10f
Mn3267 s3267 s3266 0 0 nch W=0.5u L=0.18u
Mp3267 s3267 s3266 vdd vdd pch W=1u L=0.18u
Cl3267 s3267 0 10f
Mn3268 s3268 s3267 0 0 nch W=0.5u L=0.18u
Mp3268 s3268 s3267 vdd vdd pch W=1u L=0.18u
Cl3268 s3268 0 10f
Mn3269 s3269 s3268 0 0 nch W=0.5u L=0.18u
Mp3269 s3269 s3268 vdd vdd pch W=1u L=0.18u
Cl3269 s3269 0 10f
Mn3270 s3270 s3269 0 0 nch W=0.5u L=0.18u
Mp3270 s3270 s3269 vdd vdd pch W=1u L=0.18u
Cl3270 s3270 0 10f
Mn3271 s3271 s3270 0 0 nch W=0.5u L=0.18u
Mp3271 s3271 s3270 vdd vdd pch W=1u L=0.18u
Cl3271 s3271 0 10f
Mn3272 s3272 s3271 0 0 nch W=0.5u L=0.18u
Mp3272 s3272 s3271 vdd vdd pch W=1u L=0.18u
Cl3272 s3272 0 10f
Mn3273 s3273 s3272 0 0 nch W=0.5u L=0.18u
Mp3273 s3273 s3272 vdd vdd pch W=1u L=0.18u
Cl3273 s3273 0 10f
Mn3274 s3274 s3273 0 0 nch W=0.5u L=0.18u
Mp3274 s3274 s3273 vdd vdd pch W=1u L=0.18u
Cl3274 s3274 0 10f
Mn3275 s3275 s3274 0 0 nch W=0.5u L=0.18u
Mp3275 s3275 s3274 vdd vdd pch W=1u L=0.18u
Cl3275 s3275 0 10f
Mn3276 s3276 s3275 0 0 nch W=0.5u L=0.18u
Mp3276 s3276 s3275 vdd vdd pch W=1u L=0.18u
Cl3276 s3276 0 10f
Mn3277 s3277 s3276 0 0 nch W=0.5u L=0.18u
Mp3277 s3277 s3276 vdd vdd pch W=1u L=0.18u
Cl3277 s3277 0 10f
Mn3278 s3278 s3277 0 0 nch W=0.5u L=0.18u
Mp3278 s3278 s3277 vdd vdd pch W=1u L=0.18u
Cl3278 s3278 0 10f
Mn3279 s3279 s3278 0 0 nch W=0.5u L=0.18u
Mp3279 s3279 s3278 vdd vdd pch W=1u L=0.18u
Cl3279 s3279 0 10f
Mn3280 s3280 s3279 0 0 nch W=0.5u L=0.18u
Mp3280 s3280 s3279 vdd vdd pch W=1u L=0.18u
Cl3280 s3280 0 10f
Mn3281 s3281 s3280 0 0 nch W=0.5u L=0.18u
Mp3281 s3281 s3280 vdd vdd pch W=1u L=0.18u
Cl3281 s3281 0 10f
Mn3282 s3282 s3281 0 0 nch W=0.5u L=0.18u
Mp3282 s3282 s3281 vdd vdd pch W=1u L=0.18u
Cl3282 s3282 0 10f
Mn3283 s3283 s3282 0 0 nch W=0.5u L=0.18u
Mp3283 s3283 s3282 vdd vdd pch W=1u L=0.18u
Cl3283 s3283 0 10f
Mn3284 s3284 s3283 0 0 nch W=0.5u L=0.18u
Mp3284 s3284 s3283 vdd vdd pch W=1u L=0.18u
Cl3284 s3284 0 10f
Mn3285 s3285 s3284 0 0 nch W=0.5u L=0.18u
Mp3285 s3285 s3284 vdd vdd pch W=1u L=0.18u
Cl3285 s3285 0 10f
Mn3286 s3286 s3285 0 0 nch W=0.5u L=0.18u
Mp3286 s3286 s3285 vdd vdd pch W=1u L=0.18u
Cl3286 s3286 0 10f
Mn3287 s3287 s3286 0 0 nch W=0.5u L=0.18u
Mp3287 s3287 s3286 vdd vdd pch W=1u L=0.18u
Cl3287 s3287 0 10f
Mn3288 s3288 s3287 0 0 nch W=0.5u L=0.18u
Mp3288 s3288 s3287 vdd vdd pch W=1u L=0.18u
Cl3288 s3288 0 10f
Mn3289 s3289 s3288 0 0 nch W=0.5u L=0.18u
Mp3289 s3289 s3288 vdd vdd pch W=1u L=0.18u
Cl3289 s3289 0 10f
Mn3290 s3290 s3289 0 0 nch W=0.5u L=0.18u
Mp3290 s3290 s3289 vdd vdd pch W=1u L=0.18u
Cl3290 s3290 0 10f
Mn3291 s3291 s3290 0 0 nch W=0.5u L=0.18u
Mp3291 s3291 s3290 vdd vdd pch W=1u L=0.18u
Cl3291 s3291 0 10f
Mn3292 s3292 s3291 0 0 nch W=0.5u L=0.18u
Mp3292 s3292 s3291 vdd vdd pch W=1u L=0.18u
Cl3292 s3292 0 10f
Mn3293 s3293 s3292 0 0 nch W=0.5u L=0.18u
Mp3293 s3293 s3292 vdd vdd pch W=1u L=0.18u
Cl3293 s3293 0 10f
Mn3294 s3294 s3293 0 0 nch W=0.5u L=0.18u
Mp3294 s3294 s3293 vdd vdd pch W=1u L=0.18u
Cl3294 s3294 0 10f
Mn3295 s3295 s3294 0 0 nch W=0.5u L=0.18u
Mp3295 s3295 s3294 vdd vdd pch W=1u L=0.18u
Cl3295 s3295 0 10f
Mn3296 s3296 s3295 0 0 nch W=0.5u L=0.18u
Mp3296 s3296 s3295 vdd vdd pch W=1u L=0.18u
Cl3296 s3296 0 10f
Mn3297 s3297 s3296 0 0 nch W=0.5u L=0.18u
Mp3297 s3297 s3296 vdd vdd pch W=1u L=0.18u
Cl3297 s3297 0 10f
Mn3298 s3298 s3297 0 0 nch W=0.5u L=0.18u
Mp3298 s3298 s3297 vdd vdd pch W=1u L=0.18u
Cl3298 s3298 0 10f
Mn3299 s3299 s3298 0 0 nch W=0.5u L=0.18u
Mp3299 s3299 s3298 vdd vdd pch W=1u L=0.18u
Cl3299 s3299 0 10f
Mn3300 s3300 s3299 0 0 nch W=0.5u L=0.18u
Mp3300 s3300 s3299 vdd vdd pch W=1u L=0.18u
Cl3300 s3300 0 10f
Mn3301 s3301 s3300 0 0 nch W=0.5u L=0.18u
Mp3301 s3301 s3300 vdd vdd pch W=1u L=0.18u
Cl3301 s3301 0 10f
Mn3302 s3302 s3301 0 0 nch W=0.5u L=0.18u
Mp3302 s3302 s3301 vdd vdd pch W=1u L=0.18u
Cl3302 s3302 0 10f
Mn3303 s3303 s3302 0 0 nch W=0.5u L=0.18u
Mp3303 s3303 s3302 vdd vdd pch W=1u L=0.18u
Cl3303 s3303 0 10f
Mn3304 s3304 s3303 0 0 nch W=0.5u L=0.18u
Mp3304 s3304 s3303 vdd vdd pch W=1u L=0.18u
Cl3304 s3304 0 10f
Mn3305 s3305 s3304 0 0 nch W=0.5u L=0.18u
Mp3305 s3305 s3304 vdd vdd pch W=1u L=0.18u
Cl3305 s3305 0 10f
Mn3306 s3306 s3305 0 0 nch W=0.5u L=0.18u
Mp3306 s3306 s3305 vdd vdd pch W=1u L=0.18u
Cl3306 s3306 0 10f
Mn3307 s3307 s3306 0 0 nch W=0.5u L=0.18u
Mp3307 s3307 s3306 vdd vdd pch W=1u L=0.18u
Cl3307 s3307 0 10f
Mn3308 s3308 s3307 0 0 nch W=0.5u L=0.18u
Mp3308 s3308 s3307 vdd vdd pch W=1u L=0.18u
Cl3308 s3308 0 10f
Mn3309 s3309 s3308 0 0 nch W=0.5u L=0.18u
Mp3309 s3309 s3308 vdd vdd pch W=1u L=0.18u
Cl3309 s3309 0 10f
Mn3310 s3310 s3309 0 0 nch W=0.5u L=0.18u
Mp3310 s3310 s3309 vdd vdd pch W=1u L=0.18u
Cl3310 s3310 0 10f
Mn3311 s3311 s3310 0 0 nch W=0.5u L=0.18u
Mp3311 s3311 s3310 vdd vdd pch W=1u L=0.18u
Cl3311 s3311 0 10f
Mn3312 s3312 s3311 0 0 nch W=0.5u L=0.18u
Mp3312 s3312 s3311 vdd vdd pch W=1u L=0.18u
Cl3312 s3312 0 10f
Mn3313 s3313 s3312 0 0 nch W=0.5u L=0.18u
Mp3313 s3313 s3312 vdd vdd pch W=1u L=0.18u
Cl3313 s3313 0 10f
Mn3314 s3314 s3313 0 0 nch W=0.5u L=0.18u
Mp3314 s3314 s3313 vdd vdd pch W=1u L=0.18u
Cl3314 s3314 0 10f
Mn3315 s3315 s3314 0 0 nch W=0.5u L=0.18u
Mp3315 s3315 s3314 vdd vdd pch W=1u L=0.18u
Cl3315 s3315 0 10f
Mn3316 s3316 s3315 0 0 nch W=0.5u L=0.18u
Mp3316 s3316 s3315 vdd vdd pch W=1u L=0.18u
Cl3316 s3316 0 10f
Mn3317 s3317 s3316 0 0 nch W=0.5u L=0.18u
Mp3317 s3317 s3316 vdd vdd pch W=1u L=0.18u
Cl3317 s3317 0 10f
Mn3318 s3318 s3317 0 0 nch W=0.5u L=0.18u
Mp3318 s3318 s3317 vdd vdd pch W=1u L=0.18u
Cl3318 s3318 0 10f
Mn3319 s3319 s3318 0 0 nch W=0.5u L=0.18u
Mp3319 s3319 s3318 vdd vdd pch W=1u L=0.18u
Cl3319 s3319 0 10f
Mn3320 s3320 s3319 0 0 nch W=0.5u L=0.18u
Mp3320 s3320 s3319 vdd vdd pch W=1u L=0.18u
Cl3320 s3320 0 10f
Mn3321 s3321 s3320 0 0 nch W=0.5u L=0.18u
Mp3321 s3321 s3320 vdd vdd pch W=1u L=0.18u
Cl3321 s3321 0 10f
Mn3322 s3322 s3321 0 0 nch W=0.5u L=0.18u
Mp3322 s3322 s3321 vdd vdd pch W=1u L=0.18u
Cl3322 s3322 0 10f
Mn3323 s3323 s3322 0 0 nch W=0.5u L=0.18u
Mp3323 s3323 s3322 vdd vdd pch W=1u L=0.18u
Cl3323 s3323 0 10f
Mn3324 s3324 s3323 0 0 nch W=0.5u L=0.18u
Mp3324 s3324 s3323 vdd vdd pch W=1u L=0.18u
Cl3324 s3324 0 10f
Mn3325 s3325 s3324 0 0 nch W=0.5u L=0.18u
Mp3325 s3325 s3324 vdd vdd pch W=1u L=0.18u
Cl3325 s3325 0 10f
Mn3326 s3326 s3325 0 0 nch W=0.5u L=0.18u
Mp3326 s3326 s3325 vdd vdd pch W=1u L=0.18u
Cl3326 s3326 0 10f
Mn3327 s3327 s3326 0 0 nch W=0.5u L=0.18u
Mp3327 s3327 s3326 vdd vdd pch W=1u L=0.18u
Cl3327 s3327 0 10f
Mn3328 s3328 s3327 0 0 nch W=0.5u L=0.18u
Mp3328 s3328 s3327 vdd vdd pch W=1u L=0.18u
Cl3328 s3328 0 10f
Mn3329 s3329 s3328 0 0 nch W=0.5u L=0.18u
Mp3329 s3329 s3328 vdd vdd pch W=1u L=0.18u
Cl3329 s3329 0 10f
Mn3330 s3330 s3329 0 0 nch W=0.5u L=0.18u
Mp3330 s3330 s3329 vdd vdd pch W=1u L=0.18u
Cl3330 s3330 0 10f
Mn3331 s3331 s3330 0 0 nch W=0.5u L=0.18u
Mp3331 s3331 s3330 vdd vdd pch W=1u L=0.18u
Cl3331 s3331 0 10f
Mn3332 s3332 s3331 0 0 nch W=0.5u L=0.18u
Mp3332 s3332 s3331 vdd vdd pch W=1u L=0.18u
Cl3332 s3332 0 10f
Mn3333 s3333 s3332 0 0 nch W=0.5u L=0.18u
Mp3333 s3333 s3332 vdd vdd pch W=1u L=0.18u
Cl3333 s3333 0 10f
Mn3334 s3334 s3333 0 0 nch W=0.5u L=0.18u
Mp3334 s3334 s3333 vdd vdd pch W=1u L=0.18u
Cl3334 s3334 0 10f
Mn3335 s3335 s3334 0 0 nch W=0.5u L=0.18u
Mp3335 s3335 s3334 vdd vdd pch W=1u L=0.18u
Cl3335 s3335 0 10f
Mn3336 s3336 s3335 0 0 nch W=0.5u L=0.18u
Mp3336 s3336 s3335 vdd vdd pch W=1u L=0.18u
Cl3336 s3336 0 10f
Mn3337 s3337 s3336 0 0 nch W=0.5u L=0.18u
Mp3337 s3337 s3336 vdd vdd pch W=1u L=0.18u
Cl3337 s3337 0 10f
Mn3338 s3338 s3337 0 0 nch W=0.5u L=0.18u
Mp3338 s3338 s3337 vdd vdd pch W=1u L=0.18u
Cl3338 s3338 0 10f
Mn3339 s3339 s3338 0 0 nch W=0.5u L=0.18u
Mp3339 s3339 s3338 vdd vdd pch W=1u L=0.18u
Cl3339 s3339 0 10f
Mn3340 s3340 s3339 0 0 nch W=0.5u L=0.18u
Mp3340 s3340 s3339 vdd vdd pch W=1u L=0.18u
Cl3340 s3340 0 10f
Mn3341 s3341 s3340 0 0 nch W=0.5u L=0.18u
Mp3341 s3341 s3340 vdd vdd pch W=1u L=0.18u
Cl3341 s3341 0 10f
Mn3342 s3342 s3341 0 0 nch W=0.5u L=0.18u
Mp3342 s3342 s3341 vdd vdd pch W=1u L=0.18u
Cl3342 s3342 0 10f
Mn3343 s3343 s3342 0 0 nch W=0.5u L=0.18u
Mp3343 s3343 s3342 vdd vdd pch W=1u L=0.18u
Cl3343 s3343 0 10f
Mn3344 s3344 s3343 0 0 nch W=0.5u L=0.18u
Mp3344 s3344 s3343 vdd vdd pch W=1u L=0.18u
Cl3344 s3344 0 10f
Mn3345 s3345 s3344 0 0 nch W=0.5u L=0.18u
Mp3345 s3345 s3344 vdd vdd pch W=1u L=0.18u
Cl3345 s3345 0 10f
Mn3346 s3346 s3345 0 0 nch W=0.5u L=0.18u
Mp3346 s3346 s3345 vdd vdd pch W=1u L=0.18u
Cl3346 s3346 0 10f
Mn3347 s3347 s3346 0 0 nch W=0.5u L=0.18u
Mp3347 s3347 s3346 vdd vdd pch W=1u L=0.18u
Cl3347 s3347 0 10f
Mn3348 s3348 s3347 0 0 nch W=0.5u L=0.18u
Mp3348 s3348 s3347 vdd vdd pch W=1u L=0.18u
Cl3348 s3348 0 10f
Mn3349 s3349 s3348 0 0 nch W=0.5u L=0.18u
Mp3349 s3349 s3348 vdd vdd pch W=1u L=0.18u
Cl3349 s3349 0 10f
Mn3350 s3350 s3349 0 0 nch W=0.5u L=0.18u
Mp3350 s3350 s3349 vdd vdd pch W=1u L=0.18u
Cl3350 s3350 0 10f
Mn3351 s3351 s3350 0 0 nch W=0.5u L=0.18u
Mp3351 s3351 s3350 vdd vdd pch W=1u L=0.18u
Cl3351 s3351 0 10f
Mn3352 s3352 s3351 0 0 nch W=0.5u L=0.18u
Mp3352 s3352 s3351 vdd vdd pch W=1u L=0.18u
Cl3352 s3352 0 10f
Mn3353 s3353 s3352 0 0 nch W=0.5u L=0.18u
Mp3353 s3353 s3352 vdd vdd pch W=1u L=0.18u
Cl3353 s3353 0 10f
Mn3354 s3354 s3353 0 0 nch W=0.5u L=0.18u
Mp3354 s3354 s3353 vdd vdd pch W=1u L=0.18u
Cl3354 s3354 0 10f
Mn3355 s3355 s3354 0 0 nch W=0.5u L=0.18u
Mp3355 s3355 s3354 vdd vdd pch W=1u L=0.18u
Cl3355 s3355 0 10f
Mn3356 s3356 s3355 0 0 nch W=0.5u L=0.18u
Mp3356 s3356 s3355 vdd vdd pch W=1u L=0.18u
Cl3356 s3356 0 10f
Mn3357 s3357 s3356 0 0 nch W=0.5u L=0.18u
Mp3357 s3357 s3356 vdd vdd pch W=1u L=0.18u
Cl3357 s3357 0 10f
Mn3358 s3358 s3357 0 0 nch W=0.5u L=0.18u
Mp3358 s3358 s3357 vdd vdd pch W=1u L=0.18u
Cl3358 s3358 0 10f
Mn3359 s3359 s3358 0 0 nch W=0.5u L=0.18u
Mp3359 s3359 s3358 vdd vdd pch W=1u L=0.18u
Cl3359 s3359 0 10f
Mn3360 s3360 s3359 0 0 nch W=0.5u L=0.18u
Mp3360 s3360 s3359 vdd vdd pch W=1u L=0.18u
Cl3360 s3360 0 10f
Mn3361 s3361 s3360 0 0 nch W=0.5u L=0.18u
Mp3361 s3361 s3360 vdd vdd pch W=1u L=0.18u
Cl3361 s3361 0 10f
Mn3362 s3362 s3361 0 0 nch W=0.5u L=0.18u
Mp3362 s3362 s3361 vdd vdd pch W=1u L=0.18u
Cl3362 s3362 0 10f
Mn3363 s3363 s3362 0 0 nch W=0.5u L=0.18u
Mp3363 s3363 s3362 vdd vdd pch W=1u L=0.18u
Cl3363 s3363 0 10f
Mn3364 s3364 s3363 0 0 nch W=0.5u L=0.18u
Mp3364 s3364 s3363 vdd vdd pch W=1u L=0.18u
Cl3364 s3364 0 10f
Mn3365 s3365 s3364 0 0 nch W=0.5u L=0.18u
Mp3365 s3365 s3364 vdd vdd pch W=1u L=0.18u
Cl3365 s3365 0 10f
Mn3366 s3366 s3365 0 0 nch W=0.5u L=0.18u
Mp3366 s3366 s3365 vdd vdd pch W=1u L=0.18u
Cl3366 s3366 0 10f
Mn3367 s3367 s3366 0 0 nch W=0.5u L=0.18u
Mp3367 s3367 s3366 vdd vdd pch W=1u L=0.18u
Cl3367 s3367 0 10f
Mn3368 s3368 s3367 0 0 nch W=0.5u L=0.18u
Mp3368 s3368 s3367 vdd vdd pch W=1u L=0.18u
Cl3368 s3368 0 10f
Mn3369 s3369 s3368 0 0 nch W=0.5u L=0.18u
Mp3369 s3369 s3368 vdd vdd pch W=1u L=0.18u
Cl3369 s3369 0 10f
Mn3370 s3370 s3369 0 0 nch W=0.5u L=0.18u
Mp3370 s3370 s3369 vdd vdd pch W=1u L=0.18u
Cl3370 s3370 0 10f
Mn3371 s3371 s3370 0 0 nch W=0.5u L=0.18u
Mp3371 s3371 s3370 vdd vdd pch W=1u L=0.18u
Cl3371 s3371 0 10f
Mn3372 s3372 s3371 0 0 nch W=0.5u L=0.18u
Mp3372 s3372 s3371 vdd vdd pch W=1u L=0.18u
Cl3372 s3372 0 10f
Mn3373 s3373 s3372 0 0 nch W=0.5u L=0.18u
Mp3373 s3373 s3372 vdd vdd pch W=1u L=0.18u
Cl3373 s3373 0 10f
Mn3374 s3374 s3373 0 0 nch W=0.5u L=0.18u
Mp3374 s3374 s3373 vdd vdd pch W=1u L=0.18u
Cl3374 s3374 0 10f
Mn3375 s3375 s3374 0 0 nch W=0.5u L=0.18u
Mp3375 s3375 s3374 vdd vdd pch W=1u L=0.18u
Cl3375 s3375 0 10f
Mn3376 s3376 s3375 0 0 nch W=0.5u L=0.18u
Mp3376 s3376 s3375 vdd vdd pch W=1u L=0.18u
Cl3376 s3376 0 10f
Mn3377 s3377 s3376 0 0 nch W=0.5u L=0.18u
Mp3377 s3377 s3376 vdd vdd pch W=1u L=0.18u
Cl3377 s3377 0 10f
Mn3378 s3378 s3377 0 0 nch W=0.5u L=0.18u
Mp3378 s3378 s3377 vdd vdd pch W=1u L=0.18u
Cl3378 s3378 0 10f
Mn3379 s3379 s3378 0 0 nch W=0.5u L=0.18u
Mp3379 s3379 s3378 vdd vdd pch W=1u L=0.18u
Cl3379 s3379 0 10f
Mn3380 s3380 s3379 0 0 nch W=0.5u L=0.18u
Mp3380 s3380 s3379 vdd vdd pch W=1u L=0.18u
Cl3380 s3380 0 10f
Mn3381 s3381 s3380 0 0 nch W=0.5u L=0.18u
Mp3381 s3381 s3380 vdd vdd pch W=1u L=0.18u
Cl3381 s3381 0 10f
Mn3382 s3382 s3381 0 0 nch W=0.5u L=0.18u
Mp3382 s3382 s3381 vdd vdd pch W=1u L=0.18u
Cl3382 s3382 0 10f
Mn3383 s3383 s3382 0 0 nch W=0.5u L=0.18u
Mp3383 s3383 s3382 vdd vdd pch W=1u L=0.18u
Cl3383 s3383 0 10f
Mn3384 s3384 s3383 0 0 nch W=0.5u L=0.18u
Mp3384 s3384 s3383 vdd vdd pch W=1u L=0.18u
Cl3384 s3384 0 10f
Mn3385 s3385 s3384 0 0 nch W=0.5u L=0.18u
Mp3385 s3385 s3384 vdd vdd pch W=1u L=0.18u
Cl3385 s3385 0 10f
Mn3386 s3386 s3385 0 0 nch W=0.5u L=0.18u
Mp3386 s3386 s3385 vdd vdd pch W=1u L=0.18u
Cl3386 s3386 0 10f
Mn3387 s3387 s3386 0 0 nch W=0.5u L=0.18u
Mp3387 s3387 s3386 vdd vdd pch W=1u L=0.18u
Cl3387 s3387 0 10f
Mn3388 s3388 s3387 0 0 nch W=0.5u L=0.18u
Mp3388 s3388 s3387 vdd vdd pch W=1u L=0.18u
Cl3388 s3388 0 10f
Mn3389 s3389 s3388 0 0 nch W=0.5u L=0.18u
Mp3389 s3389 s3388 vdd vdd pch W=1u L=0.18u
Cl3389 s3389 0 10f
Mn3390 s3390 s3389 0 0 nch W=0.5u L=0.18u
Mp3390 s3390 s3389 vdd vdd pch W=1u L=0.18u
Cl3390 s3390 0 10f
Mn3391 s3391 s3390 0 0 nch W=0.5u L=0.18u
Mp3391 s3391 s3390 vdd vdd pch W=1u L=0.18u
Cl3391 s3391 0 10f
Mn3392 s3392 s3391 0 0 nch W=0.5u L=0.18u
Mp3392 s3392 s3391 vdd vdd pch W=1u L=0.18u
Cl3392 s3392 0 10f
Mn3393 s3393 s3392 0 0 nch W=0.5u L=0.18u
Mp3393 s3393 s3392 vdd vdd pch W=1u L=0.18u
Cl3393 s3393 0 10f
Mn3394 s3394 s3393 0 0 nch W=0.5u L=0.18u
Mp3394 s3394 s3393 vdd vdd pch W=1u L=0.18u
Cl3394 s3394 0 10f
Mn3395 s3395 s3394 0 0 nch W=0.5u L=0.18u
Mp3395 s3395 s3394 vdd vdd pch W=1u L=0.18u
Cl3395 s3395 0 10f
Mn3396 s3396 s3395 0 0 nch W=0.5u L=0.18u
Mp3396 s3396 s3395 vdd vdd pch W=1u L=0.18u
Cl3396 s3396 0 10f
Mn3397 s3397 s3396 0 0 nch W=0.5u L=0.18u
Mp3397 s3397 s3396 vdd vdd pch W=1u L=0.18u
Cl3397 s3397 0 10f
Mn3398 s3398 s3397 0 0 nch W=0.5u L=0.18u
Mp3398 s3398 s3397 vdd vdd pch W=1u L=0.18u
Cl3398 s3398 0 10f
Mn3399 s3399 s3398 0 0 nch W=0.5u L=0.18u
Mp3399 s3399 s3398 vdd vdd pch W=1u L=0.18u
Cl3399 s3399 0 10f
Mn3400 s3400 s3399 0 0 nch W=0.5u L=0.18u
Mp3400 s3400 s3399 vdd vdd pch W=1u L=0.18u
Cl3400 s3400 0 10f
Mn3401 s3401 s3400 0 0 nch W=0.5u L=0.18u
Mp3401 s3401 s3400 vdd vdd pch W=1u L=0.18u
Cl3401 s3401 0 10f
Mn3402 s3402 s3401 0 0 nch W=0.5u L=0.18u
Mp3402 s3402 s3401 vdd vdd pch W=1u L=0.18u
Cl3402 s3402 0 10f
Mn3403 s3403 s3402 0 0 nch W=0.5u L=0.18u
Mp3403 s3403 s3402 vdd vdd pch W=1u L=0.18u
Cl3403 s3403 0 10f
Mn3404 s3404 s3403 0 0 nch W=0.5u L=0.18u
Mp3404 s3404 s3403 vdd vdd pch W=1u L=0.18u
Cl3404 s3404 0 10f
Mn3405 s3405 s3404 0 0 nch W=0.5u L=0.18u
Mp3405 s3405 s3404 vdd vdd pch W=1u L=0.18u
Cl3405 s3405 0 10f
Mn3406 s3406 s3405 0 0 nch W=0.5u L=0.18u
Mp3406 s3406 s3405 vdd vdd pch W=1u L=0.18u
Cl3406 s3406 0 10f
Mn3407 s3407 s3406 0 0 nch W=0.5u L=0.18u
Mp3407 s3407 s3406 vdd vdd pch W=1u L=0.18u
Cl3407 s3407 0 10f
Mn3408 s3408 s3407 0 0 nch W=0.5u L=0.18u
Mp3408 s3408 s3407 vdd vdd pch W=1u L=0.18u
Cl3408 s3408 0 10f
Mn3409 s3409 s3408 0 0 nch W=0.5u L=0.18u
Mp3409 s3409 s3408 vdd vdd pch W=1u L=0.18u
Cl3409 s3409 0 10f
Mn3410 s3410 s3409 0 0 nch W=0.5u L=0.18u
Mp3410 s3410 s3409 vdd vdd pch W=1u L=0.18u
Cl3410 s3410 0 10f
Mn3411 s3411 s3410 0 0 nch W=0.5u L=0.18u
Mp3411 s3411 s3410 vdd vdd pch W=1u L=0.18u
Cl3411 s3411 0 10f
Mn3412 s3412 s3411 0 0 nch W=0.5u L=0.18u
Mp3412 s3412 s3411 vdd vdd pch W=1u L=0.18u
Cl3412 s3412 0 10f
Mn3413 s3413 s3412 0 0 nch W=0.5u L=0.18u
Mp3413 s3413 s3412 vdd vdd pch W=1u L=0.18u
Cl3413 s3413 0 10f
Mn3414 s3414 s3413 0 0 nch W=0.5u L=0.18u
Mp3414 s3414 s3413 vdd vdd pch W=1u L=0.18u
Cl3414 s3414 0 10f
Mn3415 s3415 s3414 0 0 nch W=0.5u L=0.18u
Mp3415 s3415 s3414 vdd vdd pch W=1u L=0.18u
Cl3415 s3415 0 10f
Mn3416 s3416 s3415 0 0 nch W=0.5u L=0.18u
Mp3416 s3416 s3415 vdd vdd pch W=1u L=0.18u
Cl3416 s3416 0 10f
Mn3417 s3417 s3416 0 0 nch W=0.5u L=0.18u
Mp3417 s3417 s3416 vdd vdd pch W=1u L=0.18u
Cl3417 s3417 0 10f
Mn3418 s3418 s3417 0 0 nch W=0.5u L=0.18u
Mp3418 s3418 s3417 vdd vdd pch W=1u L=0.18u
Cl3418 s3418 0 10f
Mn3419 s3419 s3418 0 0 nch W=0.5u L=0.18u
Mp3419 s3419 s3418 vdd vdd pch W=1u L=0.18u
Cl3419 s3419 0 10f
Mn3420 s3420 s3419 0 0 nch W=0.5u L=0.18u
Mp3420 s3420 s3419 vdd vdd pch W=1u L=0.18u
Cl3420 s3420 0 10f
Mn3421 s3421 s3420 0 0 nch W=0.5u L=0.18u
Mp3421 s3421 s3420 vdd vdd pch W=1u L=0.18u
Cl3421 s3421 0 10f
Mn3422 s3422 s3421 0 0 nch W=0.5u L=0.18u
Mp3422 s3422 s3421 vdd vdd pch W=1u L=0.18u
Cl3422 s3422 0 10f
Mn3423 s3423 s3422 0 0 nch W=0.5u L=0.18u
Mp3423 s3423 s3422 vdd vdd pch W=1u L=0.18u
Cl3423 s3423 0 10f
Mn3424 s3424 s3423 0 0 nch W=0.5u L=0.18u
Mp3424 s3424 s3423 vdd vdd pch W=1u L=0.18u
Cl3424 s3424 0 10f
Mn3425 s3425 s3424 0 0 nch W=0.5u L=0.18u
Mp3425 s3425 s3424 vdd vdd pch W=1u L=0.18u
Cl3425 s3425 0 10f
Mn3426 s3426 s3425 0 0 nch W=0.5u L=0.18u
Mp3426 s3426 s3425 vdd vdd pch W=1u L=0.18u
Cl3426 s3426 0 10f
Mn3427 s3427 s3426 0 0 nch W=0.5u L=0.18u
Mp3427 s3427 s3426 vdd vdd pch W=1u L=0.18u
Cl3427 s3427 0 10f
Mn3428 s3428 s3427 0 0 nch W=0.5u L=0.18u
Mp3428 s3428 s3427 vdd vdd pch W=1u L=0.18u
Cl3428 s3428 0 10f
Mn3429 s3429 s3428 0 0 nch W=0.5u L=0.18u
Mp3429 s3429 s3428 vdd vdd pch W=1u L=0.18u
Cl3429 s3429 0 10f
Mn3430 s3430 s3429 0 0 nch W=0.5u L=0.18u
Mp3430 s3430 s3429 vdd vdd pch W=1u L=0.18u
Cl3430 s3430 0 10f
Mn3431 s3431 s3430 0 0 nch W=0.5u L=0.18u
Mp3431 s3431 s3430 vdd vdd pch W=1u L=0.18u
Cl3431 s3431 0 10f
Mn3432 s3432 s3431 0 0 nch W=0.5u L=0.18u
Mp3432 s3432 s3431 vdd vdd pch W=1u L=0.18u
Cl3432 s3432 0 10f
Mn3433 s3433 s3432 0 0 nch W=0.5u L=0.18u
Mp3433 s3433 s3432 vdd vdd pch W=1u L=0.18u
Cl3433 s3433 0 10f
Mn3434 s3434 s3433 0 0 nch W=0.5u L=0.18u
Mp3434 s3434 s3433 vdd vdd pch W=1u L=0.18u
Cl3434 s3434 0 10f
Mn3435 s3435 s3434 0 0 nch W=0.5u L=0.18u
Mp3435 s3435 s3434 vdd vdd pch W=1u L=0.18u
Cl3435 s3435 0 10f
Mn3436 s3436 s3435 0 0 nch W=0.5u L=0.18u
Mp3436 s3436 s3435 vdd vdd pch W=1u L=0.18u
Cl3436 s3436 0 10f
Mn3437 s3437 s3436 0 0 nch W=0.5u L=0.18u
Mp3437 s3437 s3436 vdd vdd pch W=1u L=0.18u
Cl3437 s3437 0 10f
Mn3438 s3438 s3437 0 0 nch W=0.5u L=0.18u
Mp3438 s3438 s3437 vdd vdd pch W=1u L=0.18u
Cl3438 s3438 0 10f
Mn3439 s3439 s3438 0 0 nch W=0.5u L=0.18u
Mp3439 s3439 s3438 vdd vdd pch W=1u L=0.18u
Cl3439 s3439 0 10f
Mn3440 s3440 s3439 0 0 nch W=0.5u L=0.18u
Mp3440 s3440 s3439 vdd vdd pch W=1u L=0.18u
Cl3440 s3440 0 10f
Mn3441 s3441 s3440 0 0 nch W=0.5u L=0.18u
Mp3441 s3441 s3440 vdd vdd pch W=1u L=0.18u
Cl3441 s3441 0 10f
Mn3442 s3442 s3441 0 0 nch W=0.5u L=0.18u
Mp3442 s3442 s3441 vdd vdd pch W=1u L=0.18u
Cl3442 s3442 0 10f
Mn3443 s3443 s3442 0 0 nch W=0.5u L=0.18u
Mp3443 s3443 s3442 vdd vdd pch W=1u L=0.18u
Cl3443 s3443 0 10f
Mn3444 s3444 s3443 0 0 nch W=0.5u L=0.18u
Mp3444 s3444 s3443 vdd vdd pch W=1u L=0.18u
Cl3444 s3444 0 10f
Mn3445 s3445 s3444 0 0 nch W=0.5u L=0.18u
Mp3445 s3445 s3444 vdd vdd pch W=1u L=0.18u
Cl3445 s3445 0 10f
Mn3446 s3446 s3445 0 0 nch W=0.5u L=0.18u
Mp3446 s3446 s3445 vdd vdd pch W=1u L=0.18u
Cl3446 s3446 0 10f
Mn3447 s3447 s3446 0 0 nch W=0.5u L=0.18u
Mp3447 s3447 s3446 vdd vdd pch W=1u L=0.18u
Cl3447 s3447 0 10f
Mn3448 s3448 s3447 0 0 nch W=0.5u L=0.18u
Mp3448 s3448 s3447 vdd vdd pch W=1u L=0.18u
Cl3448 s3448 0 10f
Mn3449 s3449 s3448 0 0 nch W=0.5u L=0.18u
Mp3449 s3449 s3448 vdd vdd pch W=1u L=0.18u
Cl3449 s3449 0 10f
Mn3450 s3450 s3449 0 0 nch W=0.5u L=0.18u
Mp3450 s3450 s3449 vdd vdd pch W=1u L=0.18u
Cl3450 s3450 0 10f
Mn3451 s3451 s3450 0 0 nch W=0.5u L=0.18u
Mp3451 s3451 s3450 vdd vdd pch W=1u L=0.18u
Cl3451 s3451 0 10f
Mn3452 s3452 s3451 0 0 nch W=0.5u L=0.18u
Mp3452 s3452 s3451 vdd vdd pch W=1u L=0.18u
Cl3452 s3452 0 10f
Mn3453 s3453 s3452 0 0 nch W=0.5u L=0.18u
Mp3453 s3453 s3452 vdd vdd pch W=1u L=0.18u
Cl3453 s3453 0 10f
Mn3454 s3454 s3453 0 0 nch W=0.5u L=0.18u
Mp3454 s3454 s3453 vdd vdd pch W=1u L=0.18u
Cl3454 s3454 0 10f
Mn3455 s3455 s3454 0 0 nch W=0.5u L=0.18u
Mp3455 s3455 s3454 vdd vdd pch W=1u L=0.18u
Cl3455 s3455 0 10f
Mn3456 s3456 s3455 0 0 nch W=0.5u L=0.18u
Mp3456 s3456 s3455 vdd vdd pch W=1u L=0.18u
Cl3456 s3456 0 10f
Mn3457 s3457 s3456 0 0 nch W=0.5u L=0.18u
Mp3457 s3457 s3456 vdd vdd pch W=1u L=0.18u
Cl3457 s3457 0 10f
Mn3458 s3458 s3457 0 0 nch W=0.5u L=0.18u
Mp3458 s3458 s3457 vdd vdd pch W=1u L=0.18u
Cl3458 s3458 0 10f
Mn3459 s3459 s3458 0 0 nch W=0.5u L=0.18u
Mp3459 s3459 s3458 vdd vdd pch W=1u L=0.18u
Cl3459 s3459 0 10f
Mn3460 s3460 s3459 0 0 nch W=0.5u L=0.18u
Mp3460 s3460 s3459 vdd vdd pch W=1u L=0.18u
Cl3460 s3460 0 10f
Mn3461 s3461 s3460 0 0 nch W=0.5u L=0.18u
Mp3461 s3461 s3460 vdd vdd pch W=1u L=0.18u
Cl3461 s3461 0 10f
Mn3462 s3462 s3461 0 0 nch W=0.5u L=0.18u
Mp3462 s3462 s3461 vdd vdd pch W=1u L=0.18u
Cl3462 s3462 0 10f
Mn3463 s3463 s3462 0 0 nch W=0.5u L=0.18u
Mp3463 s3463 s3462 vdd vdd pch W=1u L=0.18u
Cl3463 s3463 0 10f
Mn3464 s3464 s3463 0 0 nch W=0.5u L=0.18u
Mp3464 s3464 s3463 vdd vdd pch W=1u L=0.18u
Cl3464 s3464 0 10f
Mn3465 s3465 s3464 0 0 nch W=0.5u L=0.18u
Mp3465 s3465 s3464 vdd vdd pch W=1u L=0.18u
Cl3465 s3465 0 10f
Mn3466 s3466 s3465 0 0 nch W=0.5u L=0.18u
Mp3466 s3466 s3465 vdd vdd pch W=1u L=0.18u
Cl3466 s3466 0 10f
Mn3467 s3467 s3466 0 0 nch W=0.5u L=0.18u
Mp3467 s3467 s3466 vdd vdd pch W=1u L=0.18u
Cl3467 s3467 0 10f
Mn3468 s3468 s3467 0 0 nch W=0.5u L=0.18u
Mp3468 s3468 s3467 vdd vdd pch W=1u L=0.18u
Cl3468 s3468 0 10f
Mn3469 s3469 s3468 0 0 nch W=0.5u L=0.18u
Mp3469 s3469 s3468 vdd vdd pch W=1u L=0.18u
Cl3469 s3469 0 10f
Mn3470 s3470 s3469 0 0 nch W=0.5u L=0.18u
Mp3470 s3470 s3469 vdd vdd pch W=1u L=0.18u
Cl3470 s3470 0 10f
Mn3471 s3471 s3470 0 0 nch W=0.5u L=0.18u
Mp3471 s3471 s3470 vdd vdd pch W=1u L=0.18u
Cl3471 s3471 0 10f
Mn3472 s3472 s3471 0 0 nch W=0.5u L=0.18u
Mp3472 s3472 s3471 vdd vdd pch W=1u L=0.18u
Cl3472 s3472 0 10f
Mn3473 s3473 s3472 0 0 nch W=0.5u L=0.18u
Mp3473 s3473 s3472 vdd vdd pch W=1u L=0.18u
Cl3473 s3473 0 10f
Mn3474 s3474 s3473 0 0 nch W=0.5u L=0.18u
Mp3474 s3474 s3473 vdd vdd pch W=1u L=0.18u
Cl3474 s3474 0 10f
Mn3475 s3475 s3474 0 0 nch W=0.5u L=0.18u
Mp3475 s3475 s3474 vdd vdd pch W=1u L=0.18u
Cl3475 s3475 0 10f
Mn3476 s3476 s3475 0 0 nch W=0.5u L=0.18u
Mp3476 s3476 s3475 vdd vdd pch W=1u L=0.18u
Cl3476 s3476 0 10f
Mn3477 s3477 s3476 0 0 nch W=0.5u L=0.18u
Mp3477 s3477 s3476 vdd vdd pch W=1u L=0.18u
Cl3477 s3477 0 10f
Mn3478 s3478 s3477 0 0 nch W=0.5u L=0.18u
Mp3478 s3478 s3477 vdd vdd pch W=1u L=0.18u
Cl3478 s3478 0 10f
Mn3479 s3479 s3478 0 0 nch W=0.5u L=0.18u
Mp3479 s3479 s3478 vdd vdd pch W=1u L=0.18u
Cl3479 s3479 0 10f
Mn3480 s3480 s3479 0 0 nch W=0.5u L=0.18u
Mp3480 s3480 s3479 vdd vdd pch W=1u L=0.18u
Cl3480 s3480 0 10f
Mn3481 s3481 s3480 0 0 nch W=0.5u L=0.18u
Mp3481 s3481 s3480 vdd vdd pch W=1u L=0.18u
Cl3481 s3481 0 10f
Mn3482 s3482 s3481 0 0 nch W=0.5u L=0.18u
Mp3482 s3482 s3481 vdd vdd pch W=1u L=0.18u
Cl3482 s3482 0 10f
Mn3483 s3483 s3482 0 0 nch W=0.5u L=0.18u
Mp3483 s3483 s3482 vdd vdd pch W=1u L=0.18u
Cl3483 s3483 0 10f
Mn3484 s3484 s3483 0 0 nch W=0.5u L=0.18u
Mp3484 s3484 s3483 vdd vdd pch W=1u L=0.18u
Cl3484 s3484 0 10f
Mn3485 s3485 s3484 0 0 nch W=0.5u L=0.18u
Mp3485 s3485 s3484 vdd vdd pch W=1u L=0.18u
Cl3485 s3485 0 10f
Mn3486 s3486 s3485 0 0 nch W=0.5u L=0.18u
Mp3486 s3486 s3485 vdd vdd pch W=1u L=0.18u
Cl3486 s3486 0 10f
Mn3487 s3487 s3486 0 0 nch W=0.5u L=0.18u
Mp3487 s3487 s3486 vdd vdd pch W=1u L=0.18u
Cl3487 s3487 0 10f
Mn3488 s3488 s3487 0 0 nch W=0.5u L=0.18u
Mp3488 s3488 s3487 vdd vdd pch W=1u L=0.18u
Cl3488 s3488 0 10f
Mn3489 s3489 s3488 0 0 nch W=0.5u L=0.18u
Mp3489 s3489 s3488 vdd vdd pch W=1u L=0.18u
Cl3489 s3489 0 10f
Mn3490 s3490 s3489 0 0 nch W=0.5u L=0.18u
Mp3490 s3490 s3489 vdd vdd pch W=1u L=0.18u
Cl3490 s3490 0 10f
Mn3491 s3491 s3490 0 0 nch W=0.5u L=0.18u
Mp3491 s3491 s3490 vdd vdd pch W=1u L=0.18u
Cl3491 s3491 0 10f
Mn3492 s3492 s3491 0 0 nch W=0.5u L=0.18u
Mp3492 s3492 s3491 vdd vdd pch W=1u L=0.18u
Cl3492 s3492 0 10f
Mn3493 s3493 s3492 0 0 nch W=0.5u L=0.18u
Mp3493 s3493 s3492 vdd vdd pch W=1u L=0.18u
Cl3493 s3493 0 10f
Mn3494 s3494 s3493 0 0 nch W=0.5u L=0.18u
Mp3494 s3494 s3493 vdd vdd pch W=1u L=0.18u
Cl3494 s3494 0 10f
Mn3495 s3495 s3494 0 0 nch W=0.5u L=0.18u
Mp3495 s3495 s3494 vdd vdd pch W=1u L=0.18u
Cl3495 s3495 0 10f
Mn3496 s3496 s3495 0 0 nch W=0.5u L=0.18u
Mp3496 s3496 s3495 vdd vdd pch W=1u L=0.18u
Cl3496 s3496 0 10f
Mn3497 s3497 s3496 0 0 nch W=0.5u L=0.18u
Mp3497 s3497 s3496 vdd vdd pch W=1u L=0.18u
Cl3497 s3497 0 10f
Mn3498 s3498 s3497 0 0 nch W=0.5u L=0.18u
Mp3498 s3498 s3497 vdd vdd pch W=1u L=0.18u
Cl3498 s3498 0 10f
Mn3499 s3499 s3498 0 0 nch W=0.5u L=0.18u
Mp3499 s3499 s3498 vdd vdd pch W=1u L=0.18u
Cl3499 s3499 0 10f
Mn3500 s3500 s3499 0 0 nch W=0.5u L=0.18u
Mp3500 s3500 s3499 vdd vdd pch W=1u L=0.18u
Cl3500 s3500 0 10f
Mn3501 s3501 s3500 0 0 nch W=0.5u L=0.18u
Mp3501 s3501 s3500 vdd vdd pch W=1u L=0.18u
Cl3501 s3501 0 10f
Mn3502 s3502 s3501 0 0 nch W=0.5u L=0.18u
Mp3502 s3502 s3501 vdd vdd pch W=1u L=0.18u
Cl3502 s3502 0 10f
Mn3503 s3503 s3502 0 0 nch W=0.5u L=0.18u
Mp3503 s3503 s3502 vdd vdd pch W=1u L=0.18u
Cl3503 s3503 0 10f
Mn3504 s3504 s3503 0 0 nch W=0.5u L=0.18u
Mp3504 s3504 s3503 vdd vdd pch W=1u L=0.18u
Cl3504 s3504 0 10f
Mn3505 s3505 s3504 0 0 nch W=0.5u L=0.18u
Mp3505 s3505 s3504 vdd vdd pch W=1u L=0.18u
Cl3505 s3505 0 10f
Mn3506 s3506 s3505 0 0 nch W=0.5u L=0.18u
Mp3506 s3506 s3505 vdd vdd pch W=1u L=0.18u
Cl3506 s3506 0 10f
Mn3507 s3507 s3506 0 0 nch W=0.5u L=0.18u
Mp3507 s3507 s3506 vdd vdd pch W=1u L=0.18u
Cl3507 s3507 0 10f
Mn3508 s3508 s3507 0 0 nch W=0.5u L=0.18u
Mp3508 s3508 s3507 vdd vdd pch W=1u L=0.18u
Cl3508 s3508 0 10f
Mn3509 s3509 s3508 0 0 nch W=0.5u L=0.18u
Mp3509 s3509 s3508 vdd vdd pch W=1u L=0.18u
Cl3509 s3509 0 10f
Mn3510 s3510 s3509 0 0 nch W=0.5u L=0.18u
Mp3510 s3510 s3509 vdd vdd pch W=1u L=0.18u
Cl3510 s3510 0 10f
Mn3511 s3511 s3510 0 0 nch W=0.5u L=0.18u
Mp3511 s3511 s3510 vdd vdd pch W=1u L=0.18u
Cl3511 s3511 0 10f
Mn3512 s3512 s3511 0 0 nch W=0.5u L=0.18u
Mp3512 s3512 s3511 vdd vdd pch W=1u L=0.18u
Cl3512 s3512 0 10f
Mn3513 s3513 s3512 0 0 nch W=0.5u L=0.18u
Mp3513 s3513 s3512 vdd vdd pch W=1u L=0.18u
Cl3513 s3513 0 10f
Mn3514 s3514 s3513 0 0 nch W=0.5u L=0.18u
Mp3514 s3514 s3513 vdd vdd pch W=1u L=0.18u
Cl3514 s3514 0 10f
Mn3515 s3515 s3514 0 0 nch W=0.5u L=0.18u
Mp3515 s3515 s3514 vdd vdd pch W=1u L=0.18u
Cl3515 s3515 0 10f
Mn3516 s3516 s3515 0 0 nch W=0.5u L=0.18u
Mp3516 s3516 s3515 vdd vdd pch W=1u L=0.18u
Cl3516 s3516 0 10f
Mn3517 s3517 s3516 0 0 nch W=0.5u L=0.18u
Mp3517 s3517 s3516 vdd vdd pch W=1u L=0.18u
Cl3517 s3517 0 10f
Mn3518 s3518 s3517 0 0 nch W=0.5u L=0.18u
Mp3518 s3518 s3517 vdd vdd pch W=1u L=0.18u
Cl3518 s3518 0 10f
Mn3519 s3519 s3518 0 0 nch W=0.5u L=0.18u
Mp3519 s3519 s3518 vdd vdd pch W=1u L=0.18u
Cl3519 s3519 0 10f
Mn3520 s3520 s3519 0 0 nch W=0.5u L=0.18u
Mp3520 s3520 s3519 vdd vdd pch W=1u L=0.18u
Cl3520 s3520 0 10f
Mn3521 s3521 s3520 0 0 nch W=0.5u L=0.18u
Mp3521 s3521 s3520 vdd vdd pch W=1u L=0.18u
Cl3521 s3521 0 10f
Mn3522 s3522 s3521 0 0 nch W=0.5u L=0.18u
Mp3522 s3522 s3521 vdd vdd pch W=1u L=0.18u
Cl3522 s3522 0 10f
Mn3523 s3523 s3522 0 0 nch W=0.5u L=0.18u
Mp3523 s3523 s3522 vdd vdd pch W=1u L=0.18u
Cl3523 s3523 0 10f
Mn3524 s3524 s3523 0 0 nch W=0.5u L=0.18u
Mp3524 s3524 s3523 vdd vdd pch W=1u L=0.18u
Cl3524 s3524 0 10f
Mn3525 s3525 s3524 0 0 nch W=0.5u L=0.18u
Mp3525 s3525 s3524 vdd vdd pch W=1u L=0.18u
Cl3525 s3525 0 10f
Mn3526 s3526 s3525 0 0 nch W=0.5u L=0.18u
Mp3526 s3526 s3525 vdd vdd pch W=1u L=0.18u
Cl3526 s3526 0 10f
Mn3527 s3527 s3526 0 0 nch W=0.5u L=0.18u
Mp3527 s3527 s3526 vdd vdd pch W=1u L=0.18u
Cl3527 s3527 0 10f
Mn3528 s3528 s3527 0 0 nch W=0.5u L=0.18u
Mp3528 s3528 s3527 vdd vdd pch W=1u L=0.18u
Cl3528 s3528 0 10f
Mn3529 s3529 s3528 0 0 nch W=0.5u L=0.18u
Mp3529 s3529 s3528 vdd vdd pch W=1u L=0.18u
Cl3529 s3529 0 10f
Mn3530 s3530 s3529 0 0 nch W=0.5u L=0.18u
Mp3530 s3530 s3529 vdd vdd pch W=1u L=0.18u
Cl3530 s3530 0 10f
Mn3531 s3531 s3530 0 0 nch W=0.5u L=0.18u
Mp3531 s3531 s3530 vdd vdd pch W=1u L=0.18u
Cl3531 s3531 0 10f
Mn3532 s3532 s3531 0 0 nch W=0.5u L=0.18u
Mp3532 s3532 s3531 vdd vdd pch W=1u L=0.18u
Cl3532 s3532 0 10f
Mn3533 s3533 s3532 0 0 nch W=0.5u L=0.18u
Mp3533 s3533 s3532 vdd vdd pch W=1u L=0.18u
Cl3533 s3533 0 10f
Mn3534 s3534 s3533 0 0 nch W=0.5u L=0.18u
Mp3534 s3534 s3533 vdd vdd pch W=1u L=0.18u
Cl3534 s3534 0 10f
Mn3535 s3535 s3534 0 0 nch W=0.5u L=0.18u
Mp3535 s3535 s3534 vdd vdd pch W=1u L=0.18u
Cl3535 s3535 0 10f
Mn3536 s3536 s3535 0 0 nch W=0.5u L=0.18u
Mp3536 s3536 s3535 vdd vdd pch W=1u L=0.18u
Cl3536 s3536 0 10f
Mn3537 s3537 s3536 0 0 nch W=0.5u L=0.18u
Mp3537 s3537 s3536 vdd vdd pch W=1u L=0.18u
Cl3537 s3537 0 10f
Mn3538 s3538 s3537 0 0 nch W=0.5u L=0.18u
Mp3538 s3538 s3537 vdd vdd pch W=1u L=0.18u
Cl3538 s3538 0 10f
Mn3539 s3539 s3538 0 0 nch W=0.5u L=0.18u
Mp3539 s3539 s3538 vdd vdd pch W=1u L=0.18u
Cl3539 s3539 0 10f
Mn3540 s3540 s3539 0 0 nch W=0.5u L=0.18u
Mp3540 s3540 s3539 vdd vdd pch W=1u L=0.18u
Cl3540 s3540 0 10f
Mn3541 s3541 s3540 0 0 nch W=0.5u L=0.18u
Mp3541 s3541 s3540 vdd vdd pch W=1u L=0.18u
Cl3541 s3541 0 10f
Mn3542 s3542 s3541 0 0 nch W=0.5u L=0.18u
Mp3542 s3542 s3541 vdd vdd pch W=1u L=0.18u
Cl3542 s3542 0 10f
Mn3543 s3543 s3542 0 0 nch W=0.5u L=0.18u
Mp3543 s3543 s3542 vdd vdd pch W=1u L=0.18u
Cl3543 s3543 0 10f
Mn3544 s3544 s3543 0 0 nch W=0.5u L=0.18u
Mp3544 s3544 s3543 vdd vdd pch W=1u L=0.18u
Cl3544 s3544 0 10f
Mn3545 s3545 s3544 0 0 nch W=0.5u L=0.18u
Mp3545 s3545 s3544 vdd vdd pch W=1u L=0.18u
Cl3545 s3545 0 10f
Mn3546 s3546 s3545 0 0 nch W=0.5u L=0.18u
Mp3546 s3546 s3545 vdd vdd pch W=1u L=0.18u
Cl3546 s3546 0 10f
Mn3547 s3547 s3546 0 0 nch W=0.5u L=0.18u
Mp3547 s3547 s3546 vdd vdd pch W=1u L=0.18u
Cl3547 s3547 0 10f
Mn3548 s3548 s3547 0 0 nch W=0.5u L=0.18u
Mp3548 s3548 s3547 vdd vdd pch W=1u L=0.18u
Cl3548 s3548 0 10f
Mn3549 s3549 s3548 0 0 nch W=0.5u L=0.18u
Mp3549 s3549 s3548 vdd vdd pch W=1u L=0.18u
Cl3549 s3549 0 10f
Mn3550 s3550 s3549 0 0 nch W=0.5u L=0.18u
Mp3550 s3550 s3549 vdd vdd pch W=1u L=0.18u
Cl3550 s3550 0 10f
Mn3551 s3551 s3550 0 0 nch W=0.5u L=0.18u
Mp3551 s3551 s3550 vdd vdd pch W=1u L=0.18u
Cl3551 s3551 0 10f
Mn3552 s3552 s3551 0 0 nch W=0.5u L=0.18u
Mp3552 s3552 s3551 vdd vdd pch W=1u L=0.18u
Cl3552 s3552 0 10f
Mn3553 s3553 s3552 0 0 nch W=0.5u L=0.18u
Mp3553 s3553 s3552 vdd vdd pch W=1u L=0.18u
Cl3553 s3553 0 10f
Mn3554 s3554 s3553 0 0 nch W=0.5u L=0.18u
Mp3554 s3554 s3553 vdd vdd pch W=1u L=0.18u
Cl3554 s3554 0 10f
Mn3555 s3555 s3554 0 0 nch W=0.5u L=0.18u
Mp3555 s3555 s3554 vdd vdd pch W=1u L=0.18u
Cl3555 s3555 0 10f
Mn3556 s3556 s3555 0 0 nch W=0.5u L=0.18u
Mp3556 s3556 s3555 vdd vdd pch W=1u L=0.18u
Cl3556 s3556 0 10f
Mn3557 s3557 s3556 0 0 nch W=0.5u L=0.18u
Mp3557 s3557 s3556 vdd vdd pch W=1u L=0.18u
Cl3557 s3557 0 10f
Mn3558 s3558 s3557 0 0 nch W=0.5u L=0.18u
Mp3558 s3558 s3557 vdd vdd pch W=1u L=0.18u
Cl3558 s3558 0 10f
Mn3559 s3559 s3558 0 0 nch W=0.5u L=0.18u
Mp3559 s3559 s3558 vdd vdd pch W=1u L=0.18u
Cl3559 s3559 0 10f
Mn3560 s3560 s3559 0 0 nch W=0.5u L=0.18u
Mp3560 s3560 s3559 vdd vdd pch W=1u L=0.18u
Cl3560 s3560 0 10f
Mn3561 s3561 s3560 0 0 nch W=0.5u L=0.18u
Mp3561 s3561 s3560 vdd vdd pch W=1u L=0.18u
Cl3561 s3561 0 10f
Mn3562 s3562 s3561 0 0 nch W=0.5u L=0.18u
Mp3562 s3562 s3561 vdd vdd pch W=1u L=0.18u
Cl3562 s3562 0 10f
Mn3563 s3563 s3562 0 0 nch W=0.5u L=0.18u
Mp3563 s3563 s3562 vdd vdd pch W=1u L=0.18u
Cl3563 s3563 0 10f
Mn3564 s3564 s3563 0 0 nch W=0.5u L=0.18u
Mp3564 s3564 s3563 vdd vdd pch W=1u L=0.18u
Cl3564 s3564 0 10f
Mn3565 s3565 s3564 0 0 nch W=0.5u L=0.18u
Mp3565 s3565 s3564 vdd vdd pch W=1u L=0.18u
Cl3565 s3565 0 10f
Mn3566 s3566 s3565 0 0 nch W=0.5u L=0.18u
Mp3566 s3566 s3565 vdd vdd pch W=1u L=0.18u
Cl3566 s3566 0 10f
Mn3567 s3567 s3566 0 0 nch W=0.5u L=0.18u
Mp3567 s3567 s3566 vdd vdd pch W=1u L=0.18u
Cl3567 s3567 0 10f
Mn3568 s3568 s3567 0 0 nch W=0.5u L=0.18u
Mp3568 s3568 s3567 vdd vdd pch W=1u L=0.18u
Cl3568 s3568 0 10f
Mn3569 s3569 s3568 0 0 nch W=0.5u L=0.18u
Mp3569 s3569 s3568 vdd vdd pch W=1u L=0.18u
Cl3569 s3569 0 10f
Mn3570 s3570 s3569 0 0 nch W=0.5u L=0.18u
Mp3570 s3570 s3569 vdd vdd pch W=1u L=0.18u
Cl3570 s3570 0 10f
Mn3571 s3571 s3570 0 0 nch W=0.5u L=0.18u
Mp3571 s3571 s3570 vdd vdd pch W=1u L=0.18u
Cl3571 s3571 0 10f
Mn3572 s3572 s3571 0 0 nch W=0.5u L=0.18u
Mp3572 s3572 s3571 vdd vdd pch W=1u L=0.18u
Cl3572 s3572 0 10f
Mn3573 s3573 s3572 0 0 nch W=0.5u L=0.18u
Mp3573 s3573 s3572 vdd vdd pch W=1u L=0.18u
Cl3573 s3573 0 10f
Mn3574 s3574 s3573 0 0 nch W=0.5u L=0.18u
Mp3574 s3574 s3573 vdd vdd pch W=1u L=0.18u
Cl3574 s3574 0 10f
Mn3575 s3575 s3574 0 0 nch W=0.5u L=0.18u
Mp3575 s3575 s3574 vdd vdd pch W=1u L=0.18u
Cl3575 s3575 0 10f
Mn3576 s3576 s3575 0 0 nch W=0.5u L=0.18u
Mp3576 s3576 s3575 vdd vdd pch W=1u L=0.18u
Cl3576 s3576 0 10f
Mn3577 s3577 s3576 0 0 nch W=0.5u L=0.18u
Mp3577 s3577 s3576 vdd vdd pch W=1u L=0.18u
Cl3577 s3577 0 10f
Mn3578 s3578 s3577 0 0 nch W=0.5u L=0.18u
Mp3578 s3578 s3577 vdd vdd pch W=1u L=0.18u
Cl3578 s3578 0 10f
Mn3579 s3579 s3578 0 0 nch W=0.5u L=0.18u
Mp3579 s3579 s3578 vdd vdd pch W=1u L=0.18u
Cl3579 s3579 0 10f
Mn3580 s3580 s3579 0 0 nch W=0.5u L=0.18u
Mp3580 s3580 s3579 vdd vdd pch W=1u L=0.18u
Cl3580 s3580 0 10f
Mn3581 s3581 s3580 0 0 nch W=0.5u L=0.18u
Mp3581 s3581 s3580 vdd vdd pch W=1u L=0.18u
Cl3581 s3581 0 10f
Mn3582 s3582 s3581 0 0 nch W=0.5u L=0.18u
Mp3582 s3582 s3581 vdd vdd pch W=1u L=0.18u
Cl3582 s3582 0 10f
Mn3583 s3583 s3582 0 0 nch W=0.5u L=0.18u
Mp3583 s3583 s3582 vdd vdd pch W=1u L=0.18u
Cl3583 s3583 0 10f
Mn3584 s3584 s3583 0 0 nch W=0.5u L=0.18u
Mp3584 s3584 s3583 vdd vdd pch W=1u L=0.18u
Cl3584 s3584 0 10f
Mn3585 s3585 s3584 0 0 nch W=0.5u L=0.18u
Mp3585 s3585 s3584 vdd vdd pch W=1u L=0.18u
Cl3585 s3585 0 10f
Mn3586 s3586 s3585 0 0 nch W=0.5u L=0.18u
Mp3586 s3586 s3585 vdd vdd pch W=1u L=0.18u
Cl3586 s3586 0 10f
Mn3587 s3587 s3586 0 0 nch W=0.5u L=0.18u
Mp3587 s3587 s3586 vdd vdd pch W=1u L=0.18u
Cl3587 s3587 0 10f
Mn3588 s3588 s3587 0 0 nch W=0.5u L=0.18u
Mp3588 s3588 s3587 vdd vdd pch W=1u L=0.18u
Cl3588 s3588 0 10f
Mn3589 s3589 s3588 0 0 nch W=0.5u L=0.18u
Mp3589 s3589 s3588 vdd vdd pch W=1u L=0.18u
Cl3589 s3589 0 10f
Mn3590 s3590 s3589 0 0 nch W=0.5u L=0.18u
Mp3590 s3590 s3589 vdd vdd pch W=1u L=0.18u
Cl3590 s3590 0 10f
Mn3591 s3591 s3590 0 0 nch W=0.5u L=0.18u
Mp3591 s3591 s3590 vdd vdd pch W=1u L=0.18u
Cl3591 s3591 0 10f
Mn3592 s3592 s3591 0 0 nch W=0.5u L=0.18u
Mp3592 s3592 s3591 vdd vdd pch W=1u L=0.18u
Cl3592 s3592 0 10f
Mn3593 s3593 s3592 0 0 nch W=0.5u L=0.18u
Mp3593 s3593 s3592 vdd vdd pch W=1u L=0.18u
Cl3593 s3593 0 10f
Mn3594 s3594 s3593 0 0 nch W=0.5u L=0.18u
Mp3594 s3594 s3593 vdd vdd pch W=1u L=0.18u
Cl3594 s3594 0 10f
Mn3595 s3595 s3594 0 0 nch W=0.5u L=0.18u
Mp3595 s3595 s3594 vdd vdd pch W=1u L=0.18u
Cl3595 s3595 0 10f
Mn3596 s3596 s3595 0 0 nch W=0.5u L=0.18u
Mp3596 s3596 s3595 vdd vdd pch W=1u L=0.18u
Cl3596 s3596 0 10f
Mn3597 s3597 s3596 0 0 nch W=0.5u L=0.18u
Mp3597 s3597 s3596 vdd vdd pch W=1u L=0.18u
Cl3597 s3597 0 10f
Mn3598 s3598 s3597 0 0 nch W=0.5u L=0.18u
Mp3598 s3598 s3597 vdd vdd pch W=1u L=0.18u
Cl3598 s3598 0 10f
Mn3599 s3599 s3598 0 0 nch W=0.5u L=0.18u
Mp3599 s3599 s3598 vdd vdd pch W=1u L=0.18u
Cl3599 s3599 0 10f
Mn3600 s3600 s3599 0 0 nch W=0.5u L=0.18u
Mp3600 s3600 s3599 vdd vdd pch W=1u L=0.18u
Cl3600 s3600 0 10f
Mn3601 s3601 s3600 0 0 nch W=0.5u L=0.18u
Mp3601 s3601 s3600 vdd vdd pch W=1u L=0.18u
Cl3601 s3601 0 10f
Mn3602 s3602 s3601 0 0 nch W=0.5u L=0.18u
Mp3602 s3602 s3601 vdd vdd pch W=1u L=0.18u
Cl3602 s3602 0 10f
Mn3603 s3603 s3602 0 0 nch W=0.5u L=0.18u
Mp3603 s3603 s3602 vdd vdd pch W=1u L=0.18u
Cl3603 s3603 0 10f
Mn3604 s3604 s3603 0 0 nch W=0.5u L=0.18u
Mp3604 s3604 s3603 vdd vdd pch W=1u L=0.18u
Cl3604 s3604 0 10f
Mn3605 s3605 s3604 0 0 nch W=0.5u L=0.18u
Mp3605 s3605 s3604 vdd vdd pch W=1u L=0.18u
Cl3605 s3605 0 10f
Mn3606 s3606 s3605 0 0 nch W=0.5u L=0.18u
Mp3606 s3606 s3605 vdd vdd pch W=1u L=0.18u
Cl3606 s3606 0 10f
Mn3607 s3607 s3606 0 0 nch W=0.5u L=0.18u
Mp3607 s3607 s3606 vdd vdd pch W=1u L=0.18u
Cl3607 s3607 0 10f
Mn3608 s3608 s3607 0 0 nch W=0.5u L=0.18u
Mp3608 s3608 s3607 vdd vdd pch W=1u L=0.18u
Cl3608 s3608 0 10f
Mn3609 s3609 s3608 0 0 nch W=0.5u L=0.18u
Mp3609 s3609 s3608 vdd vdd pch W=1u L=0.18u
Cl3609 s3609 0 10f
Mn3610 s3610 s3609 0 0 nch W=0.5u L=0.18u
Mp3610 s3610 s3609 vdd vdd pch W=1u L=0.18u
Cl3610 s3610 0 10f
Mn3611 s3611 s3610 0 0 nch W=0.5u L=0.18u
Mp3611 s3611 s3610 vdd vdd pch W=1u L=0.18u
Cl3611 s3611 0 10f
Mn3612 s3612 s3611 0 0 nch W=0.5u L=0.18u
Mp3612 s3612 s3611 vdd vdd pch W=1u L=0.18u
Cl3612 s3612 0 10f
Mn3613 s3613 s3612 0 0 nch W=0.5u L=0.18u
Mp3613 s3613 s3612 vdd vdd pch W=1u L=0.18u
Cl3613 s3613 0 10f
Mn3614 s3614 s3613 0 0 nch W=0.5u L=0.18u
Mp3614 s3614 s3613 vdd vdd pch W=1u L=0.18u
Cl3614 s3614 0 10f
Mn3615 s3615 s3614 0 0 nch W=0.5u L=0.18u
Mp3615 s3615 s3614 vdd vdd pch W=1u L=0.18u
Cl3615 s3615 0 10f
Mn3616 s3616 s3615 0 0 nch W=0.5u L=0.18u
Mp3616 s3616 s3615 vdd vdd pch W=1u L=0.18u
Cl3616 s3616 0 10f
Mn3617 s3617 s3616 0 0 nch W=0.5u L=0.18u
Mp3617 s3617 s3616 vdd vdd pch W=1u L=0.18u
Cl3617 s3617 0 10f
Mn3618 s3618 s3617 0 0 nch W=0.5u L=0.18u
Mp3618 s3618 s3617 vdd vdd pch W=1u L=0.18u
Cl3618 s3618 0 10f
Mn3619 s3619 s3618 0 0 nch W=0.5u L=0.18u
Mp3619 s3619 s3618 vdd vdd pch W=1u L=0.18u
Cl3619 s3619 0 10f
Mn3620 s3620 s3619 0 0 nch W=0.5u L=0.18u
Mp3620 s3620 s3619 vdd vdd pch W=1u L=0.18u
Cl3620 s3620 0 10f
Mn3621 s3621 s3620 0 0 nch W=0.5u L=0.18u
Mp3621 s3621 s3620 vdd vdd pch W=1u L=0.18u
Cl3621 s3621 0 10f
Mn3622 s3622 s3621 0 0 nch W=0.5u L=0.18u
Mp3622 s3622 s3621 vdd vdd pch W=1u L=0.18u
Cl3622 s3622 0 10f
Mn3623 s3623 s3622 0 0 nch W=0.5u L=0.18u
Mp3623 s3623 s3622 vdd vdd pch W=1u L=0.18u
Cl3623 s3623 0 10f
Mn3624 s3624 s3623 0 0 nch W=0.5u L=0.18u
Mp3624 s3624 s3623 vdd vdd pch W=1u L=0.18u
Cl3624 s3624 0 10f
Mn3625 s3625 s3624 0 0 nch W=0.5u L=0.18u
Mp3625 s3625 s3624 vdd vdd pch W=1u L=0.18u
Cl3625 s3625 0 10f
Mn3626 s3626 s3625 0 0 nch W=0.5u L=0.18u
Mp3626 s3626 s3625 vdd vdd pch W=1u L=0.18u
Cl3626 s3626 0 10f
Mn3627 s3627 s3626 0 0 nch W=0.5u L=0.18u
Mp3627 s3627 s3626 vdd vdd pch W=1u L=0.18u
Cl3627 s3627 0 10f
Mn3628 s3628 s3627 0 0 nch W=0.5u L=0.18u
Mp3628 s3628 s3627 vdd vdd pch W=1u L=0.18u
Cl3628 s3628 0 10f
Mn3629 s3629 s3628 0 0 nch W=0.5u L=0.18u
Mp3629 s3629 s3628 vdd vdd pch W=1u L=0.18u
Cl3629 s3629 0 10f
Mn3630 s3630 s3629 0 0 nch W=0.5u L=0.18u
Mp3630 s3630 s3629 vdd vdd pch W=1u L=0.18u
Cl3630 s3630 0 10f
Mn3631 s3631 s3630 0 0 nch W=0.5u L=0.18u
Mp3631 s3631 s3630 vdd vdd pch W=1u L=0.18u
Cl3631 s3631 0 10f
Mn3632 s3632 s3631 0 0 nch W=0.5u L=0.18u
Mp3632 s3632 s3631 vdd vdd pch W=1u L=0.18u
Cl3632 s3632 0 10f
Mn3633 s3633 s3632 0 0 nch W=0.5u L=0.18u
Mp3633 s3633 s3632 vdd vdd pch W=1u L=0.18u
Cl3633 s3633 0 10f
Mn3634 s3634 s3633 0 0 nch W=0.5u L=0.18u
Mp3634 s3634 s3633 vdd vdd pch W=1u L=0.18u
Cl3634 s3634 0 10f
Mn3635 s3635 s3634 0 0 nch W=0.5u L=0.18u
Mp3635 s3635 s3634 vdd vdd pch W=1u L=0.18u
Cl3635 s3635 0 10f
Mn3636 s3636 s3635 0 0 nch W=0.5u L=0.18u
Mp3636 s3636 s3635 vdd vdd pch W=1u L=0.18u
Cl3636 s3636 0 10f
Mn3637 s3637 s3636 0 0 nch W=0.5u L=0.18u
Mp3637 s3637 s3636 vdd vdd pch W=1u L=0.18u
Cl3637 s3637 0 10f
Mn3638 s3638 s3637 0 0 nch W=0.5u L=0.18u
Mp3638 s3638 s3637 vdd vdd pch W=1u L=0.18u
Cl3638 s3638 0 10f
Mn3639 s3639 s3638 0 0 nch W=0.5u L=0.18u
Mp3639 s3639 s3638 vdd vdd pch W=1u L=0.18u
Cl3639 s3639 0 10f
Mn3640 s3640 s3639 0 0 nch W=0.5u L=0.18u
Mp3640 s3640 s3639 vdd vdd pch W=1u L=0.18u
Cl3640 s3640 0 10f
Mn3641 s3641 s3640 0 0 nch W=0.5u L=0.18u
Mp3641 s3641 s3640 vdd vdd pch W=1u L=0.18u
Cl3641 s3641 0 10f
Mn3642 s3642 s3641 0 0 nch W=0.5u L=0.18u
Mp3642 s3642 s3641 vdd vdd pch W=1u L=0.18u
Cl3642 s3642 0 10f
Mn3643 s3643 s3642 0 0 nch W=0.5u L=0.18u
Mp3643 s3643 s3642 vdd vdd pch W=1u L=0.18u
Cl3643 s3643 0 10f
Mn3644 s3644 s3643 0 0 nch W=0.5u L=0.18u
Mp3644 s3644 s3643 vdd vdd pch W=1u L=0.18u
Cl3644 s3644 0 10f
Mn3645 s3645 s3644 0 0 nch W=0.5u L=0.18u
Mp3645 s3645 s3644 vdd vdd pch W=1u L=0.18u
Cl3645 s3645 0 10f
Mn3646 s3646 s3645 0 0 nch W=0.5u L=0.18u
Mp3646 s3646 s3645 vdd vdd pch W=1u L=0.18u
Cl3646 s3646 0 10f
Mn3647 s3647 s3646 0 0 nch W=0.5u L=0.18u
Mp3647 s3647 s3646 vdd vdd pch W=1u L=0.18u
Cl3647 s3647 0 10f
Mn3648 s3648 s3647 0 0 nch W=0.5u L=0.18u
Mp3648 s3648 s3647 vdd vdd pch W=1u L=0.18u
Cl3648 s3648 0 10f
Mn3649 s3649 s3648 0 0 nch W=0.5u L=0.18u
Mp3649 s3649 s3648 vdd vdd pch W=1u L=0.18u
Cl3649 s3649 0 10f
Mn3650 s3650 s3649 0 0 nch W=0.5u L=0.18u
Mp3650 s3650 s3649 vdd vdd pch W=1u L=0.18u
Cl3650 s3650 0 10f
Mn3651 s3651 s3650 0 0 nch W=0.5u L=0.18u
Mp3651 s3651 s3650 vdd vdd pch W=1u L=0.18u
Cl3651 s3651 0 10f
Mn3652 s3652 s3651 0 0 nch W=0.5u L=0.18u
Mp3652 s3652 s3651 vdd vdd pch W=1u L=0.18u
Cl3652 s3652 0 10f
Mn3653 s3653 s3652 0 0 nch W=0.5u L=0.18u
Mp3653 s3653 s3652 vdd vdd pch W=1u L=0.18u
Cl3653 s3653 0 10f
Mn3654 s3654 s3653 0 0 nch W=0.5u L=0.18u
Mp3654 s3654 s3653 vdd vdd pch W=1u L=0.18u
Cl3654 s3654 0 10f
Mn3655 s3655 s3654 0 0 nch W=0.5u L=0.18u
Mp3655 s3655 s3654 vdd vdd pch W=1u L=0.18u
Cl3655 s3655 0 10f
Mn3656 s3656 s3655 0 0 nch W=0.5u L=0.18u
Mp3656 s3656 s3655 vdd vdd pch W=1u L=0.18u
Cl3656 s3656 0 10f
Mn3657 s3657 s3656 0 0 nch W=0.5u L=0.18u
Mp3657 s3657 s3656 vdd vdd pch W=1u L=0.18u
Cl3657 s3657 0 10f
Mn3658 s3658 s3657 0 0 nch W=0.5u L=0.18u
Mp3658 s3658 s3657 vdd vdd pch W=1u L=0.18u
Cl3658 s3658 0 10f
Mn3659 s3659 s3658 0 0 nch W=0.5u L=0.18u
Mp3659 s3659 s3658 vdd vdd pch W=1u L=0.18u
Cl3659 s3659 0 10f
Mn3660 s3660 s3659 0 0 nch W=0.5u L=0.18u
Mp3660 s3660 s3659 vdd vdd pch W=1u L=0.18u
Cl3660 s3660 0 10f
Mn3661 s3661 s3660 0 0 nch W=0.5u L=0.18u
Mp3661 s3661 s3660 vdd vdd pch W=1u L=0.18u
Cl3661 s3661 0 10f
Mn3662 s3662 s3661 0 0 nch W=0.5u L=0.18u
Mp3662 s3662 s3661 vdd vdd pch W=1u L=0.18u
Cl3662 s3662 0 10f
Mn3663 s3663 s3662 0 0 nch W=0.5u L=0.18u
Mp3663 s3663 s3662 vdd vdd pch W=1u L=0.18u
Cl3663 s3663 0 10f
Mn3664 s3664 s3663 0 0 nch W=0.5u L=0.18u
Mp3664 s3664 s3663 vdd vdd pch W=1u L=0.18u
Cl3664 s3664 0 10f
Mn3665 s3665 s3664 0 0 nch W=0.5u L=0.18u
Mp3665 s3665 s3664 vdd vdd pch W=1u L=0.18u
Cl3665 s3665 0 10f
Mn3666 s3666 s3665 0 0 nch W=0.5u L=0.18u
Mp3666 s3666 s3665 vdd vdd pch W=1u L=0.18u
Cl3666 s3666 0 10f
Mn3667 s3667 s3666 0 0 nch W=0.5u L=0.18u
Mp3667 s3667 s3666 vdd vdd pch W=1u L=0.18u
Cl3667 s3667 0 10f
Mn3668 s3668 s3667 0 0 nch W=0.5u L=0.18u
Mp3668 s3668 s3667 vdd vdd pch W=1u L=0.18u
Cl3668 s3668 0 10f
Mn3669 s3669 s3668 0 0 nch W=0.5u L=0.18u
Mp3669 s3669 s3668 vdd vdd pch W=1u L=0.18u
Cl3669 s3669 0 10f
Mn3670 s3670 s3669 0 0 nch W=0.5u L=0.18u
Mp3670 s3670 s3669 vdd vdd pch W=1u L=0.18u
Cl3670 s3670 0 10f
Mn3671 s3671 s3670 0 0 nch W=0.5u L=0.18u
Mp3671 s3671 s3670 vdd vdd pch W=1u L=0.18u
Cl3671 s3671 0 10f
Mn3672 s3672 s3671 0 0 nch W=0.5u L=0.18u
Mp3672 s3672 s3671 vdd vdd pch W=1u L=0.18u
Cl3672 s3672 0 10f
Mn3673 s3673 s3672 0 0 nch W=0.5u L=0.18u
Mp3673 s3673 s3672 vdd vdd pch W=1u L=0.18u
Cl3673 s3673 0 10f
Mn3674 s3674 s3673 0 0 nch W=0.5u L=0.18u
Mp3674 s3674 s3673 vdd vdd pch W=1u L=0.18u
Cl3674 s3674 0 10f
Mn3675 s3675 s3674 0 0 nch W=0.5u L=0.18u
Mp3675 s3675 s3674 vdd vdd pch W=1u L=0.18u
Cl3675 s3675 0 10f
Mn3676 s3676 s3675 0 0 nch W=0.5u L=0.18u
Mp3676 s3676 s3675 vdd vdd pch W=1u L=0.18u
Cl3676 s3676 0 10f
Mn3677 s3677 s3676 0 0 nch W=0.5u L=0.18u
Mp3677 s3677 s3676 vdd vdd pch W=1u L=0.18u
Cl3677 s3677 0 10f
Mn3678 s3678 s3677 0 0 nch W=0.5u L=0.18u
Mp3678 s3678 s3677 vdd vdd pch W=1u L=0.18u
Cl3678 s3678 0 10f
Mn3679 s3679 s3678 0 0 nch W=0.5u L=0.18u
Mp3679 s3679 s3678 vdd vdd pch W=1u L=0.18u
Cl3679 s3679 0 10f
Mn3680 s3680 s3679 0 0 nch W=0.5u L=0.18u
Mp3680 s3680 s3679 vdd vdd pch W=1u L=0.18u
Cl3680 s3680 0 10f
Mn3681 s3681 s3680 0 0 nch W=0.5u L=0.18u
Mp3681 s3681 s3680 vdd vdd pch W=1u L=0.18u
Cl3681 s3681 0 10f
Mn3682 s3682 s3681 0 0 nch W=0.5u L=0.18u
Mp3682 s3682 s3681 vdd vdd pch W=1u L=0.18u
Cl3682 s3682 0 10f
Mn3683 s3683 s3682 0 0 nch W=0.5u L=0.18u
Mp3683 s3683 s3682 vdd vdd pch W=1u L=0.18u
Cl3683 s3683 0 10f
Mn3684 s3684 s3683 0 0 nch W=0.5u L=0.18u
Mp3684 s3684 s3683 vdd vdd pch W=1u L=0.18u
Cl3684 s3684 0 10f
Mn3685 s3685 s3684 0 0 nch W=0.5u L=0.18u
Mp3685 s3685 s3684 vdd vdd pch W=1u L=0.18u
Cl3685 s3685 0 10f
Mn3686 s3686 s3685 0 0 nch W=0.5u L=0.18u
Mp3686 s3686 s3685 vdd vdd pch W=1u L=0.18u
Cl3686 s3686 0 10f
Mn3687 s3687 s3686 0 0 nch W=0.5u L=0.18u
Mp3687 s3687 s3686 vdd vdd pch W=1u L=0.18u
Cl3687 s3687 0 10f
Mn3688 s3688 s3687 0 0 nch W=0.5u L=0.18u
Mp3688 s3688 s3687 vdd vdd pch W=1u L=0.18u
Cl3688 s3688 0 10f
Mn3689 s3689 s3688 0 0 nch W=0.5u L=0.18u
Mp3689 s3689 s3688 vdd vdd pch W=1u L=0.18u
Cl3689 s3689 0 10f
Mn3690 s3690 s3689 0 0 nch W=0.5u L=0.18u
Mp3690 s3690 s3689 vdd vdd pch W=1u L=0.18u
Cl3690 s3690 0 10f
Mn3691 s3691 s3690 0 0 nch W=0.5u L=0.18u
Mp3691 s3691 s3690 vdd vdd pch W=1u L=0.18u
Cl3691 s3691 0 10f
Mn3692 s3692 s3691 0 0 nch W=0.5u L=0.18u
Mp3692 s3692 s3691 vdd vdd pch W=1u L=0.18u
Cl3692 s3692 0 10f
Mn3693 s3693 s3692 0 0 nch W=0.5u L=0.18u
Mp3693 s3693 s3692 vdd vdd pch W=1u L=0.18u
Cl3693 s3693 0 10f
Mn3694 s3694 s3693 0 0 nch W=0.5u L=0.18u
Mp3694 s3694 s3693 vdd vdd pch W=1u L=0.18u
Cl3694 s3694 0 10f
Mn3695 s3695 s3694 0 0 nch W=0.5u L=0.18u
Mp3695 s3695 s3694 vdd vdd pch W=1u L=0.18u
Cl3695 s3695 0 10f
Mn3696 s3696 s3695 0 0 nch W=0.5u L=0.18u
Mp3696 s3696 s3695 vdd vdd pch W=1u L=0.18u
Cl3696 s3696 0 10f
Mn3697 s3697 s3696 0 0 nch W=0.5u L=0.18u
Mp3697 s3697 s3696 vdd vdd pch W=1u L=0.18u
Cl3697 s3697 0 10f
Mn3698 s3698 s3697 0 0 nch W=0.5u L=0.18u
Mp3698 s3698 s3697 vdd vdd pch W=1u L=0.18u
Cl3698 s3698 0 10f
Mn3699 s3699 s3698 0 0 nch W=0.5u L=0.18u
Mp3699 s3699 s3698 vdd vdd pch W=1u L=0.18u
Cl3699 s3699 0 10f
Mn3700 s3700 s3699 0 0 nch W=0.5u L=0.18u
Mp3700 s3700 s3699 vdd vdd pch W=1u L=0.18u
Cl3700 s3700 0 10f
Mn3701 s3701 s3700 0 0 nch W=0.5u L=0.18u
Mp3701 s3701 s3700 vdd vdd pch W=1u L=0.18u
Cl3701 s3701 0 10f
Mn3702 s3702 s3701 0 0 nch W=0.5u L=0.18u
Mp3702 s3702 s3701 vdd vdd pch W=1u L=0.18u
Cl3702 s3702 0 10f
Mn3703 s3703 s3702 0 0 nch W=0.5u L=0.18u
Mp3703 s3703 s3702 vdd vdd pch W=1u L=0.18u
Cl3703 s3703 0 10f
Mn3704 s3704 s3703 0 0 nch W=0.5u L=0.18u
Mp3704 s3704 s3703 vdd vdd pch W=1u L=0.18u
Cl3704 s3704 0 10f
Mn3705 s3705 s3704 0 0 nch W=0.5u L=0.18u
Mp3705 s3705 s3704 vdd vdd pch W=1u L=0.18u
Cl3705 s3705 0 10f
Mn3706 s3706 s3705 0 0 nch W=0.5u L=0.18u
Mp3706 s3706 s3705 vdd vdd pch W=1u L=0.18u
Cl3706 s3706 0 10f
Mn3707 s3707 s3706 0 0 nch W=0.5u L=0.18u
Mp3707 s3707 s3706 vdd vdd pch W=1u L=0.18u
Cl3707 s3707 0 10f
Mn3708 s3708 s3707 0 0 nch W=0.5u L=0.18u
Mp3708 s3708 s3707 vdd vdd pch W=1u L=0.18u
Cl3708 s3708 0 10f
Mn3709 s3709 s3708 0 0 nch W=0.5u L=0.18u
Mp3709 s3709 s3708 vdd vdd pch W=1u L=0.18u
Cl3709 s3709 0 10f
Mn3710 s3710 s3709 0 0 nch W=0.5u L=0.18u
Mp3710 s3710 s3709 vdd vdd pch W=1u L=0.18u
Cl3710 s3710 0 10f
Mn3711 s3711 s3710 0 0 nch W=0.5u L=0.18u
Mp3711 s3711 s3710 vdd vdd pch W=1u L=0.18u
Cl3711 s3711 0 10f
Mn3712 s3712 s3711 0 0 nch W=0.5u L=0.18u
Mp3712 s3712 s3711 vdd vdd pch W=1u L=0.18u
Cl3712 s3712 0 10f
Mn3713 s3713 s3712 0 0 nch W=0.5u L=0.18u
Mp3713 s3713 s3712 vdd vdd pch W=1u L=0.18u
Cl3713 s3713 0 10f
Mn3714 s3714 s3713 0 0 nch W=0.5u L=0.18u
Mp3714 s3714 s3713 vdd vdd pch W=1u L=0.18u
Cl3714 s3714 0 10f
Mn3715 s3715 s3714 0 0 nch W=0.5u L=0.18u
Mp3715 s3715 s3714 vdd vdd pch W=1u L=0.18u
Cl3715 s3715 0 10f
Mn3716 s3716 s3715 0 0 nch W=0.5u L=0.18u
Mp3716 s3716 s3715 vdd vdd pch W=1u L=0.18u
Cl3716 s3716 0 10f
Mn3717 s3717 s3716 0 0 nch W=0.5u L=0.18u
Mp3717 s3717 s3716 vdd vdd pch W=1u L=0.18u
Cl3717 s3717 0 10f
Mn3718 s3718 s3717 0 0 nch W=0.5u L=0.18u
Mp3718 s3718 s3717 vdd vdd pch W=1u L=0.18u
Cl3718 s3718 0 10f
Mn3719 s3719 s3718 0 0 nch W=0.5u L=0.18u
Mp3719 s3719 s3718 vdd vdd pch W=1u L=0.18u
Cl3719 s3719 0 10f
Mn3720 s3720 s3719 0 0 nch W=0.5u L=0.18u
Mp3720 s3720 s3719 vdd vdd pch W=1u L=0.18u
Cl3720 s3720 0 10f
Mn3721 s3721 s3720 0 0 nch W=0.5u L=0.18u
Mp3721 s3721 s3720 vdd vdd pch W=1u L=0.18u
Cl3721 s3721 0 10f
Mn3722 s3722 s3721 0 0 nch W=0.5u L=0.18u
Mp3722 s3722 s3721 vdd vdd pch W=1u L=0.18u
Cl3722 s3722 0 10f
Mn3723 s3723 s3722 0 0 nch W=0.5u L=0.18u
Mp3723 s3723 s3722 vdd vdd pch W=1u L=0.18u
Cl3723 s3723 0 10f
Mn3724 s3724 s3723 0 0 nch W=0.5u L=0.18u
Mp3724 s3724 s3723 vdd vdd pch W=1u L=0.18u
Cl3724 s3724 0 10f
Mn3725 s3725 s3724 0 0 nch W=0.5u L=0.18u
Mp3725 s3725 s3724 vdd vdd pch W=1u L=0.18u
Cl3725 s3725 0 10f
Mn3726 s3726 s3725 0 0 nch W=0.5u L=0.18u
Mp3726 s3726 s3725 vdd vdd pch W=1u L=0.18u
Cl3726 s3726 0 10f
Mn3727 s3727 s3726 0 0 nch W=0.5u L=0.18u
Mp3727 s3727 s3726 vdd vdd pch W=1u L=0.18u
Cl3727 s3727 0 10f
Mn3728 s3728 s3727 0 0 nch W=0.5u L=0.18u
Mp3728 s3728 s3727 vdd vdd pch W=1u L=0.18u
Cl3728 s3728 0 10f
Mn3729 s3729 s3728 0 0 nch W=0.5u L=0.18u
Mp3729 s3729 s3728 vdd vdd pch W=1u L=0.18u
Cl3729 s3729 0 10f
Mn3730 s3730 s3729 0 0 nch W=0.5u L=0.18u
Mp3730 s3730 s3729 vdd vdd pch W=1u L=0.18u
Cl3730 s3730 0 10f
Mn3731 s3731 s3730 0 0 nch W=0.5u L=0.18u
Mp3731 s3731 s3730 vdd vdd pch W=1u L=0.18u
Cl3731 s3731 0 10f
Mn3732 s3732 s3731 0 0 nch W=0.5u L=0.18u
Mp3732 s3732 s3731 vdd vdd pch W=1u L=0.18u
Cl3732 s3732 0 10f
Mn3733 s3733 s3732 0 0 nch W=0.5u L=0.18u
Mp3733 s3733 s3732 vdd vdd pch W=1u L=0.18u
Cl3733 s3733 0 10f
Mn3734 s3734 s3733 0 0 nch W=0.5u L=0.18u
Mp3734 s3734 s3733 vdd vdd pch W=1u L=0.18u
Cl3734 s3734 0 10f
Mn3735 s3735 s3734 0 0 nch W=0.5u L=0.18u
Mp3735 s3735 s3734 vdd vdd pch W=1u L=0.18u
Cl3735 s3735 0 10f
Mn3736 s3736 s3735 0 0 nch W=0.5u L=0.18u
Mp3736 s3736 s3735 vdd vdd pch W=1u L=0.18u
Cl3736 s3736 0 10f
Mn3737 s3737 s3736 0 0 nch W=0.5u L=0.18u
Mp3737 s3737 s3736 vdd vdd pch W=1u L=0.18u
Cl3737 s3737 0 10f
Mn3738 s3738 s3737 0 0 nch W=0.5u L=0.18u
Mp3738 s3738 s3737 vdd vdd pch W=1u L=0.18u
Cl3738 s3738 0 10f
Mn3739 s3739 s3738 0 0 nch W=0.5u L=0.18u
Mp3739 s3739 s3738 vdd vdd pch W=1u L=0.18u
Cl3739 s3739 0 10f
Mn3740 s3740 s3739 0 0 nch W=0.5u L=0.18u
Mp3740 s3740 s3739 vdd vdd pch W=1u L=0.18u
Cl3740 s3740 0 10f
Mn3741 s3741 s3740 0 0 nch W=0.5u L=0.18u
Mp3741 s3741 s3740 vdd vdd pch W=1u L=0.18u
Cl3741 s3741 0 10f
Mn3742 s3742 s3741 0 0 nch W=0.5u L=0.18u
Mp3742 s3742 s3741 vdd vdd pch W=1u L=0.18u
Cl3742 s3742 0 10f
Mn3743 s3743 s3742 0 0 nch W=0.5u L=0.18u
Mp3743 s3743 s3742 vdd vdd pch W=1u L=0.18u
Cl3743 s3743 0 10f
Mn3744 s3744 s3743 0 0 nch W=0.5u L=0.18u
Mp3744 s3744 s3743 vdd vdd pch W=1u L=0.18u
Cl3744 s3744 0 10f
Mn3745 s3745 s3744 0 0 nch W=0.5u L=0.18u
Mp3745 s3745 s3744 vdd vdd pch W=1u L=0.18u
Cl3745 s3745 0 10f
Mn3746 s3746 s3745 0 0 nch W=0.5u L=0.18u
Mp3746 s3746 s3745 vdd vdd pch W=1u L=0.18u
Cl3746 s3746 0 10f
Mn3747 s3747 s3746 0 0 nch W=0.5u L=0.18u
Mp3747 s3747 s3746 vdd vdd pch W=1u L=0.18u
Cl3747 s3747 0 10f
Mn3748 s3748 s3747 0 0 nch W=0.5u L=0.18u
Mp3748 s3748 s3747 vdd vdd pch W=1u L=0.18u
Cl3748 s3748 0 10f
Mn3749 s3749 s3748 0 0 nch W=0.5u L=0.18u
Mp3749 s3749 s3748 vdd vdd pch W=1u L=0.18u
Cl3749 s3749 0 10f
Mn3750 s3750 s3749 0 0 nch W=0.5u L=0.18u
Mp3750 s3750 s3749 vdd vdd pch W=1u L=0.18u
Cl3750 s3750 0 10f
Mn3751 s3751 s3750 0 0 nch W=0.5u L=0.18u
Mp3751 s3751 s3750 vdd vdd pch W=1u L=0.18u
Cl3751 s3751 0 10f
Mn3752 s3752 s3751 0 0 nch W=0.5u L=0.18u
Mp3752 s3752 s3751 vdd vdd pch W=1u L=0.18u
Cl3752 s3752 0 10f
Mn3753 s3753 s3752 0 0 nch W=0.5u L=0.18u
Mp3753 s3753 s3752 vdd vdd pch W=1u L=0.18u
Cl3753 s3753 0 10f
Mn3754 s3754 s3753 0 0 nch W=0.5u L=0.18u
Mp3754 s3754 s3753 vdd vdd pch W=1u L=0.18u
Cl3754 s3754 0 10f
Mn3755 s3755 s3754 0 0 nch W=0.5u L=0.18u
Mp3755 s3755 s3754 vdd vdd pch W=1u L=0.18u
Cl3755 s3755 0 10f
Mn3756 s3756 s3755 0 0 nch W=0.5u L=0.18u
Mp3756 s3756 s3755 vdd vdd pch W=1u L=0.18u
Cl3756 s3756 0 10f
Mn3757 s3757 s3756 0 0 nch W=0.5u L=0.18u
Mp3757 s3757 s3756 vdd vdd pch W=1u L=0.18u
Cl3757 s3757 0 10f
Mn3758 s3758 s3757 0 0 nch W=0.5u L=0.18u
Mp3758 s3758 s3757 vdd vdd pch W=1u L=0.18u
Cl3758 s3758 0 10f
Mn3759 s3759 s3758 0 0 nch W=0.5u L=0.18u
Mp3759 s3759 s3758 vdd vdd pch W=1u L=0.18u
Cl3759 s3759 0 10f
Mn3760 s3760 s3759 0 0 nch W=0.5u L=0.18u
Mp3760 s3760 s3759 vdd vdd pch W=1u L=0.18u
Cl3760 s3760 0 10f
Mn3761 s3761 s3760 0 0 nch W=0.5u L=0.18u
Mp3761 s3761 s3760 vdd vdd pch W=1u L=0.18u
Cl3761 s3761 0 10f
Mn3762 s3762 s3761 0 0 nch W=0.5u L=0.18u
Mp3762 s3762 s3761 vdd vdd pch W=1u L=0.18u
Cl3762 s3762 0 10f
Mn3763 s3763 s3762 0 0 nch W=0.5u L=0.18u
Mp3763 s3763 s3762 vdd vdd pch W=1u L=0.18u
Cl3763 s3763 0 10f
Mn3764 s3764 s3763 0 0 nch W=0.5u L=0.18u
Mp3764 s3764 s3763 vdd vdd pch W=1u L=0.18u
Cl3764 s3764 0 10f
Mn3765 s3765 s3764 0 0 nch W=0.5u L=0.18u
Mp3765 s3765 s3764 vdd vdd pch W=1u L=0.18u
Cl3765 s3765 0 10f
Mn3766 s3766 s3765 0 0 nch W=0.5u L=0.18u
Mp3766 s3766 s3765 vdd vdd pch W=1u L=0.18u
Cl3766 s3766 0 10f
Mn3767 s3767 s3766 0 0 nch W=0.5u L=0.18u
Mp3767 s3767 s3766 vdd vdd pch W=1u L=0.18u
Cl3767 s3767 0 10f
Mn3768 s3768 s3767 0 0 nch W=0.5u L=0.18u
Mp3768 s3768 s3767 vdd vdd pch W=1u L=0.18u
Cl3768 s3768 0 10f
Mn3769 s3769 s3768 0 0 nch W=0.5u L=0.18u
Mp3769 s3769 s3768 vdd vdd pch W=1u L=0.18u
Cl3769 s3769 0 10f
Mn3770 s3770 s3769 0 0 nch W=0.5u L=0.18u
Mp3770 s3770 s3769 vdd vdd pch W=1u L=0.18u
Cl3770 s3770 0 10f
Mn3771 s3771 s3770 0 0 nch W=0.5u L=0.18u
Mp3771 s3771 s3770 vdd vdd pch W=1u L=0.18u
Cl3771 s3771 0 10f
Mn3772 s3772 s3771 0 0 nch W=0.5u L=0.18u
Mp3772 s3772 s3771 vdd vdd pch W=1u L=0.18u
Cl3772 s3772 0 10f
Mn3773 s3773 s3772 0 0 nch W=0.5u L=0.18u
Mp3773 s3773 s3772 vdd vdd pch W=1u L=0.18u
Cl3773 s3773 0 10f
Mn3774 s3774 s3773 0 0 nch W=0.5u L=0.18u
Mp3774 s3774 s3773 vdd vdd pch W=1u L=0.18u
Cl3774 s3774 0 10f
Mn3775 s3775 s3774 0 0 nch W=0.5u L=0.18u
Mp3775 s3775 s3774 vdd vdd pch W=1u L=0.18u
Cl3775 s3775 0 10f
Mn3776 s3776 s3775 0 0 nch W=0.5u L=0.18u
Mp3776 s3776 s3775 vdd vdd pch W=1u L=0.18u
Cl3776 s3776 0 10f
Mn3777 s3777 s3776 0 0 nch W=0.5u L=0.18u
Mp3777 s3777 s3776 vdd vdd pch W=1u L=0.18u
Cl3777 s3777 0 10f
Mn3778 s3778 s3777 0 0 nch W=0.5u L=0.18u
Mp3778 s3778 s3777 vdd vdd pch W=1u L=0.18u
Cl3778 s3778 0 10f
Mn3779 s3779 s3778 0 0 nch W=0.5u L=0.18u
Mp3779 s3779 s3778 vdd vdd pch W=1u L=0.18u
Cl3779 s3779 0 10f
Mn3780 s3780 s3779 0 0 nch W=0.5u L=0.18u
Mp3780 s3780 s3779 vdd vdd pch W=1u L=0.18u
Cl3780 s3780 0 10f
Mn3781 s3781 s3780 0 0 nch W=0.5u L=0.18u
Mp3781 s3781 s3780 vdd vdd pch W=1u L=0.18u
Cl3781 s3781 0 10f
Mn3782 s3782 s3781 0 0 nch W=0.5u L=0.18u
Mp3782 s3782 s3781 vdd vdd pch W=1u L=0.18u
Cl3782 s3782 0 10f
Mn3783 s3783 s3782 0 0 nch W=0.5u L=0.18u
Mp3783 s3783 s3782 vdd vdd pch W=1u L=0.18u
Cl3783 s3783 0 10f
Mn3784 s3784 s3783 0 0 nch W=0.5u L=0.18u
Mp3784 s3784 s3783 vdd vdd pch W=1u L=0.18u
Cl3784 s3784 0 10f
Mn3785 s3785 s3784 0 0 nch W=0.5u L=0.18u
Mp3785 s3785 s3784 vdd vdd pch W=1u L=0.18u
Cl3785 s3785 0 10f
Mn3786 s3786 s3785 0 0 nch W=0.5u L=0.18u
Mp3786 s3786 s3785 vdd vdd pch W=1u L=0.18u
Cl3786 s3786 0 10f
Mn3787 s3787 s3786 0 0 nch W=0.5u L=0.18u
Mp3787 s3787 s3786 vdd vdd pch W=1u L=0.18u
Cl3787 s3787 0 10f
Mn3788 s3788 s3787 0 0 nch W=0.5u L=0.18u
Mp3788 s3788 s3787 vdd vdd pch W=1u L=0.18u
Cl3788 s3788 0 10f
Mn3789 s3789 s3788 0 0 nch W=0.5u L=0.18u
Mp3789 s3789 s3788 vdd vdd pch W=1u L=0.18u
Cl3789 s3789 0 10f
Mn3790 s3790 s3789 0 0 nch W=0.5u L=0.18u
Mp3790 s3790 s3789 vdd vdd pch W=1u L=0.18u
Cl3790 s3790 0 10f
Mn3791 s3791 s3790 0 0 nch W=0.5u L=0.18u
Mp3791 s3791 s3790 vdd vdd pch W=1u L=0.18u
Cl3791 s3791 0 10f
Mn3792 s3792 s3791 0 0 nch W=0.5u L=0.18u
Mp3792 s3792 s3791 vdd vdd pch W=1u L=0.18u
Cl3792 s3792 0 10f
Mn3793 s3793 s3792 0 0 nch W=0.5u L=0.18u
Mp3793 s3793 s3792 vdd vdd pch W=1u L=0.18u
Cl3793 s3793 0 10f
Mn3794 s3794 s3793 0 0 nch W=0.5u L=0.18u
Mp3794 s3794 s3793 vdd vdd pch W=1u L=0.18u
Cl3794 s3794 0 10f
Mn3795 s3795 s3794 0 0 nch W=0.5u L=0.18u
Mp3795 s3795 s3794 vdd vdd pch W=1u L=0.18u
Cl3795 s3795 0 10f
Mn3796 s3796 s3795 0 0 nch W=0.5u L=0.18u
Mp3796 s3796 s3795 vdd vdd pch W=1u L=0.18u
Cl3796 s3796 0 10f
Mn3797 s3797 s3796 0 0 nch W=0.5u L=0.18u
Mp3797 s3797 s3796 vdd vdd pch W=1u L=0.18u
Cl3797 s3797 0 10f
Mn3798 s3798 s3797 0 0 nch W=0.5u L=0.18u
Mp3798 s3798 s3797 vdd vdd pch W=1u L=0.18u
Cl3798 s3798 0 10f
Mn3799 s3799 s3798 0 0 nch W=0.5u L=0.18u
Mp3799 s3799 s3798 vdd vdd pch W=1u L=0.18u
Cl3799 s3799 0 10f
Mn3800 s3800 s3799 0 0 nch W=0.5u L=0.18u
Mp3800 s3800 s3799 vdd vdd pch W=1u L=0.18u
Cl3800 s3800 0 10f
Mn3801 s3801 s3800 0 0 nch W=0.5u L=0.18u
Mp3801 s3801 s3800 vdd vdd pch W=1u L=0.18u
Cl3801 s3801 0 10f
Mn3802 s3802 s3801 0 0 nch W=0.5u L=0.18u
Mp3802 s3802 s3801 vdd vdd pch W=1u L=0.18u
Cl3802 s3802 0 10f
Mn3803 s3803 s3802 0 0 nch W=0.5u L=0.18u
Mp3803 s3803 s3802 vdd vdd pch W=1u L=0.18u
Cl3803 s3803 0 10f
Mn3804 s3804 s3803 0 0 nch W=0.5u L=0.18u
Mp3804 s3804 s3803 vdd vdd pch W=1u L=0.18u
Cl3804 s3804 0 10f
Mn3805 s3805 s3804 0 0 nch W=0.5u L=0.18u
Mp3805 s3805 s3804 vdd vdd pch W=1u L=0.18u
Cl3805 s3805 0 10f
Mn3806 s3806 s3805 0 0 nch W=0.5u L=0.18u
Mp3806 s3806 s3805 vdd vdd pch W=1u L=0.18u
Cl3806 s3806 0 10f
Mn3807 s3807 s3806 0 0 nch W=0.5u L=0.18u
Mp3807 s3807 s3806 vdd vdd pch W=1u L=0.18u
Cl3807 s3807 0 10f
Mn3808 s3808 s3807 0 0 nch W=0.5u L=0.18u
Mp3808 s3808 s3807 vdd vdd pch W=1u L=0.18u
Cl3808 s3808 0 10f
Mn3809 s3809 s3808 0 0 nch W=0.5u L=0.18u
Mp3809 s3809 s3808 vdd vdd pch W=1u L=0.18u
Cl3809 s3809 0 10f
Mn3810 s3810 s3809 0 0 nch W=0.5u L=0.18u
Mp3810 s3810 s3809 vdd vdd pch W=1u L=0.18u
Cl3810 s3810 0 10f
Mn3811 s3811 s3810 0 0 nch W=0.5u L=0.18u
Mp3811 s3811 s3810 vdd vdd pch W=1u L=0.18u
Cl3811 s3811 0 10f
Mn3812 s3812 s3811 0 0 nch W=0.5u L=0.18u
Mp3812 s3812 s3811 vdd vdd pch W=1u L=0.18u
Cl3812 s3812 0 10f
Mn3813 s3813 s3812 0 0 nch W=0.5u L=0.18u
Mp3813 s3813 s3812 vdd vdd pch W=1u L=0.18u
Cl3813 s3813 0 10f
Mn3814 s3814 s3813 0 0 nch W=0.5u L=0.18u
Mp3814 s3814 s3813 vdd vdd pch W=1u L=0.18u
Cl3814 s3814 0 10f
Mn3815 s3815 s3814 0 0 nch W=0.5u L=0.18u
Mp3815 s3815 s3814 vdd vdd pch W=1u L=0.18u
Cl3815 s3815 0 10f
Mn3816 s3816 s3815 0 0 nch W=0.5u L=0.18u
Mp3816 s3816 s3815 vdd vdd pch W=1u L=0.18u
Cl3816 s3816 0 10f
Mn3817 s3817 s3816 0 0 nch W=0.5u L=0.18u
Mp3817 s3817 s3816 vdd vdd pch W=1u L=0.18u
Cl3817 s3817 0 10f
Mn3818 s3818 s3817 0 0 nch W=0.5u L=0.18u
Mp3818 s3818 s3817 vdd vdd pch W=1u L=0.18u
Cl3818 s3818 0 10f
Mn3819 s3819 s3818 0 0 nch W=0.5u L=0.18u
Mp3819 s3819 s3818 vdd vdd pch W=1u L=0.18u
Cl3819 s3819 0 10f
Mn3820 s3820 s3819 0 0 nch W=0.5u L=0.18u
Mp3820 s3820 s3819 vdd vdd pch W=1u L=0.18u
Cl3820 s3820 0 10f
Mn3821 s3821 s3820 0 0 nch W=0.5u L=0.18u
Mp3821 s3821 s3820 vdd vdd pch W=1u L=0.18u
Cl3821 s3821 0 10f
Mn3822 s3822 s3821 0 0 nch W=0.5u L=0.18u
Mp3822 s3822 s3821 vdd vdd pch W=1u L=0.18u
Cl3822 s3822 0 10f
Mn3823 s3823 s3822 0 0 nch W=0.5u L=0.18u
Mp3823 s3823 s3822 vdd vdd pch W=1u L=0.18u
Cl3823 s3823 0 10f
Mn3824 s3824 s3823 0 0 nch W=0.5u L=0.18u
Mp3824 s3824 s3823 vdd vdd pch W=1u L=0.18u
Cl3824 s3824 0 10f
Mn3825 s3825 s3824 0 0 nch W=0.5u L=0.18u
Mp3825 s3825 s3824 vdd vdd pch W=1u L=0.18u
Cl3825 s3825 0 10f
Mn3826 s3826 s3825 0 0 nch W=0.5u L=0.18u
Mp3826 s3826 s3825 vdd vdd pch W=1u L=0.18u
Cl3826 s3826 0 10f
Mn3827 s3827 s3826 0 0 nch W=0.5u L=0.18u
Mp3827 s3827 s3826 vdd vdd pch W=1u L=0.18u
Cl3827 s3827 0 10f
Mn3828 s3828 s3827 0 0 nch W=0.5u L=0.18u
Mp3828 s3828 s3827 vdd vdd pch W=1u L=0.18u
Cl3828 s3828 0 10f
Mn3829 s3829 s3828 0 0 nch W=0.5u L=0.18u
Mp3829 s3829 s3828 vdd vdd pch W=1u L=0.18u
Cl3829 s3829 0 10f
Mn3830 s3830 s3829 0 0 nch W=0.5u L=0.18u
Mp3830 s3830 s3829 vdd vdd pch W=1u L=0.18u
Cl3830 s3830 0 10f
Mn3831 s3831 s3830 0 0 nch W=0.5u L=0.18u
Mp3831 s3831 s3830 vdd vdd pch W=1u L=0.18u
Cl3831 s3831 0 10f
Mn3832 s3832 s3831 0 0 nch W=0.5u L=0.18u
Mp3832 s3832 s3831 vdd vdd pch W=1u L=0.18u
Cl3832 s3832 0 10f
Mn3833 s3833 s3832 0 0 nch W=0.5u L=0.18u
Mp3833 s3833 s3832 vdd vdd pch W=1u L=0.18u
Cl3833 s3833 0 10f
Mn3834 s3834 s3833 0 0 nch W=0.5u L=0.18u
Mp3834 s3834 s3833 vdd vdd pch W=1u L=0.18u
Cl3834 s3834 0 10f
Mn3835 s3835 s3834 0 0 nch W=0.5u L=0.18u
Mp3835 s3835 s3834 vdd vdd pch W=1u L=0.18u
Cl3835 s3835 0 10f
Mn3836 s3836 s3835 0 0 nch W=0.5u L=0.18u
Mp3836 s3836 s3835 vdd vdd pch W=1u L=0.18u
Cl3836 s3836 0 10f
Mn3837 s3837 s3836 0 0 nch W=0.5u L=0.18u
Mp3837 s3837 s3836 vdd vdd pch W=1u L=0.18u
Cl3837 s3837 0 10f
Mn3838 s3838 s3837 0 0 nch W=0.5u L=0.18u
Mp3838 s3838 s3837 vdd vdd pch W=1u L=0.18u
Cl3838 s3838 0 10f
Mn3839 s3839 s3838 0 0 nch W=0.5u L=0.18u
Mp3839 s3839 s3838 vdd vdd pch W=1u L=0.18u
Cl3839 s3839 0 10f
Mn3840 s3840 s3839 0 0 nch W=0.5u L=0.18u
Mp3840 s3840 s3839 vdd vdd pch W=1u L=0.18u
Cl3840 s3840 0 10f
Mn3841 s3841 s3840 0 0 nch W=0.5u L=0.18u
Mp3841 s3841 s3840 vdd vdd pch W=1u L=0.18u
Cl3841 s3841 0 10f
Mn3842 s3842 s3841 0 0 nch W=0.5u L=0.18u
Mp3842 s3842 s3841 vdd vdd pch W=1u L=0.18u
Cl3842 s3842 0 10f
Mn3843 s3843 s3842 0 0 nch W=0.5u L=0.18u
Mp3843 s3843 s3842 vdd vdd pch W=1u L=0.18u
Cl3843 s3843 0 10f
Mn3844 s3844 s3843 0 0 nch W=0.5u L=0.18u
Mp3844 s3844 s3843 vdd vdd pch W=1u L=0.18u
Cl3844 s3844 0 10f
Mn3845 s3845 s3844 0 0 nch W=0.5u L=0.18u
Mp3845 s3845 s3844 vdd vdd pch W=1u L=0.18u
Cl3845 s3845 0 10f
Mn3846 s3846 s3845 0 0 nch W=0.5u L=0.18u
Mp3846 s3846 s3845 vdd vdd pch W=1u L=0.18u
Cl3846 s3846 0 10f
Mn3847 s3847 s3846 0 0 nch W=0.5u L=0.18u
Mp3847 s3847 s3846 vdd vdd pch W=1u L=0.18u
Cl3847 s3847 0 10f
Mn3848 s3848 s3847 0 0 nch W=0.5u L=0.18u
Mp3848 s3848 s3847 vdd vdd pch W=1u L=0.18u
Cl3848 s3848 0 10f
Mn3849 s3849 s3848 0 0 nch W=0.5u L=0.18u
Mp3849 s3849 s3848 vdd vdd pch W=1u L=0.18u
Cl3849 s3849 0 10f
Mn3850 s3850 s3849 0 0 nch W=0.5u L=0.18u
Mp3850 s3850 s3849 vdd vdd pch W=1u L=0.18u
Cl3850 s3850 0 10f
Mn3851 s3851 s3850 0 0 nch W=0.5u L=0.18u
Mp3851 s3851 s3850 vdd vdd pch W=1u L=0.18u
Cl3851 s3851 0 10f
Mn3852 s3852 s3851 0 0 nch W=0.5u L=0.18u
Mp3852 s3852 s3851 vdd vdd pch W=1u L=0.18u
Cl3852 s3852 0 10f
Mn3853 s3853 s3852 0 0 nch W=0.5u L=0.18u
Mp3853 s3853 s3852 vdd vdd pch W=1u L=0.18u
Cl3853 s3853 0 10f
Mn3854 s3854 s3853 0 0 nch W=0.5u L=0.18u
Mp3854 s3854 s3853 vdd vdd pch W=1u L=0.18u
Cl3854 s3854 0 10f
Mn3855 s3855 s3854 0 0 nch W=0.5u L=0.18u
Mp3855 s3855 s3854 vdd vdd pch W=1u L=0.18u
Cl3855 s3855 0 10f
Mn3856 s3856 s3855 0 0 nch W=0.5u L=0.18u
Mp3856 s3856 s3855 vdd vdd pch W=1u L=0.18u
Cl3856 s3856 0 10f
Mn3857 s3857 s3856 0 0 nch W=0.5u L=0.18u
Mp3857 s3857 s3856 vdd vdd pch W=1u L=0.18u
Cl3857 s3857 0 10f
Mn3858 s3858 s3857 0 0 nch W=0.5u L=0.18u
Mp3858 s3858 s3857 vdd vdd pch W=1u L=0.18u
Cl3858 s3858 0 10f
Mn3859 s3859 s3858 0 0 nch W=0.5u L=0.18u
Mp3859 s3859 s3858 vdd vdd pch W=1u L=0.18u
Cl3859 s3859 0 10f
Mn3860 s3860 s3859 0 0 nch W=0.5u L=0.18u
Mp3860 s3860 s3859 vdd vdd pch W=1u L=0.18u
Cl3860 s3860 0 10f
Mn3861 s3861 s3860 0 0 nch W=0.5u L=0.18u
Mp3861 s3861 s3860 vdd vdd pch W=1u L=0.18u
Cl3861 s3861 0 10f
Mn3862 s3862 s3861 0 0 nch W=0.5u L=0.18u
Mp3862 s3862 s3861 vdd vdd pch W=1u L=0.18u
Cl3862 s3862 0 10f
Mn3863 s3863 s3862 0 0 nch W=0.5u L=0.18u
Mp3863 s3863 s3862 vdd vdd pch W=1u L=0.18u
Cl3863 s3863 0 10f
Mn3864 s3864 s3863 0 0 nch W=0.5u L=0.18u
Mp3864 s3864 s3863 vdd vdd pch W=1u L=0.18u
Cl3864 s3864 0 10f
Mn3865 s3865 s3864 0 0 nch W=0.5u L=0.18u
Mp3865 s3865 s3864 vdd vdd pch W=1u L=0.18u
Cl3865 s3865 0 10f
Mn3866 s3866 s3865 0 0 nch W=0.5u L=0.18u
Mp3866 s3866 s3865 vdd vdd pch W=1u L=0.18u
Cl3866 s3866 0 10f
Mn3867 s3867 s3866 0 0 nch W=0.5u L=0.18u
Mp3867 s3867 s3866 vdd vdd pch W=1u L=0.18u
Cl3867 s3867 0 10f
Mn3868 s3868 s3867 0 0 nch W=0.5u L=0.18u
Mp3868 s3868 s3867 vdd vdd pch W=1u L=0.18u
Cl3868 s3868 0 10f
Mn3869 s3869 s3868 0 0 nch W=0.5u L=0.18u
Mp3869 s3869 s3868 vdd vdd pch W=1u L=0.18u
Cl3869 s3869 0 10f
Mn3870 s3870 s3869 0 0 nch W=0.5u L=0.18u
Mp3870 s3870 s3869 vdd vdd pch W=1u L=0.18u
Cl3870 s3870 0 10f
Mn3871 s3871 s3870 0 0 nch W=0.5u L=0.18u
Mp3871 s3871 s3870 vdd vdd pch W=1u L=0.18u
Cl3871 s3871 0 10f
Mn3872 s3872 s3871 0 0 nch W=0.5u L=0.18u
Mp3872 s3872 s3871 vdd vdd pch W=1u L=0.18u
Cl3872 s3872 0 10f
Mn3873 s3873 s3872 0 0 nch W=0.5u L=0.18u
Mp3873 s3873 s3872 vdd vdd pch W=1u L=0.18u
Cl3873 s3873 0 10f
Mn3874 s3874 s3873 0 0 nch W=0.5u L=0.18u
Mp3874 s3874 s3873 vdd vdd pch W=1u L=0.18u
Cl3874 s3874 0 10f
Mn3875 s3875 s3874 0 0 nch W=0.5u L=0.18u
Mp3875 s3875 s3874 vdd vdd pch W=1u L=0.18u
Cl3875 s3875 0 10f
Mn3876 s3876 s3875 0 0 nch W=0.5u L=0.18u
Mp3876 s3876 s3875 vdd vdd pch W=1u L=0.18u
Cl3876 s3876 0 10f
Mn3877 s3877 s3876 0 0 nch W=0.5u L=0.18u
Mp3877 s3877 s3876 vdd vdd pch W=1u L=0.18u
Cl3877 s3877 0 10f
Mn3878 s3878 s3877 0 0 nch W=0.5u L=0.18u
Mp3878 s3878 s3877 vdd vdd pch W=1u L=0.18u
Cl3878 s3878 0 10f
Mn3879 s3879 s3878 0 0 nch W=0.5u L=0.18u
Mp3879 s3879 s3878 vdd vdd pch W=1u L=0.18u
Cl3879 s3879 0 10f
Mn3880 s3880 s3879 0 0 nch W=0.5u L=0.18u
Mp3880 s3880 s3879 vdd vdd pch W=1u L=0.18u
Cl3880 s3880 0 10f
Mn3881 s3881 s3880 0 0 nch W=0.5u L=0.18u
Mp3881 s3881 s3880 vdd vdd pch W=1u L=0.18u
Cl3881 s3881 0 10f
Mn3882 s3882 s3881 0 0 nch W=0.5u L=0.18u
Mp3882 s3882 s3881 vdd vdd pch W=1u L=0.18u
Cl3882 s3882 0 10f
Mn3883 s3883 s3882 0 0 nch W=0.5u L=0.18u
Mp3883 s3883 s3882 vdd vdd pch W=1u L=0.18u
Cl3883 s3883 0 10f
Mn3884 s3884 s3883 0 0 nch W=0.5u L=0.18u
Mp3884 s3884 s3883 vdd vdd pch W=1u L=0.18u
Cl3884 s3884 0 10f
Mn3885 s3885 s3884 0 0 nch W=0.5u L=0.18u
Mp3885 s3885 s3884 vdd vdd pch W=1u L=0.18u
Cl3885 s3885 0 10f
Mn3886 s3886 s3885 0 0 nch W=0.5u L=0.18u
Mp3886 s3886 s3885 vdd vdd pch W=1u L=0.18u
Cl3886 s3886 0 10f
Mn3887 s3887 s3886 0 0 nch W=0.5u L=0.18u
Mp3887 s3887 s3886 vdd vdd pch W=1u L=0.18u
Cl3887 s3887 0 10f
Mn3888 s3888 s3887 0 0 nch W=0.5u L=0.18u
Mp3888 s3888 s3887 vdd vdd pch W=1u L=0.18u
Cl3888 s3888 0 10f
Mn3889 s3889 s3888 0 0 nch W=0.5u L=0.18u
Mp3889 s3889 s3888 vdd vdd pch W=1u L=0.18u
Cl3889 s3889 0 10f
Mn3890 s3890 s3889 0 0 nch W=0.5u L=0.18u
Mp3890 s3890 s3889 vdd vdd pch W=1u L=0.18u
Cl3890 s3890 0 10f
Mn3891 s3891 s3890 0 0 nch W=0.5u L=0.18u
Mp3891 s3891 s3890 vdd vdd pch W=1u L=0.18u
Cl3891 s3891 0 10f
Mn3892 s3892 s3891 0 0 nch W=0.5u L=0.18u
Mp3892 s3892 s3891 vdd vdd pch W=1u L=0.18u
Cl3892 s3892 0 10f
Mn3893 s3893 s3892 0 0 nch W=0.5u L=0.18u
Mp3893 s3893 s3892 vdd vdd pch W=1u L=0.18u
Cl3893 s3893 0 10f
Mn3894 s3894 s3893 0 0 nch W=0.5u L=0.18u
Mp3894 s3894 s3893 vdd vdd pch W=1u L=0.18u
Cl3894 s3894 0 10f
Mn3895 s3895 s3894 0 0 nch W=0.5u L=0.18u
Mp3895 s3895 s3894 vdd vdd pch W=1u L=0.18u
Cl3895 s3895 0 10f
Mn3896 s3896 s3895 0 0 nch W=0.5u L=0.18u
Mp3896 s3896 s3895 vdd vdd pch W=1u L=0.18u
Cl3896 s3896 0 10f
Mn3897 s3897 s3896 0 0 nch W=0.5u L=0.18u
Mp3897 s3897 s3896 vdd vdd pch W=1u L=0.18u
Cl3897 s3897 0 10f
Mn3898 s3898 s3897 0 0 nch W=0.5u L=0.18u
Mp3898 s3898 s3897 vdd vdd pch W=1u L=0.18u
Cl3898 s3898 0 10f
Mn3899 s3899 s3898 0 0 nch W=0.5u L=0.18u
Mp3899 s3899 s3898 vdd vdd pch W=1u L=0.18u
Cl3899 s3899 0 10f
Mn3900 s3900 s3899 0 0 nch W=0.5u L=0.18u
Mp3900 s3900 s3899 vdd vdd pch W=1u L=0.18u
Cl3900 s3900 0 10f
Mn3901 s3901 s3900 0 0 nch W=0.5u L=0.18u
Mp3901 s3901 s3900 vdd vdd pch W=1u L=0.18u
Cl3901 s3901 0 10f
Mn3902 s3902 s3901 0 0 nch W=0.5u L=0.18u
Mp3902 s3902 s3901 vdd vdd pch W=1u L=0.18u
Cl3902 s3902 0 10f
Mn3903 s3903 s3902 0 0 nch W=0.5u L=0.18u
Mp3903 s3903 s3902 vdd vdd pch W=1u L=0.18u
Cl3903 s3903 0 10f
Mn3904 s3904 s3903 0 0 nch W=0.5u L=0.18u
Mp3904 s3904 s3903 vdd vdd pch W=1u L=0.18u
Cl3904 s3904 0 10f
Mn3905 s3905 s3904 0 0 nch W=0.5u L=0.18u
Mp3905 s3905 s3904 vdd vdd pch W=1u L=0.18u
Cl3905 s3905 0 10f
Mn3906 s3906 s3905 0 0 nch W=0.5u L=0.18u
Mp3906 s3906 s3905 vdd vdd pch W=1u L=0.18u
Cl3906 s3906 0 10f
Mn3907 s3907 s3906 0 0 nch W=0.5u L=0.18u
Mp3907 s3907 s3906 vdd vdd pch W=1u L=0.18u
Cl3907 s3907 0 10f
Mn3908 s3908 s3907 0 0 nch W=0.5u L=0.18u
Mp3908 s3908 s3907 vdd vdd pch W=1u L=0.18u
Cl3908 s3908 0 10f
Mn3909 s3909 s3908 0 0 nch W=0.5u L=0.18u
Mp3909 s3909 s3908 vdd vdd pch W=1u L=0.18u
Cl3909 s3909 0 10f
Mn3910 s3910 s3909 0 0 nch W=0.5u L=0.18u
Mp3910 s3910 s3909 vdd vdd pch W=1u L=0.18u
Cl3910 s3910 0 10f
Mn3911 s3911 s3910 0 0 nch W=0.5u L=0.18u
Mp3911 s3911 s3910 vdd vdd pch W=1u L=0.18u
Cl3911 s3911 0 10f
Mn3912 s3912 s3911 0 0 nch W=0.5u L=0.18u
Mp3912 s3912 s3911 vdd vdd pch W=1u L=0.18u
Cl3912 s3912 0 10f
Mn3913 s3913 s3912 0 0 nch W=0.5u L=0.18u
Mp3913 s3913 s3912 vdd vdd pch W=1u L=0.18u
Cl3913 s3913 0 10f
Mn3914 s3914 s3913 0 0 nch W=0.5u L=0.18u
Mp3914 s3914 s3913 vdd vdd pch W=1u L=0.18u
Cl3914 s3914 0 10f
Mn3915 s3915 s3914 0 0 nch W=0.5u L=0.18u
Mp3915 s3915 s3914 vdd vdd pch W=1u L=0.18u
Cl3915 s3915 0 10f
Mn3916 s3916 s3915 0 0 nch W=0.5u L=0.18u
Mp3916 s3916 s3915 vdd vdd pch W=1u L=0.18u
Cl3916 s3916 0 10f
Mn3917 s3917 s3916 0 0 nch W=0.5u L=0.18u
Mp3917 s3917 s3916 vdd vdd pch W=1u L=0.18u
Cl3917 s3917 0 10f
Mn3918 s3918 s3917 0 0 nch W=0.5u L=0.18u
Mp3918 s3918 s3917 vdd vdd pch W=1u L=0.18u
Cl3918 s3918 0 10f
Mn3919 s3919 s3918 0 0 nch W=0.5u L=0.18u
Mp3919 s3919 s3918 vdd vdd pch W=1u L=0.18u
Cl3919 s3919 0 10f
Mn3920 s3920 s3919 0 0 nch W=0.5u L=0.18u
Mp3920 s3920 s3919 vdd vdd pch W=1u L=0.18u
Cl3920 s3920 0 10f
Mn3921 s3921 s3920 0 0 nch W=0.5u L=0.18u
Mp3921 s3921 s3920 vdd vdd pch W=1u L=0.18u
Cl3921 s3921 0 10f
Mn3922 s3922 s3921 0 0 nch W=0.5u L=0.18u
Mp3922 s3922 s3921 vdd vdd pch W=1u L=0.18u
Cl3922 s3922 0 10f
Mn3923 s3923 s3922 0 0 nch W=0.5u L=0.18u
Mp3923 s3923 s3922 vdd vdd pch W=1u L=0.18u
Cl3923 s3923 0 10f
Mn3924 s3924 s3923 0 0 nch W=0.5u L=0.18u
Mp3924 s3924 s3923 vdd vdd pch W=1u L=0.18u
Cl3924 s3924 0 10f
Mn3925 s3925 s3924 0 0 nch W=0.5u L=0.18u
Mp3925 s3925 s3924 vdd vdd pch W=1u L=0.18u
Cl3925 s3925 0 10f
Mn3926 s3926 s3925 0 0 nch W=0.5u L=0.18u
Mp3926 s3926 s3925 vdd vdd pch W=1u L=0.18u
Cl3926 s3926 0 10f
Mn3927 s3927 s3926 0 0 nch W=0.5u L=0.18u
Mp3927 s3927 s3926 vdd vdd pch W=1u L=0.18u
Cl3927 s3927 0 10f
Mn3928 s3928 s3927 0 0 nch W=0.5u L=0.18u
Mp3928 s3928 s3927 vdd vdd pch W=1u L=0.18u
Cl3928 s3928 0 10f
Mn3929 s3929 s3928 0 0 nch W=0.5u L=0.18u
Mp3929 s3929 s3928 vdd vdd pch W=1u L=0.18u
Cl3929 s3929 0 10f
Mn3930 s3930 s3929 0 0 nch W=0.5u L=0.18u
Mp3930 s3930 s3929 vdd vdd pch W=1u L=0.18u
Cl3930 s3930 0 10f
Mn3931 s3931 s3930 0 0 nch W=0.5u L=0.18u
Mp3931 s3931 s3930 vdd vdd pch W=1u L=0.18u
Cl3931 s3931 0 10f
Mn3932 s3932 s3931 0 0 nch W=0.5u L=0.18u
Mp3932 s3932 s3931 vdd vdd pch W=1u L=0.18u
Cl3932 s3932 0 10f
Mn3933 s3933 s3932 0 0 nch W=0.5u L=0.18u
Mp3933 s3933 s3932 vdd vdd pch W=1u L=0.18u
Cl3933 s3933 0 10f
Mn3934 s3934 s3933 0 0 nch W=0.5u L=0.18u
Mp3934 s3934 s3933 vdd vdd pch W=1u L=0.18u
Cl3934 s3934 0 10f
Mn3935 s3935 s3934 0 0 nch W=0.5u L=0.18u
Mp3935 s3935 s3934 vdd vdd pch W=1u L=0.18u
Cl3935 s3935 0 10f
Mn3936 s3936 s3935 0 0 nch W=0.5u L=0.18u
Mp3936 s3936 s3935 vdd vdd pch W=1u L=0.18u
Cl3936 s3936 0 10f
Mn3937 s3937 s3936 0 0 nch W=0.5u L=0.18u
Mp3937 s3937 s3936 vdd vdd pch W=1u L=0.18u
Cl3937 s3937 0 10f
Mn3938 s3938 s3937 0 0 nch W=0.5u L=0.18u
Mp3938 s3938 s3937 vdd vdd pch W=1u L=0.18u
Cl3938 s3938 0 10f
Mn3939 s3939 s3938 0 0 nch W=0.5u L=0.18u
Mp3939 s3939 s3938 vdd vdd pch W=1u L=0.18u
Cl3939 s3939 0 10f
Mn3940 s3940 s3939 0 0 nch W=0.5u L=0.18u
Mp3940 s3940 s3939 vdd vdd pch W=1u L=0.18u
Cl3940 s3940 0 10f
Mn3941 s3941 s3940 0 0 nch W=0.5u L=0.18u
Mp3941 s3941 s3940 vdd vdd pch W=1u L=0.18u
Cl3941 s3941 0 10f
Mn3942 s3942 s3941 0 0 nch W=0.5u L=0.18u
Mp3942 s3942 s3941 vdd vdd pch W=1u L=0.18u
Cl3942 s3942 0 10f
Mn3943 s3943 s3942 0 0 nch W=0.5u L=0.18u
Mp3943 s3943 s3942 vdd vdd pch W=1u L=0.18u
Cl3943 s3943 0 10f
Mn3944 s3944 s3943 0 0 nch W=0.5u L=0.18u
Mp3944 s3944 s3943 vdd vdd pch W=1u L=0.18u
Cl3944 s3944 0 10f
Mn3945 s3945 s3944 0 0 nch W=0.5u L=0.18u
Mp3945 s3945 s3944 vdd vdd pch W=1u L=0.18u
Cl3945 s3945 0 10f
Mn3946 s3946 s3945 0 0 nch W=0.5u L=0.18u
Mp3946 s3946 s3945 vdd vdd pch W=1u L=0.18u
Cl3946 s3946 0 10f
Mn3947 s3947 s3946 0 0 nch W=0.5u L=0.18u
Mp3947 s3947 s3946 vdd vdd pch W=1u L=0.18u
Cl3947 s3947 0 10f
Mn3948 s3948 s3947 0 0 nch W=0.5u L=0.18u
Mp3948 s3948 s3947 vdd vdd pch W=1u L=0.18u
Cl3948 s3948 0 10f
Mn3949 s3949 s3948 0 0 nch W=0.5u L=0.18u
Mp3949 s3949 s3948 vdd vdd pch W=1u L=0.18u
Cl3949 s3949 0 10f
Mn3950 s3950 s3949 0 0 nch W=0.5u L=0.18u
Mp3950 s3950 s3949 vdd vdd pch W=1u L=0.18u
Cl3950 s3950 0 10f
Mn3951 s3951 s3950 0 0 nch W=0.5u L=0.18u
Mp3951 s3951 s3950 vdd vdd pch W=1u L=0.18u
Cl3951 s3951 0 10f
Mn3952 s3952 s3951 0 0 nch W=0.5u L=0.18u
Mp3952 s3952 s3951 vdd vdd pch W=1u L=0.18u
Cl3952 s3952 0 10f
Mn3953 s3953 s3952 0 0 nch W=0.5u L=0.18u
Mp3953 s3953 s3952 vdd vdd pch W=1u L=0.18u
Cl3953 s3953 0 10f
Mn3954 s3954 s3953 0 0 nch W=0.5u L=0.18u
Mp3954 s3954 s3953 vdd vdd pch W=1u L=0.18u
Cl3954 s3954 0 10f
Mn3955 s3955 s3954 0 0 nch W=0.5u L=0.18u
Mp3955 s3955 s3954 vdd vdd pch W=1u L=0.18u
Cl3955 s3955 0 10f
Mn3956 s3956 s3955 0 0 nch W=0.5u L=0.18u
Mp3956 s3956 s3955 vdd vdd pch W=1u L=0.18u
Cl3956 s3956 0 10f
Mn3957 s3957 s3956 0 0 nch W=0.5u L=0.18u
Mp3957 s3957 s3956 vdd vdd pch W=1u L=0.18u
Cl3957 s3957 0 10f
Mn3958 s3958 s3957 0 0 nch W=0.5u L=0.18u
Mp3958 s3958 s3957 vdd vdd pch W=1u L=0.18u
Cl3958 s3958 0 10f
Mn3959 s3959 s3958 0 0 nch W=0.5u L=0.18u
Mp3959 s3959 s3958 vdd vdd pch W=1u L=0.18u
Cl3959 s3959 0 10f
Mn3960 s3960 s3959 0 0 nch W=0.5u L=0.18u
Mp3960 s3960 s3959 vdd vdd pch W=1u L=0.18u
Cl3960 s3960 0 10f
Mn3961 s3961 s3960 0 0 nch W=0.5u L=0.18u
Mp3961 s3961 s3960 vdd vdd pch W=1u L=0.18u
Cl3961 s3961 0 10f
Mn3962 s3962 s3961 0 0 nch W=0.5u L=0.18u
Mp3962 s3962 s3961 vdd vdd pch W=1u L=0.18u
Cl3962 s3962 0 10f
Mn3963 s3963 s3962 0 0 nch W=0.5u L=0.18u
Mp3963 s3963 s3962 vdd vdd pch W=1u L=0.18u
Cl3963 s3963 0 10f
Mn3964 s3964 s3963 0 0 nch W=0.5u L=0.18u
Mp3964 s3964 s3963 vdd vdd pch W=1u L=0.18u
Cl3964 s3964 0 10f
Mn3965 s3965 s3964 0 0 nch W=0.5u L=0.18u
Mp3965 s3965 s3964 vdd vdd pch W=1u L=0.18u
Cl3965 s3965 0 10f
Mn3966 s3966 s3965 0 0 nch W=0.5u L=0.18u
Mp3966 s3966 s3965 vdd vdd pch W=1u L=0.18u
Cl3966 s3966 0 10f
Mn3967 s3967 s3966 0 0 nch W=0.5u L=0.18u
Mp3967 s3967 s3966 vdd vdd pch W=1u L=0.18u
Cl3967 s3967 0 10f
Mn3968 s3968 s3967 0 0 nch W=0.5u L=0.18u
Mp3968 s3968 s3967 vdd vdd pch W=1u L=0.18u
Cl3968 s3968 0 10f
Mn3969 s3969 s3968 0 0 nch W=0.5u L=0.18u
Mp3969 s3969 s3968 vdd vdd pch W=1u L=0.18u
Cl3969 s3969 0 10f
Mn3970 s3970 s3969 0 0 nch W=0.5u L=0.18u
Mp3970 s3970 s3969 vdd vdd pch W=1u L=0.18u
Cl3970 s3970 0 10f
Mn3971 s3971 s3970 0 0 nch W=0.5u L=0.18u
Mp3971 s3971 s3970 vdd vdd pch W=1u L=0.18u
Cl3971 s3971 0 10f
Mn3972 s3972 s3971 0 0 nch W=0.5u L=0.18u
Mp3972 s3972 s3971 vdd vdd pch W=1u L=0.18u
Cl3972 s3972 0 10f
Mn3973 s3973 s3972 0 0 nch W=0.5u L=0.18u
Mp3973 s3973 s3972 vdd vdd pch W=1u L=0.18u
Cl3973 s3973 0 10f
Mn3974 s3974 s3973 0 0 nch W=0.5u L=0.18u
Mp3974 s3974 s3973 vdd vdd pch W=1u L=0.18u
Cl3974 s3974 0 10f
Mn3975 s3975 s3974 0 0 nch W=0.5u L=0.18u
Mp3975 s3975 s3974 vdd vdd pch W=1u L=0.18u
Cl3975 s3975 0 10f
Mn3976 s3976 s3975 0 0 nch W=0.5u L=0.18u
Mp3976 s3976 s3975 vdd vdd pch W=1u L=0.18u
Cl3976 s3976 0 10f
Mn3977 s3977 s3976 0 0 nch W=0.5u L=0.18u
Mp3977 s3977 s3976 vdd vdd pch W=1u L=0.18u
Cl3977 s3977 0 10f
Mn3978 s3978 s3977 0 0 nch W=0.5u L=0.18u
Mp3978 s3978 s3977 vdd vdd pch W=1u L=0.18u
Cl3978 s3978 0 10f
Mn3979 s3979 s3978 0 0 nch W=0.5u L=0.18u
Mp3979 s3979 s3978 vdd vdd pch W=1u L=0.18u
Cl3979 s3979 0 10f
Mn3980 s3980 s3979 0 0 nch W=0.5u L=0.18u
Mp3980 s3980 s3979 vdd vdd pch W=1u L=0.18u
Cl3980 s3980 0 10f
Mn3981 s3981 s3980 0 0 nch W=0.5u L=0.18u
Mp3981 s3981 s3980 vdd vdd pch W=1u L=0.18u
Cl3981 s3981 0 10f
Mn3982 s3982 s3981 0 0 nch W=0.5u L=0.18u
Mp3982 s3982 s3981 vdd vdd pch W=1u L=0.18u
Cl3982 s3982 0 10f
Mn3983 s3983 s3982 0 0 nch W=0.5u L=0.18u
Mp3983 s3983 s3982 vdd vdd pch W=1u L=0.18u
Cl3983 s3983 0 10f
Mn3984 s3984 s3983 0 0 nch W=0.5u L=0.18u
Mp3984 s3984 s3983 vdd vdd pch W=1u L=0.18u
Cl3984 s3984 0 10f
Mn3985 s3985 s3984 0 0 nch W=0.5u L=0.18u
Mp3985 s3985 s3984 vdd vdd pch W=1u L=0.18u
Cl3985 s3985 0 10f
Mn3986 s3986 s3985 0 0 nch W=0.5u L=0.18u
Mp3986 s3986 s3985 vdd vdd pch W=1u L=0.18u
Cl3986 s3986 0 10f
Mn3987 s3987 s3986 0 0 nch W=0.5u L=0.18u
Mp3987 s3987 s3986 vdd vdd pch W=1u L=0.18u
Cl3987 s3987 0 10f
Mn3988 s3988 s3987 0 0 nch W=0.5u L=0.18u
Mp3988 s3988 s3987 vdd vdd pch W=1u L=0.18u
Cl3988 s3988 0 10f
Mn3989 s3989 s3988 0 0 nch W=0.5u L=0.18u
Mp3989 s3989 s3988 vdd vdd pch W=1u L=0.18u
Cl3989 s3989 0 10f
Mn3990 s3990 s3989 0 0 nch W=0.5u L=0.18u
Mp3990 s3990 s3989 vdd vdd pch W=1u L=0.18u
Cl3990 s3990 0 10f
Mn3991 s3991 s3990 0 0 nch W=0.5u L=0.18u
Mp3991 s3991 s3990 vdd vdd pch W=1u L=0.18u
Cl3991 s3991 0 10f
Mn3992 s3992 s3991 0 0 nch W=0.5u L=0.18u
Mp3992 s3992 s3991 vdd vdd pch W=1u L=0.18u
Cl3992 s3992 0 10f
Mn3993 s3993 s3992 0 0 nch W=0.5u L=0.18u
Mp3993 s3993 s3992 vdd vdd pch W=1u L=0.18u
Cl3993 s3993 0 10f
Mn3994 s3994 s3993 0 0 nch W=0.5u L=0.18u
Mp3994 s3994 s3993 vdd vdd pch W=1u L=0.18u
Cl3994 s3994 0 10f
Mn3995 s3995 s3994 0 0 nch W=0.5u L=0.18u
Mp3995 s3995 s3994 vdd vdd pch W=1u L=0.18u
Cl3995 s3995 0 10f
Mn3996 s3996 s3995 0 0 nch W=0.5u L=0.18u
Mp3996 s3996 s3995 vdd vdd pch W=1u L=0.18u
Cl3996 s3996 0 10f
Mn3997 s3997 s3996 0 0 nch W=0.5u L=0.18u
Mp3997 s3997 s3996 vdd vdd pch W=1u L=0.18u
Cl3997 s3997 0 10f
Mn3998 s3998 s3997 0 0 nch W=0.5u L=0.18u
Mp3998 s3998 s3997 vdd vdd pch W=1u L=0.18u
Cl3998 s3998 0 10f
Mn3999 s3999 s3998 0 0 nch W=0.5u L=0.18u
Mp3999 s3999 s3998 vdd vdd pch W=1u L=0.18u
Cl3999 s3999 0 10f
Mn4000 s4000 s3999 0 0 nch W=0.5u L=0.18u
Mp4000 s4000 s3999 vdd vdd pch W=1u L=0.18u
Cload s4000 0 10f
.tran 0.1n 50n
.end
