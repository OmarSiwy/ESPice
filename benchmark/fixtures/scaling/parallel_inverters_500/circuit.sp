* Parallel CMOS inverters: 500 instances — GPU batch stress test
.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
.model pch PMOS(level=1 VTO=-0.7 KP=50u GAMMA=0.57 LAMBDA=0.05 PHI=0.65)
Vdd vdd 0 DC 1.8
Vin in 0 PULSE(0 1.8 0 0.1n 0.1n 5n 10n)
Mn1 out1 in 0 0 nch W=0.5u L=0.18u
Mp1 out1 in vdd vdd pch W=1u L=0.18u
Cl1 out1 0 10f
Mn2 out2 in 0 0 nch W=0.5u L=0.18u
Mp2 out2 in vdd vdd pch W=1u L=0.18u
Cl2 out2 0 10f
Mn3 out3 in 0 0 nch W=0.5u L=0.18u
Mp3 out3 in vdd vdd pch W=1u L=0.18u
Cl3 out3 0 10f
Mn4 out4 in 0 0 nch W=0.5u L=0.18u
Mp4 out4 in vdd vdd pch W=1u L=0.18u
Cl4 out4 0 10f
Mn5 out5 in 0 0 nch W=0.5u L=0.18u
Mp5 out5 in vdd vdd pch W=1u L=0.18u
Cl5 out5 0 10f
Mn6 out6 in 0 0 nch W=0.5u L=0.18u
Mp6 out6 in vdd vdd pch W=1u L=0.18u
Cl6 out6 0 10f
Mn7 out7 in 0 0 nch W=0.5u L=0.18u
Mp7 out7 in vdd vdd pch W=1u L=0.18u
Cl7 out7 0 10f
Mn8 out8 in 0 0 nch W=0.5u L=0.18u
Mp8 out8 in vdd vdd pch W=1u L=0.18u
Cl8 out8 0 10f
Mn9 out9 in 0 0 nch W=0.5u L=0.18u
Mp9 out9 in vdd vdd pch W=1u L=0.18u
Cl9 out9 0 10f
Mn10 out10 in 0 0 nch W=0.5u L=0.18u
Mp10 out10 in vdd vdd pch W=1u L=0.18u
Cl10 out10 0 10f
Mn11 out11 in 0 0 nch W=0.5u L=0.18u
Mp11 out11 in vdd vdd pch W=1u L=0.18u
Cl11 out11 0 10f
Mn12 out12 in 0 0 nch W=0.5u L=0.18u
Mp12 out12 in vdd vdd pch W=1u L=0.18u
Cl12 out12 0 10f
Mn13 out13 in 0 0 nch W=0.5u L=0.18u
Mp13 out13 in vdd vdd pch W=1u L=0.18u
Cl13 out13 0 10f
Mn14 out14 in 0 0 nch W=0.5u L=0.18u
Mp14 out14 in vdd vdd pch W=1u L=0.18u
Cl14 out14 0 10f
Mn15 out15 in 0 0 nch W=0.5u L=0.18u
Mp15 out15 in vdd vdd pch W=1u L=0.18u
Cl15 out15 0 10f
Mn16 out16 in 0 0 nch W=0.5u L=0.18u
Mp16 out16 in vdd vdd pch W=1u L=0.18u
Cl16 out16 0 10f
Mn17 out17 in 0 0 nch W=0.5u L=0.18u
Mp17 out17 in vdd vdd pch W=1u L=0.18u
Cl17 out17 0 10f
Mn18 out18 in 0 0 nch W=0.5u L=0.18u
Mp18 out18 in vdd vdd pch W=1u L=0.18u
Cl18 out18 0 10f
Mn19 out19 in 0 0 nch W=0.5u L=0.18u
Mp19 out19 in vdd vdd pch W=1u L=0.18u
Cl19 out19 0 10f
Mn20 out20 in 0 0 nch W=0.5u L=0.18u
Mp20 out20 in vdd vdd pch W=1u L=0.18u
Cl20 out20 0 10f
Mn21 out21 in 0 0 nch W=0.5u L=0.18u
Mp21 out21 in vdd vdd pch W=1u L=0.18u
Cl21 out21 0 10f
Mn22 out22 in 0 0 nch W=0.5u L=0.18u
Mp22 out22 in vdd vdd pch W=1u L=0.18u
Cl22 out22 0 10f
Mn23 out23 in 0 0 nch W=0.5u L=0.18u
Mp23 out23 in vdd vdd pch W=1u L=0.18u
Cl23 out23 0 10f
Mn24 out24 in 0 0 nch W=0.5u L=0.18u
Mp24 out24 in vdd vdd pch W=1u L=0.18u
Cl24 out24 0 10f
Mn25 out25 in 0 0 nch W=0.5u L=0.18u
Mp25 out25 in vdd vdd pch W=1u L=0.18u
Cl25 out25 0 10f
Mn26 out26 in 0 0 nch W=0.5u L=0.18u
Mp26 out26 in vdd vdd pch W=1u L=0.18u
Cl26 out26 0 10f
Mn27 out27 in 0 0 nch W=0.5u L=0.18u
Mp27 out27 in vdd vdd pch W=1u L=0.18u
Cl27 out27 0 10f
Mn28 out28 in 0 0 nch W=0.5u L=0.18u
Mp28 out28 in vdd vdd pch W=1u L=0.18u
Cl28 out28 0 10f
Mn29 out29 in 0 0 nch W=0.5u L=0.18u
Mp29 out29 in vdd vdd pch W=1u L=0.18u
Cl29 out29 0 10f
Mn30 out30 in 0 0 nch W=0.5u L=0.18u
Mp30 out30 in vdd vdd pch W=1u L=0.18u
Cl30 out30 0 10f
Mn31 out31 in 0 0 nch W=0.5u L=0.18u
Mp31 out31 in vdd vdd pch W=1u L=0.18u
Cl31 out31 0 10f
Mn32 out32 in 0 0 nch W=0.5u L=0.18u
Mp32 out32 in vdd vdd pch W=1u L=0.18u
Cl32 out32 0 10f
Mn33 out33 in 0 0 nch W=0.5u L=0.18u
Mp33 out33 in vdd vdd pch W=1u L=0.18u
Cl33 out33 0 10f
Mn34 out34 in 0 0 nch W=0.5u L=0.18u
Mp34 out34 in vdd vdd pch W=1u L=0.18u
Cl34 out34 0 10f
Mn35 out35 in 0 0 nch W=0.5u L=0.18u
Mp35 out35 in vdd vdd pch W=1u L=0.18u
Cl35 out35 0 10f
Mn36 out36 in 0 0 nch W=0.5u L=0.18u
Mp36 out36 in vdd vdd pch W=1u L=0.18u
Cl36 out36 0 10f
Mn37 out37 in 0 0 nch W=0.5u L=0.18u
Mp37 out37 in vdd vdd pch W=1u L=0.18u
Cl37 out37 0 10f
Mn38 out38 in 0 0 nch W=0.5u L=0.18u
Mp38 out38 in vdd vdd pch W=1u L=0.18u
Cl38 out38 0 10f
Mn39 out39 in 0 0 nch W=0.5u L=0.18u
Mp39 out39 in vdd vdd pch W=1u L=0.18u
Cl39 out39 0 10f
Mn40 out40 in 0 0 nch W=0.5u L=0.18u
Mp40 out40 in vdd vdd pch W=1u L=0.18u
Cl40 out40 0 10f
Mn41 out41 in 0 0 nch W=0.5u L=0.18u
Mp41 out41 in vdd vdd pch W=1u L=0.18u
Cl41 out41 0 10f
Mn42 out42 in 0 0 nch W=0.5u L=0.18u
Mp42 out42 in vdd vdd pch W=1u L=0.18u
Cl42 out42 0 10f
Mn43 out43 in 0 0 nch W=0.5u L=0.18u
Mp43 out43 in vdd vdd pch W=1u L=0.18u
Cl43 out43 0 10f
Mn44 out44 in 0 0 nch W=0.5u L=0.18u
Mp44 out44 in vdd vdd pch W=1u L=0.18u
Cl44 out44 0 10f
Mn45 out45 in 0 0 nch W=0.5u L=0.18u
Mp45 out45 in vdd vdd pch W=1u L=0.18u
Cl45 out45 0 10f
Mn46 out46 in 0 0 nch W=0.5u L=0.18u
Mp46 out46 in vdd vdd pch W=1u L=0.18u
Cl46 out46 0 10f
Mn47 out47 in 0 0 nch W=0.5u L=0.18u
Mp47 out47 in vdd vdd pch W=1u L=0.18u
Cl47 out47 0 10f
Mn48 out48 in 0 0 nch W=0.5u L=0.18u
Mp48 out48 in vdd vdd pch W=1u L=0.18u
Cl48 out48 0 10f
Mn49 out49 in 0 0 nch W=0.5u L=0.18u
Mp49 out49 in vdd vdd pch W=1u L=0.18u
Cl49 out49 0 10f
Mn50 out50 in 0 0 nch W=0.5u L=0.18u
Mp50 out50 in vdd vdd pch W=1u L=0.18u
Cl50 out50 0 10f
Mn51 out51 in 0 0 nch W=0.5u L=0.18u
Mp51 out51 in vdd vdd pch W=1u L=0.18u
Cl51 out51 0 10f
Mn52 out52 in 0 0 nch W=0.5u L=0.18u
Mp52 out52 in vdd vdd pch W=1u L=0.18u
Cl52 out52 0 10f
Mn53 out53 in 0 0 nch W=0.5u L=0.18u
Mp53 out53 in vdd vdd pch W=1u L=0.18u
Cl53 out53 0 10f
Mn54 out54 in 0 0 nch W=0.5u L=0.18u
Mp54 out54 in vdd vdd pch W=1u L=0.18u
Cl54 out54 0 10f
Mn55 out55 in 0 0 nch W=0.5u L=0.18u
Mp55 out55 in vdd vdd pch W=1u L=0.18u
Cl55 out55 0 10f
Mn56 out56 in 0 0 nch W=0.5u L=0.18u
Mp56 out56 in vdd vdd pch W=1u L=0.18u
Cl56 out56 0 10f
Mn57 out57 in 0 0 nch W=0.5u L=0.18u
Mp57 out57 in vdd vdd pch W=1u L=0.18u
Cl57 out57 0 10f
Mn58 out58 in 0 0 nch W=0.5u L=0.18u
Mp58 out58 in vdd vdd pch W=1u L=0.18u
Cl58 out58 0 10f
Mn59 out59 in 0 0 nch W=0.5u L=0.18u
Mp59 out59 in vdd vdd pch W=1u L=0.18u
Cl59 out59 0 10f
Mn60 out60 in 0 0 nch W=0.5u L=0.18u
Mp60 out60 in vdd vdd pch W=1u L=0.18u
Cl60 out60 0 10f
Mn61 out61 in 0 0 nch W=0.5u L=0.18u
Mp61 out61 in vdd vdd pch W=1u L=0.18u
Cl61 out61 0 10f
Mn62 out62 in 0 0 nch W=0.5u L=0.18u
Mp62 out62 in vdd vdd pch W=1u L=0.18u
Cl62 out62 0 10f
Mn63 out63 in 0 0 nch W=0.5u L=0.18u
Mp63 out63 in vdd vdd pch W=1u L=0.18u
Cl63 out63 0 10f
Mn64 out64 in 0 0 nch W=0.5u L=0.18u
Mp64 out64 in vdd vdd pch W=1u L=0.18u
Cl64 out64 0 10f
Mn65 out65 in 0 0 nch W=0.5u L=0.18u
Mp65 out65 in vdd vdd pch W=1u L=0.18u
Cl65 out65 0 10f
Mn66 out66 in 0 0 nch W=0.5u L=0.18u
Mp66 out66 in vdd vdd pch W=1u L=0.18u
Cl66 out66 0 10f
Mn67 out67 in 0 0 nch W=0.5u L=0.18u
Mp67 out67 in vdd vdd pch W=1u L=0.18u
Cl67 out67 0 10f
Mn68 out68 in 0 0 nch W=0.5u L=0.18u
Mp68 out68 in vdd vdd pch W=1u L=0.18u
Cl68 out68 0 10f
Mn69 out69 in 0 0 nch W=0.5u L=0.18u
Mp69 out69 in vdd vdd pch W=1u L=0.18u
Cl69 out69 0 10f
Mn70 out70 in 0 0 nch W=0.5u L=0.18u
Mp70 out70 in vdd vdd pch W=1u L=0.18u
Cl70 out70 0 10f
Mn71 out71 in 0 0 nch W=0.5u L=0.18u
Mp71 out71 in vdd vdd pch W=1u L=0.18u
Cl71 out71 0 10f
Mn72 out72 in 0 0 nch W=0.5u L=0.18u
Mp72 out72 in vdd vdd pch W=1u L=0.18u
Cl72 out72 0 10f
Mn73 out73 in 0 0 nch W=0.5u L=0.18u
Mp73 out73 in vdd vdd pch W=1u L=0.18u
Cl73 out73 0 10f
Mn74 out74 in 0 0 nch W=0.5u L=0.18u
Mp74 out74 in vdd vdd pch W=1u L=0.18u
Cl74 out74 0 10f
Mn75 out75 in 0 0 nch W=0.5u L=0.18u
Mp75 out75 in vdd vdd pch W=1u L=0.18u
Cl75 out75 0 10f
Mn76 out76 in 0 0 nch W=0.5u L=0.18u
Mp76 out76 in vdd vdd pch W=1u L=0.18u
Cl76 out76 0 10f
Mn77 out77 in 0 0 nch W=0.5u L=0.18u
Mp77 out77 in vdd vdd pch W=1u L=0.18u
Cl77 out77 0 10f
Mn78 out78 in 0 0 nch W=0.5u L=0.18u
Mp78 out78 in vdd vdd pch W=1u L=0.18u
Cl78 out78 0 10f
Mn79 out79 in 0 0 nch W=0.5u L=0.18u
Mp79 out79 in vdd vdd pch W=1u L=0.18u
Cl79 out79 0 10f
Mn80 out80 in 0 0 nch W=0.5u L=0.18u
Mp80 out80 in vdd vdd pch W=1u L=0.18u
Cl80 out80 0 10f
Mn81 out81 in 0 0 nch W=0.5u L=0.18u
Mp81 out81 in vdd vdd pch W=1u L=0.18u
Cl81 out81 0 10f
Mn82 out82 in 0 0 nch W=0.5u L=0.18u
Mp82 out82 in vdd vdd pch W=1u L=0.18u
Cl82 out82 0 10f
Mn83 out83 in 0 0 nch W=0.5u L=0.18u
Mp83 out83 in vdd vdd pch W=1u L=0.18u
Cl83 out83 0 10f
Mn84 out84 in 0 0 nch W=0.5u L=0.18u
Mp84 out84 in vdd vdd pch W=1u L=0.18u
Cl84 out84 0 10f
Mn85 out85 in 0 0 nch W=0.5u L=0.18u
Mp85 out85 in vdd vdd pch W=1u L=0.18u
Cl85 out85 0 10f
Mn86 out86 in 0 0 nch W=0.5u L=0.18u
Mp86 out86 in vdd vdd pch W=1u L=0.18u
Cl86 out86 0 10f
Mn87 out87 in 0 0 nch W=0.5u L=0.18u
Mp87 out87 in vdd vdd pch W=1u L=0.18u
Cl87 out87 0 10f
Mn88 out88 in 0 0 nch W=0.5u L=0.18u
Mp88 out88 in vdd vdd pch W=1u L=0.18u
Cl88 out88 0 10f
Mn89 out89 in 0 0 nch W=0.5u L=0.18u
Mp89 out89 in vdd vdd pch W=1u L=0.18u
Cl89 out89 0 10f
Mn90 out90 in 0 0 nch W=0.5u L=0.18u
Mp90 out90 in vdd vdd pch W=1u L=0.18u
Cl90 out90 0 10f
Mn91 out91 in 0 0 nch W=0.5u L=0.18u
Mp91 out91 in vdd vdd pch W=1u L=0.18u
Cl91 out91 0 10f
Mn92 out92 in 0 0 nch W=0.5u L=0.18u
Mp92 out92 in vdd vdd pch W=1u L=0.18u
Cl92 out92 0 10f
Mn93 out93 in 0 0 nch W=0.5u L=0.18u
Mp93 out93 in vdd vdd pch W=1u L=0.18u
Cl93 out93 0 10f
Mn94 out94 in 0 0 nch W=0.5u L=0.18u
Mp94 out94 in vdd vdd pch W=1u L=0.18u
Cl94 out94 0 10f
Mn95 out95 in 0 0 nch W=0.5u L=0.18u
Mp95 out95 in vdd vdd pch W=1u L=0.18u
Cl95 out95 0 10f
Mn96 out96 in 0 0 nch W=0.5u L=0.18u
Mp96 out96 in vdd vdd pch W=1u L=0.18u
Cl96 out96 0 10f
Mn97 out97 in 0 0 nch W=0.5u L=0.18u
Mp97 out97 in vdd vdd pch W=1u L=0.18u
Cl97 out97 0 10f
Mn98 out98 in 0 0 nch W=0.5u L=0.18u
Mp98 out98 in vdd vdd pch W=1u L=0.18u
Cl98 out98 0 10f
Mn99 out99 in 0 0 nch W=0.5u L=0.18u
Mp99 out99 in vdd vdd pch W=1u L=0.18u
Cl99 out99 0 10f
Mn100 out100 in 0 0 nch W=0.5u L=0.18u
Mp100 out100 in vdd vdd pch W=1u L=0.18u
Cl100 out100 0 10f
Mn101 out101 in 0 0 nch W=0.5u L=0.18u
Mp101 out101 in vdd vdd pch W=1u L=0.18u
Cl101 out101 0 10f
Mn102 out102 in 0 0 nch W=0.5u L=0.18u
Mp102 out102 in vdd vdd pch W=1u L=0.18u
Cl102 out102 0 10f
Mn103 out103 in 0 0 nch W=0.5u L=0.18u
Mp103 out103 in vdd vdd pch W=1u L=0.18u
Cl103 out103 0 10f
Mn104 out104 in 0 0 nch W=0.5u L=0.18u
Mp104 out104 in vdd vdd pch W=1u L=0.18u
Cl104 out104 0 10f
Mn105 out105 in 0 0 nch W=0.5u L=0.18u
Mp105 out105 in vdd vdd pch W=1u L=0.18u
Cl105 out105 0 10f
Mn106 out106 in 0 0 nch W=0.5u L=0.18u
Mp106 out106 in vdd vdd pch W=1u L=0.18u
Cl106 out106 0 10f
Mn107 out107 in 0 0 nch W=0.5u L=0.18u
Mp107 out107 in vdd vdd pch W=1u L=0.18u
Cl107 out107 0 10f
Mn108 out108 in 0 0 nch W=0.5u L=0.18u
Mp108 out108 in vdd vdd pch W=1u L=0.18u
Cl108 out108 0 10f
Mn109 out109 in 0 0 nch W=0.5u L=0.18u
Mp109 out109 in vdd vdd pch W=1u L=0.18u
Cl109 out109 0 10f
Mn110 out110 in 0 0 nch W=0.5u L=0.18u
Mp110 out110 in vdd vdd pch W=1u L=0.18u
Cl110 out110 0 10f
Mn111 out111 in 0 0 nch W=0.5u L=0.18u
Mp111 out111 in vdd vdd pch W=1u L=0.18u
Cl111 out111 0 10f
Mn112 out112 in 0 0 nch W=0.5u L=0.18u
Mp112 out112 in vdd vdd pch W=1u L=0.18u
Cl112 out112 0 10f
Mn113 out113 in 0 0 nch W=0.5u L=0.18u
Mp113 out113 in vdd vdd pch W=1u L=0.18u
Cl113 out113 0 10f
Mn114 out114 in 0 0 nch W=0.5u L=0.18u
Mp114 out114 in vdd vdd pch W=1u L=0.18u
Cl114 out114 0 10f
Mn115 out115 in 0 0 nch W=0.5u L=0.18u
Mp115 out115 in vdd vdd pch W=1u L=0.18u
Cl115 out115 0 10f
Mn116 out116 in 0 0 nch W=0.5u L=0.18u
Mp116 out116 in vdd vdd pch W=1u L=0.18u
Cl116 out116 0 10f
Mn117 out117 in 0 0 nch W=0.5u L=0.18u
Mp117 out117 in vdd vdd pch W=1u L=0.18u
Cl117 out117 0 10f
Mn118 out118 in 0 0 nch W=0.5u L=0.18u
Mp118 out118 in vdd vdd pch W=1u L=0.18u
Cl118 out118 0 10f
Mn119 out119 in 0 0 nch W=0.5u L=0.18u
Mp119 out119 in vdd vdd pch W=1u L=0.18u
Cl119 out119 0 10f
Mn120 out120 in 0 0 nch W=0.5u L=0.18u
Mp120 out120 in vdd vdd pch W=1u L=0.18u
Cl120 out120 0 10f
Mn121 out121 in 0 0 nch W=0.5u L=0.18u
Mp121 out121 in vdd vdd pch W=1u L=0.18u
Cl121 out121 0 10f
Mn122 out122 in 0 0 nch W=0.5u L=0.18u
Mp122 out122 in vdd vdd pch W=1u L=0.18u
Cl122 out122 0 10f
Mn123 out123 in 0 0 nch W=0.5u L=0.18u
Mp123 out123 in vdd vdd pch W=1u L=0.18u
Cl123 out123 0 10f
Mn124 out124 in 0 0 nch W=0.5u L=0.18u
Mp124 out124 in vdd vdd pch W=1u L=0.18u
Cl124 out124 0 10f
Mn125 out125 in 0 0 nch W=0.5u L=0.18u
Mp125 out125 in vdd vdd pch W=1u L=0.18u
Cl125 out125 0 10f
Mn126 out126 in 0 0 nch W=0.5u L=0.18u
Mp126 out126 in vdd vdd pch W=1u L=0.18u
Cl126 out126 0 10f
Mn127 out127 in 0 0 nch W=0.5u L=0.18u
Mp127 out127 in vdd vdd pch W=1u L=0.18u
Cl127 out127 0 10f
Mn128 out128 in 0 0 nch W=0.5u L=0.18u
Mp128 out128 in vdd vdd pch W=1u L=0.18u
Cl128 out128 0 10f
Mn129 out129 in 0 0 nch W=0.5u L=0.18u
Mp129 out129 in vdd vdd pch W=1u L=0.18u
Cl129 out129 0 10f
Mn130 out130 in 0 0 nch W=0.5u L=0.18u
Mp130 out130 in vdd vdd pch W=1u L=0.18u
Cl130 out130 0 10f
Mn131 out131 in 0 0 nch W=0.5u L=0.18u
Mp131 out131 in vdd vdd pch W=1u L=0.18u
Cl131 out131 0 10f
Mn132 out132 in 0 0 nch W=0.5u L=0.18u
Mp132 out132 in vdd vdd pch W=1u L=0.18u
Cl132 out132 0 10f
Mn133 out133 in 0 0 nch W=0.5u L=0.18u
Mp133 out133 in vdd vdd pch W=1u L=0.18u
Cl133 out133 0 10f
Mn134 out134 in 0 0 nch W=0.5u L=0.18u
Mp134 out134 in vdd vdd pch W=1u L=0.18u
Cl134 out134 0 10f
Mn135 out135 in 0 0 nch W=0.5u L=0.18u
Mp135 out135 in vdd vdd pch W=1u L=0.18u
Cl135 out135 0 10f
Mn136 out136 in 0 0 nch W=0.5u L=0.18u
Mp136 out136 in vdd vdd pch W=1u L=0.18u
Cl136 out136 0 10f
Mn137 out137 in 0 0 nch W=0.5u L=0.18u
Mp137 out137 in vdd vdd pch W=1u L=0.18u
Cl137 out137 0 10f
Mn138 out138 in 0 0 nch W=0.5u L=0.18u
Mp138 out138 in vdd vdd pch W=1u L=0.18u
Cl138 out138 0 10f
Mn139 out139 in 0 0 nch W=0.5u L=0.18u
Mp139 out139 in vdd vdd pch W=1u L=0.18u
Cl139 out139 0 10f
Mn140 out140 in 0 0 nch W=0.5u L=0.18u
Mp140 out140 in vdd vdd pch W=1u L=0.18u
Cl140 out140 0 10f
Mn141 out141 in 0 0 nch W=0.5u L=0.18u
Mp141 out141 in vdd vdd pch W=1u L=0.18u
Cl141 out141 0 10f
Mn142 out142 in 0 0 nch W=0.5u L=0.18u
Mp142 out142 in vdd vdd pch W=1u L=0.18u
Cl142 out142 0 10f
Mn143 out143 in 0 0 nch W=0.5u L=0.18u
Mp143 out143 in vdd vdd pch W=1u L=0.18u
Cl143 out143 0 10f
Mn144 out144 in 0 0 nch W=0.5u L=0.18u
Mp144 out144 in vdd vdd pch W=1u L=0.18u
Cl144 out144 0 10f
Mn145 out145 in 0 0 nch W=0.5u L=0.18u
Mp145 out145 in vdd vdd pch W=1u L=0.18u
Cl145 out145 0 10f
Mn146 out146 in 0 0 nch W=0.5u L=0.18u
Mp146 out146 in vdd vdd pch W=1u L=0.18u
Cl146 out146 0 10f
Mn147 out147 in 0 0 nch W=0.5u L=0.18u
Mp147 out147 in vdd vdd pch W=1u L=0.18u
Cl147 out147 0 10f
Mn148 out148 in 0 0 nch W=0.5u L=0.18u
Mp148 out148 in vdd vdd pch W=1u L=0.18u
Cl148 out148 0 10f
Mn149 out149 in 0 0 nch W=0.5u L=0.18u
Mp149 out149 in vdd vdd pch W=1u L=0.18u
Cl149 out149 0 10f
Mn150 out150 in 0 0 nch W=0.5u L=0.18u
Mp150 out150 in vdd vdd pch W=1u L=0.18u
Cl150 out150 0 10f
Mn151 out151 in 0 0 nch W=0.5u L=0.18u
Mp151 out151 in vdd vdd pch W=1u L=0.18u
Cl151 out151 0 10f
Mn152 out152 in 0 0 nch W=0.5u L=0.18u
Mp152 out152 in vdd vdd pch W=1u L=0.18u
Cl152 out152 0 10f
Mn153 out153 in 0 0 nch W=0.5u L=0.18u
Mp153 out153 in vdd vdd pch W=1u L=0.18u
Cl153 out153 0 10f
Mn154 out154 in 0 0 nch W=0.5u L=0.18u
Mp154 out154 in vdd vdd pch W=1u L=0.18u
Cl154 out154 0 10f
Mn155 out155 in 0 0 nch W=0.5u L=0.18u
Mp155 out155 in vdd vdd pch W=1u L=0.18u
Cl155 out155 0 10f
Mn156 out156 in 0 0 nch W=0.5u L=0.18u
Mp156 out156 in vdd vdd pch W=1u L=0.18u
Cl156 out156 0 10f
Mn157 out157 in 0 0 nch W=0.5u L=0.18u
Mp157 out157 in vdd vdd pch W=1u L=0.18u
Cl157 out157 0 10f
Mn158 out158 in 0 0 nch W=0.5u L=0.18u
Mp158 out158 in vdd vdd pch W=1u L=0.18u
Cl158 out158 0 10f
Mn159 out159 in 0 0 nch W=0.5u L=0.18u
Mp159 out159 in vdd vdd pch W=1u L=0.18u
Cl159 out159 0 10f
Mn160 out160 in 0 0 nch W=0.5u L=0.18u
Mp160 out160 in vdd vdd pch W=1u L=0.18u
Cl160 out160 0 10f
Mn161 out161 in 0 0 nch W=0.5u L=0.18u
Mp161 out161 in vdd vdd pch W=1u L=0.18u
Cl161 out161 0 10f
Mn162 out162 in 0 0 nch W=0.5u L=0.18u
Mp162 out162 in vdd vdd pch W=1u L=0.18u
Cl162 out162 0 10f
Mn163 out163 in 0 0 nch W=0.5u L=0.18u
Mp163 out163 in vdd vdd pch W=1u L=0.18u
Cl163 out163 0 10f
Mn164 out164 in 0 0 nch W=0.5u L=0.18u
Mp164 out164 in vdd vdd pch W=1u L=0.18u
Cl164 out164 0 10f
Mn165 out165 in 0 0 nch W=0.5u L=0.18u
Mp165 out165 in vdd vdd pch W=1u L=0.18u
Cl165 out165 0 10f
Mn166 out166 in 0 0 nch W=0.5u L=0.18u
Mp166 out166 in vdd vdd pch W=1u L=0.18u
Cl166 out166 0 10f
Mn167 out167 in 0 0 nch W=0.5u L=0.18u
Mp167 out167 in vdd vdd pch W=1u L=0.18u
Cl167 out167 0 10f
Mn168 out168 in 0 0 nch W=0.5u L=0.18u
Mp168 out168 in vdd vdd pch W=1u L=0.18u
Cl168 out168 0 10f
Mn169 out169 in 0 0 nch W=0.5u L=0.18u
Mp169 out169 in vdd vdd pch W=1u L=0.18u
Cl169 out169 0 10f
Mn170 out170 in 0 0 nch W=0.5u L=0.18u
Mp170 out170 in vdd vdd pch W=1u L=0.18u
Cl170 out170 0 10f
Mn171 out171 in 0 0 nch W=0.5u L=0.18u
Mp171 out171 in vdd vdd pch W=1u L=0.18u
Cl171 out171 0 10f
Mn172 out172 in 0 0 nch W=0.5u L=0.18u
Mp172 out172 in vdd vdd pch W=1u L=0.18u
Cl172 out172 0 10f
Mn173 out173 in 0 0 nch W=0.5u L=0.18u
Mp173 out173 in vdd vdd pch W=1u L=0.18u
Cl173 out173 0 10f
Mn174 out174 in 0 0 nch W=0.5u L=0.18u
Mp174 out174 in vdd vdd pch W=1u L=0.18u
Cl174 out174 0 10f
Mn175 out175 in 0 0 nch W=0.5u L=0.18u
Mp175 out175 in vdd vdd pch W=1u L=0.18u
Cl175 out175 0 10f
Mn176 out176 in 0 0 nch W=0.5u L=0.18u
Mp176 out176 in vdd vdd pch W=1u L=0.18u
Cl176 out176 0 10f
Mn177 out177 in 0 0 nch W=0.5u L=0.18u
Mp177 out177 in vdd vdd pch W=1u L=0.18u
Cl177 out177 0 10f
Mn178 out178 in 0 0 nch W=0.5u L=0.18u
Mp178 out178 in vdd vdd pch W=1u L=0.18u
Cl178 out178 0 10f
Mn179 out179 in 0 0 nch W=0.5u L=0.18u
Mp179 out179 in vdd vdd pch W=1u L=0.18u
Cl179 out179 0 10f
Mn180 out180 in 0 0 nch W=0.5u L=0.18u
Mp180 out180 in vdd vdd pch W=1u L=0.18u
Cl180 out180 0 10f
Mn181 out181 in 0 0 nch W=0.5u L=0.18u
Mp181 out181 in vdd vdd pch W=1u L=0.18u
Cl181 out181 0 10f
Mn182 out182 in 0 0 nch W=0.5u L=0.18u
Mp182 out182 in vdd vdd pch W=1u L=0.18u
Cl182 out182 0 10f
Mn183 out183 in 0 0 nch W=0.5u L=0.18u
Mp183 out183 in vdd vdd pch W=1u L=0.18u
Cl183 out183 0 10f
Mn184 out184 in 0 0 nch W=0.5u L=0.18u
Mp184 out184 in vdd vdd pch W=1u L=0.18u
Cl184 out184 0 10f
Mn185 out185 in 0 0 nch W=0.5u L=0.18u
Mp185 out185 in vdd vdd pch W=1u L=0.18u
Cl185 out185 0 10f
Mn186 out186 in 0 0 nch W=0.5u L=0.18u
Mp186 out186 in vdd vdd pch W=1u L=0.18u
Cl186 out186 0 10f
Mn187 out187 in 0 0 nch W=0.5u L=0.18u
Mp187 out187 in vdd vdd pch W=1u L=0.18u
Cl187 out187 0 10f
Mn188 out188 in 0 0 nch W=0.5u L=0.18u
Mp188 out188 in vdd vdd pch W=1u L=0.18u
Cl188 out188 0 10f
Mn189 out189 in 0 0 nch W=0.5u L=0.18u
Mp189 out189 in vdd vdd pch W=1u L=0.18u
Cl189 out189 0 10f
Mn190 out190 in 0 0 nch W=0.5u L=0.18u
Mp190 out190 in vdd vdd pch W=1u L=0.18u
Cl190 out190 0 10f
Mn191 out191 in 0 0 nch W=0.5u L=0.18u
Mp191 out191 in vdd vdd pch W=1u L=0.18u
Cl191 out191 0 10f
Mn192 out192 in 0 0 nch W=0.5u L=0.18u
Mp192 out192 in vdd vdd pch W=1u L=0.18u
Cl192 out192 0 10f
Mn193 out193 in 0 0 nch W=0.5u L=0.18u
Mp193 out193 in vdd vdd pch W=1u L=0.18u
Cl193 out193 0 10f
Mn194 out194 in 0 0 nch W=0.5u L=0.18u
Mp194 out194 in vdd vdd pch W=1u L=0.18u
Cl194 out194 0 10f
Mn195 out195 in 0 0 nch W=0.5u L=0.18u
Mp195 out195 in vdd vdd pch W=1u L=0.18u
Cl195 out195 0 10f
Mn196 out196 in 0 0 nch W=0.5u L=0.18u
Mp196 out196 in vdd vdd pch W=1u L=0.18u
Cl196 out196 0 10f
Mn197 out197 in 0 0 nch W=0.5u L=0.18u
Mp197 out197 in vdd vdd pch W=1u L=0.18u
Cl197 out197 0 10f
Mn198 out198 in 0 0 nch W=0.5u L=0.18u
Mp198 out198 in vdd vdd pch W=1u L=0.18u
Cl198 out198 0 10f
Mn199 out199 in 0 0 nch W=0.5u L=0.18u
Mp199 out199 in vdd vdd pch W=1u L=0.18u
Cl199 out199 0 10f
Mn200 out200 in 0 0 nch W=0.5u L=0.18u
Mp200 out200 in vdd vdd pch W=1u L=0.18u
Cl200 out200 0 10f
Mn201 out201 in 0 0 nch W=0.5u L=0.18u
Mp201 out201 in vdd vdd pch W=1u L=0.18u
Cl201 out201 0 10f
Mn202 out202 in 0 0 nch W=0.5u L=0.18u
Mp202 out202 in vdd vdd pch W=1u L=0.18u
Cl202 out202 0 10f
Mn203 out203 in 0 0 nch W=0.5u L=0.18u
Mp203 out203 in vdd vdd pch W=1u L=0.18u
Cl203 out203 0 10f
Mn204 out204 in 0 0 nch W=0.5u L=0.18u
Mp204 out204 in vdd vdd pch W=1u L=0.18u
Cl204 out204 0 10f
Mn205 out205 in 0 0 nch W=0.5u L=0.18u
Mp205 out205 in vdd vdd pch W=1u L=0.18u
Cl205 out205 0 10f
Mn206 out206 in 0 0 nch W=0.5u L=0.18u
Mp206 out206 in vdd vdd pch W=1u L=0.18u
Cl206 out206 0 10f
Mn207 out207 in 0 0 nch W=0.5u L=0.18u
Mp207 out207 in vdd vdd pch W=1u L=0.18u
Cl207 out207 0 10f
Mn208 out208 in 0 0 nch W=0.5u L=0.18u
Mp208 out208 in vdd vdd pch W=1u L=0.18u
Cl208 out208 0 10f
Mn209 out209 in 0 0 nch W=0.5u L=0.18u
Mp209 out209 in vdd vdd pch W=1u L=0.18u
Cl209 out209 0 10f
Mn210 out210 in 0 0 nch W=0.5u L=0.18u
Mp210 out210 in vdd vdd pch W=1u L=0.18u
Cl210 out210 0 10f
Mn211 out211 in 0 0 nch W=0.5u L=0.18u
Mp211 out211 in vdd vdd pch W=1u L=0.18u
Cl211 out211 0 10f
Mn212 out212 in 0 0 nch W=0.5u L=0.18u
Mp212 out212 in vdd vdd pch W=1u L=0.18u
Cl212 out212 0 10f
Mn213 out213 in 0 0 nch W=0.5u L=0.18u
Mp213 out213 in vdd vdd pch W=1u L=0.18u
Cl213 out213 0 10f
Mn214 out214 in 0 0 nch W=0.5u L=0.18u
Mp214 out214 in vdd vdd pch W=1u L=0.18u
Cl214 out214 0 10f
Mn215 out215 in 0 0 nch W=0.5u L=0.18u
Mp215 out215 in vdd vdd pch W=1u L=0.18u
Cl215 out215 0 10f
Mn216 out216 in 0 0 nch W=0.5u L=0.18u
Mp216 out216 in vdd vdd pch W=1u L=0.18u
Cl216 out216 0 10f
Mn217 out217 in 0 0 nch W=0.5u L=0.18u
Mp217 out217 in vdd vdd pch W=1u L=0.18u
Cl217 out217 0 10f
Mn218 out218 in 0 0 nch W=0.5u L=0.18u
Mp218 out218 in vdd vdd pch W=1u L=0.18u
Cl218 out218 0 10f
Mn219 out219 in 0 0 nch W=0.5u L=0.18u
Mp219 out219 in vdd vdd pch W=1u L=0.18u
Cl219 out219 0 10f
Mn220 out220 in 0 0 nch W=0.5u L=0.18u
Mp220 out220 in vdd vdd pch W=1u L=0.18u
Cl220 out220 0 10f
Mn221 out221 in 0 0 nch W=0.5u L=0.18u
Mp221 out221 in vdd vdd pch W=1u L=0.18u
Cl221 out221 0 10f
Mn222 out222 in 0 0 nch W=0.5u L=0.18u
Mp222 out222 in vdd vdd pch W=1u L=0.18u
Cl222 out222 0 10f
Mn223 out223 in 0 0 nch W=0.5u L=0.18u
Mp223 out223 in vdd vdd pch W=1u L=0.18u
Cl223 out223 0 10f
Mn224 out224 in 0 0 nch W=0.5u L=0.18u
Mp224 out224 in vdd vdd pch W=1u L=0.18u
Cl224 out224 0 10f
Mn225 out225 in 0 0 nch W=0.5u L=0.18u
Mp225 out225 in vdd vdd pch W=1u L=0.18u
Cl225 out225 0 10f
Mn226 out226 in 0 0 nch W=0.5u L=0.18u
Mp226 out226 in vdd vdd pch W=1u L=0.18u
Cl226 out226 0 10f
Mn227 out227 in 0 0 nch W=0.5u L=0.18u
Mp227 out227 in vdd vdd pch W=1u L=0.18u
Cl227 out227 0 10f
Mn228 out228 in 0 0 nch W=0.5u L=0.18u
Mp228 out228 in vdd vdd pch W=1u L=0.18u
Cl228 out228 0 10f
Mn229 out229 in 0 0 nch W=0.5u L=0.18u
Mp229 out229 in vdd vdd pch W=1u L=0.18u
Cl229 out229 0 10f
Mn230 out230 in 0 0 nch W=0.5u L=0.18u
Mp230 out230 in vdd vdd pch W=1u L=0.18u
Cl230 out230 0 10f
Mn231 out231 in 0 0 nch W=0.5u L=0.18u
Mp231 out231 in vdd vdd pch W=1u L=0.18u
Cl231 out231 0 10f
Mn232 out232 in 0 0 nch W=0.5u L=0.18u
Mp232 out232 in vdd vdd pch W=1u L=0.18u
Cl232 out232 0 10f
Mn233 out233 in 0 0 nch W=0.5u L=0.18u
Mp233 out233 in vdd vdd pch W=1u L=0.18u
Cl233 out233 0 10f
Mn234 out234 in 0 0 nch W=0.5u L=0.18u
Mp234 out234 in vdd vdd pch W=1u L=0.18u
Cl234 out234 0 10f
Mn235 out235 in 0 0 nch W=0.5u L=0.18u
Mp235 out235 in vdd vdd pch W=1u L=0.18u
Cl235 out235 0 10f
Mn236 out236 in 0 0 nch W=0.5u L=0.18u
Mp236 out236 in vdd vdd pch W=1u L=0.18u
Cl236 out236 0 10f
Mn237 out237 in 0 0 nch W=0.5u L=0.18u
Mp237 out237 in vdd vdd pch W=1u L=0.18u
Cl237 out237 0 10f
Mn238 out238 in 0 0 nch W=0.5u L=0.18u
Mp238 out238 in vdd vdd pch W=1u L=0.18u
Cl238 out238 0 10f
Mn239 out239 in 0 0 nch W=0.5u L=0.18u
Mp239 out239 in vdd vdd pch W=1u L=0.18u
Cl239 out239 0 10f
Mn240 out240 in 0 0 nch W=0.5u L=0.18u
Mp240 out240 in vdd vdd pch W=1u L=0.18u
Cl240 out240 0 10f
Mn241 out241 in 0 0 nch W=0.5u L=0.18u
Mp241 out241 in vdd vdd pch W=1u L=0.18u
Cl241 out241 0 10f
Mn242 out242 in 0 0 nch W=0.5u L=0.18u
Mp242 out242 in vdd vdd pch W=1u L=0.18u
Cl242 out242 0 10f
Mn243 out243 in 0 0 nch W=0.5u L=0.18u
Mp243 out243 in vdd vdd pch W=1u L=0.18u
Cl243 out243 0 10f
Mn244 out244 in 0 0 nch W=0.5u L=0.18u
Mp244 out244 in vdd vdd pch W=1u L=0.18u
Cl244 out244 0 10f
Mn245 out245 in 0 0 nch W=0.5u L=0.18u
Mp245 out245 in vdd vdd pch W=1u L=0.18u
Cl245 out245 0 10f
Mn246 out246 in 0 0 nch W=0.5u L=0.18u
Mp246 out246 in vdd vdd pch W=1u L=0.18u
Cl246 out246 0 10f
Mn247 out247 in 0 0 nch W=0.5u L=0.18u
Mp247 out247 in vdd vdd pch W=1u L=0.18u
Cl247 out247 0 10f
Mn248 out248 in 0 0 nch W=0.5u L=0.18u
Mp248 out248 in vdd vdd pch W=1u L=0.18u
Cl248 out248 0 10f
Mn249 out249 in 0 0 nch W=0.5u L=0.18u
Mp249 out249 in vdd vdd pch W=1u L=0.18u
Cl249 out249 0 10f
Mn250 out250 in 0 0 nch W=0.5u L=0.18u
Mp250 out250 in vdd vdd pch W=1u L=0.18u
Cl250 out250 0 10f
Mn251 out251 in 0 0 nch W=0.5u L=0.18u
Mp251 out251 in vdd vdd pch W=1u L=0.18u
Cl251 out251 0 10f
Mn252 out252 in 0 0 nch W=0.5u L=0.18u
Mp252 out252 in vdd vdd pch W=1u L=0.18u
Cl252 out252 0 10f
Mn253 out253 in 0 0 nch W=0.5u L=0.18u
Mp253 out253 in vdd vdd pch W=1u L=0.18u
Cl253 out253 0 10f
Mn254 out254 in 0 0 nch W=0.5u L=0.18u
Mp254 out254 in vdd vdd pch W=1u L=0.18u
Cl254 out254 0 10f
Mn255 out255 in 0 0 nch W=0.5u L=0.18u
Mp255 out255 in vdd vdd pch W=1u L=0.18u
Cl255 out255 0 10f
Mn256 out256 in 0 0 nch W=0.5u L=0.18u
Mp256 out256 in vdd vdd pch W=1u L=0.18u
Cl256 out256 0 10f
Mn257 out257 in 0 0 nch W=0.5u L=0.18u
Mp257 out257 in vdd vdd pch W=1u L=0.18u
Cl257 out257 0 10f
Mn258 out258 in 0 0 nch W=0.5u L=0.18u
Mp258 out258 in vdd vdd pch W=1u L=0.18u
Cl258 out258 0 10f
Mn259 out259 in 0 0 nch W=0.5u L=0.18u
Mp259 out259 in vdd vdd pch W=1u L=0.18u
Cl259 out259 0 10f
Mn260 out260 in 0 0 nch W=0.5u L=0.18u
Mp260 out260 in vdd vdd pch W=1u L=0.18u
Cl260 out260 0 10f
Mn261 out261 in 0 0 nch W=0.5u L=0.18u
Mp261 out261 in vdd vdd pch W=1u L=0.18u
Cl261 out261 0 10f
Mn262 out262 in 0 0 nch W=0.5u L=0.18u
Mp262 out262 in vdd vdd pch W=1u L=0.18u
Cl262 out262 0 10f
Mn263 out263 in 0 0 nch W=0.5u L=0.18u
Mp263 out263 in vdd vdd pch W=1u L=0.18u
Cl263 out263 0 10f
Mn264 out264 in 0 0 nch W=0.5u L=0.18u
Mp264 out264 in vdd vdd pch W=1u L=0.18u
Cl264 out264 0 10f
Mn265 out265 in 0 0 nch W=0.5u L=0.18u
Mp265 out265 in vdd vdd pch W=1u L=0.18u
Cl265 out265 0 10f
Mn266 out266 in 0 0 nch W=0.5u L=0.18u
Mp266 out266 in vdd vdd pch W=1u L=0.18u
Cl266 out266 0 10f
Mn267 out267 in 0 0 nch W=0.5u L=0.18u
Mp267 out267 in vdd vdd pch W=1u L=0.18u
Cl267 out267 0 10f
Mn268 out268 in 0 0 nch W=0.5u L=0.18u
Mp268 out268 in vdd vdd pch W=1u L=0.18u
Cl268 out268 0 10f
Mn269 out269 in 0 0 nch W=0.5u L=0.18u
Mp269 out269 in vdd vdd pch W=1u L=0.18u
Cl269 out269 0 10f
Mn270 out270 in 0 0 nch W=0.5u L=0.18u
Mp270 out270 in vdd vdd pch W=1u L=0.18u
Cl270 out270 0 10f
Mn271 out271 in 0 0 nch W=0.5u L=0.18u
Mp271 out271 in vdd vdd pch W=1u L=0.18u
Cl271 out271 0 10f
Mn272 out272 in 0 0 nch W=0.5u L=0.18u
Mp272 out272 in vdd vdd pch W=1u L=0.18u
Cl272 out272 0 10f
Mn273 out273 in 0 0 nch W=0.5u L=0.18u
Mp273 out273 in vdd vdd pch W=1u L=0.18u
Cl273 out273 0 10f
Mn274 out274 in 0 0 nch W=0.5u L=0.18u
Mp274 out274 in vdd vdd pch W=1u L=0.18u
Cl274 out274 0 10f
Mn275 out275 in 0 0 nch W=0.5u L=0.18u
Mp275 out275 in vdd vdd pch W=1u L=0.18u
Cl275 out275 0 10f
Mn276 out276 in 0 0 nch W=0.5u L=0.18u
Mp276 out276 in vdd vdd pch W=1u L=0.18u
Cl276 out276 0 10f
Mn277 out277 in 0 0 nch W=0.5u L=0.18u
Mp277 out277 in vdd vdd pch W=1u L=0.18u
Cl277 out277 0 10f
Mn278 out278 in 0 0 nch W=0.5u L=0.18u
Mp278 out278 in vdd vdd pch W=1u L=0.18u
Cl278 out278 0 10f
Mn279 out279 in 0 0 nch W=0.5u L=0.18u
Mp279 out279 in vdd vdd pch W=1u L=0.18u
Cl279 out279 0 10f
Mn280 out280 in 0 0 nch W=0.5u L=0.18u
Mp280 out280 in vdd vdd pch W=1u L=0.18u
Cl280 out280 0 10f
Mn281 out281 in 0 0 nch W=0.5u L=0.18u
Mp281 out281 in vdd vdd pch W=1u L=0.18u
Cl281 out281 0 10f
Mn282 out282 in 0 0 nch W=0.5u L=0.18u
Mp282 out282 in vdd vdd pch W=1u L=0.18u
Cl282 out282 0 10f
Mn283 out283 in 0 0 nch W=0.5u L=0.18u
Mp283 out283 in vdd vdd pch W=1u L=0.18u
Cl283 out283 0 10f
Mn284 out284 in 0 0 nch W=0.5u L=0.18u
Mp284 out284 in vdd vdd pch W=1u L=0.18u
Cl284 out284 0 10f
Mn285 out285 in 0 0 nch W=0.5u L=0.18u
Mp285 out285 in vdd vdd pch W=1u L=0.18u
Cl285 out285 0 10f
Mn286 out286 in 0 0 nch W=0.5u L=0.18u
Mp286 out286 in vdd vdd pch W=1u L=0.18u
Cl286 out286 0 10f
Mn287 out287 in 0 0 nch W=0.5u L=0.18u
Mp287 out287 in vdd vdd pch W=1u L=0.18u
Cl287 out287 0 10f
Mn288 out288 in 0 0 nch W=0.5u L=0.18u
Mp288 out288 in vdd vdd pch W=1u L=0.18u
Cl288 out288 0 10f
Mn289 out289 in 0 0 nch W=0.5u L=0.18u
Mp289 out289 in vdd vdd pch W=1u L=0.18u
Cl289 out289 0 10f
Mn290 out290 in 0 0 nch W=0.5u L=0.18u
Mp290 out290 in vdd vdd pch W=1u L=0.18u
Cl290 out290 0 10f
Mn291 out291 in 0 0 nch W=0.5u L=0.18u
Mp291 out291 in vdd vdd pch W=1u L=0.18u
Cl291 out291 0 10f
Mn292 out292 in 0 0 nch W=0.5u L=0.18u
Mp292 out292 in vdd vdd pch W=1u L=0.18u
Cl292 out292 0 10f
Mn293 out293 in 0 0 nch W=0.5u L=0.18u
Mp293 out293 in vdd vdd pch W=1u L=0.18u
Cl293 out293 0 10f
Mn294 out294 in 0 0 nch W=0.5u L=0.18u
Mp294 out294 in vdd vdd pch W=1u L=0.18u
Cl294 out294 0 10f
Mn295 out295 in 0 0 nch W=0.5u L=0.18u
Mp295 out295 in vdd vdd pch W=1u L=0.18u
Cl295 out295 0 10f
Mn296 out296 in 0 0 nch W=0.5u L=0.18u
Mp296 out296 in vdd vdd pch W=1u L=0.18u
Cl296 out296 0 10f
Mn297 out297 in 0 0 nch W=0.5u L=0.18u
Mp297 out297 in vdd vdd pch W=1u L=0.18u
Cl297 out297 0 10f
Mn298 out298 in 0 0 nch W=0.5u L=0.18u
Mp298 out298 in vdd vdd pch W=1u L=0.18u
Cl298 out298 0 10f
Mn299 out299 in 0 0 nch W=0.5u L=0.18u
Mp299 out299 in vdd vdd pch W=1u L=0.18u
Cl299 out299 0 10f
Mn300 out300 in 0 0 nch W=0.5u L=0.18u
Mp300 out300 in vdd vdd pch W=1u L=0.18u
Cl300 out300 0 10f
Mn301 out301 in 0 0 nch W=0.5u L=0.18u
Mp301 out301 in vdd vdd pch W=1u L=0.18u
Cl301 out301 0 10f
Mn302 out302 in 0 0 nch W=0.5u L=0.18u
Mp302 out302 in vdd vdd pch W=1u L=0.18u
Cl302 out302 0 10f
Mn303 out303 in 0 0 nch W=0.5u L=0.18u
Mp303 out303 in vdd vdd pch W=1u L=0.18u
Cl303 out303 0 10f
Mn304 out304 in 0 0 nch W=0.5u L=0.18u
Mp304 out304 in vdd vdd pch W=1u L=0.18u
Cl304 out304 0 10f
Mn305 out305 in 0 0 nch W=0.5u L=0.18u
Mp305 out305 in vdd vdd pch W=1u L=0.18u
Cl305 out305 0 10f
Mn306 out306 in 0 0 nch W=0.5u L=0.18u
Mp306 out306 in vdd vdd pch W=1u L=0.18u
Cl306 out306 0 10f
Mn307 out307 in 0 0 nch W=0.5u L=0.18u
Mp307 out307 in vdd vdd pch W=1u L=0.18u
Cl307 out307 0 10f
Mn308 out308 in 0 0 nch W=0.5u L=0.18u
Mp308 out308 in vdd vdd pch W=1u L=0.18u
Cl308 out308 0 10f
Mn309 out309 in 0 0 nch W=0.5u L=0.18u
Mp309 out309 in vdd vdd pch W=1u L=0.18u
Cl309 out309 0 10f
Mn310 out310 in 0 0 nch W=0.5u L=0.18u
Mp310 out310 in vdd vdd pch W=1u L=0.18u
Cl310 out310 0 10f
Mn311 out311 in 0 0 nch W=0.5u L=0.18u
Mp311 out311 in vdd vdd pch W=1u L=0.18u
Cl311 out311 0 10f
Mn312 out312 in 0 0 nch W=0.5u L=0.18u
Mp312 out312 in vdd vdd pch W=1u L=0.18u
Cl312 out312 0 10f
Mn313 out313 in 0 0 nch W=0.5u L=0.18u
Mp313 out313 in vdd vdd pch W=1u L=0.18u
Cl313 out313 0 10f
Mn314 out314 in 0 0 nch W=0.5u L=0.18u
Mp314 out314 in vdd vdd pch W=1u L=0.18u
Cl314 out314 0 10f
Mn315 out315 in 0 0 nch W=0.5u L=0.18u
Mp315 out315 in vdd vdd pch W=1u L=0.18u
Cl315 out315 0 10f
Mn316 out316 in 0 0 nch W=0.5u L=0.18u
Mp316 out316 in vdd vdd pch W=1u L=0.18u
Cl316 out316 0 10f
Mn317 out317 in 0 0 nch W=0.5u L=0.18u
Mp317 out317 in vdd vdd pch W=1u L=0.18u
Cl317 out317 0 10f
Mn318 out318 in 0 0 nch W=0.5u L=0.18u
Mp318 out318 in vdd vdd pch W=1u L=0.18u
Cl318 out318 0 10f
Mn319 out319 in 0 0 nch W=0.5u L=0.18u
Mp319 out319 in vdd vdd pch W=1u L=0.18u
Cl319 out319 0 10f
Mn320 out320 in 0 0 nch W=0.5u L=0.18u
Mp320 out320 in vdd vdd pch W=1u L=0.18u
Cl320 out320 0 10f
Mn321 out321 in 0 0 nch W=0.5u L=0.18u
Mp321 out321 in vdd vdd pch W=1u L=0.18u
Cl321 out321 0 10f
Mn322 out322 in 0 0 nch W=0.5u L=0.18u
Mp322 out322 in vdd vdd pch W=1u L=0.18u
Cl322 out322 0 10f
Mn323 out323 in 0 0 nch W=0.5u L=0.18u
Mp323 out323 in vdd vdd pch W=1u L=0.18u
Cl323 out323 0 10f
Mn324 out324 in 0 0 nch W=0.5u L=0.18u
Mp324 out324 in vdd vdd pch W=1u L=0.18u
Cl324 out324 0 10f
Mn325 out325 in 0 0 nch W=0.5u L=0.18u
Mp325 out325 in vdd vdd pch W=1u L=0.18u
Cl325 out325 0 10f
Mn326 out326 in 0 0 nch W=0.5u L=0.18u
Mp326 out326 in vdd vdd pch W=1u L=0.18u
Cl326 out326 0 10f
Mn327 out327 in 0 0 nch W=0.5u L=0.18u
Mp327 out327 in vdd vdd pch W=1u L=0.18u
Cl327 out327 0 10f
Mn328 out328 in 0 0 nch W=0.5u L=0.18u
Mp328 out328 in vdd vdd pch W=1u L=0.18u
Cl328 out328 0 10f
Mn329 out329 in 0 0 nch W=0.5u L=0.18u
Mp329 out329 in vdd vdd pch W=1u L=0.18u
Cl329 out329 0 10f
Mn330 out330 in 0 0 nch W=0.5u L=0.18u
Mp330 out330 in vdd vdd pch W=1u L=0.18u
Cl330 out330 0 10f
Mn331 out331 in 0 0 nch W=0.5u L=0.18u
Mp331 out331 in vdd vdd pch W=1u L=0.18u
Cl331 out331 0 10f
Mn332 out332 in 0 0 nch W=0.5u L=0.18u
Mp332 out332 in vdd vdd pch W=1u L=0.18u
Cl332 out332 0 10f
Mn333 out333 in 0 0 nch W=0.5u L=0.18u
Mp333 out333 in vdd vdd pch W=1u L=0.18u
Cl333 out333 0 10f
Mn334 out334 in 0 0 nch W=0.5u L=0.18u
Mp334 out334 in vdd vdd pch W=1u L=0.18u
Cl334 out334 0 10f
Mn335 out335 in 0 0 nch W=0.5u L=0.18u
Mp335 out335 in vdd vdd pch W=1u L=0.18u
Cl335 out335 0 10f
Mn336 out336 in 0 0 nch W=0.5u L=0.18u
Mp336 out336 in vdd vdd pch W=1u L=0.18u
Cl336 out336 0 10f
Mn337 out337 in 0 0 nch W=0.5u L=0.18u
Mp337 out337 in vdd vdd pch W=1u L=0.18u
Cl337 out337 0 10f
Mn338 out338 in 0 0 nch W=0.5u L=0.18u
Mp338 out338 in vdd vdd pch W=1u L=0.18u
Cl338 out338 0 10f
Mn339 out339 in 0 0 nch W=0.5u L=0.18u
Mp339 out339 in vdd vdd pch W=1u L=0.18u
Cl339 out339 0 10f
Mn340 out340 in 0 0 nch W=0.5u L=0.18u
Mp340 out340 in vdd vdd pch W=1u L=0.18u
Cl340 out340 0 10f
Mn341 out341 in 0 0 nch W=0.5u L=0.18u
Mp341 out341 in vdd vdd pch W=1u L=0.18u
Cl341 out341 0 10f
Mn342 out342 in 0 0 nch W=0.5u L=0.18u
Mp342 out342 in vdd vdd pch W=1u L=0.18u
Cl342 out342 0 10f
Mn343 out343 in 0 0 nch W=0.5u L=0.18u
Mp343 out343 in vdd vdd pch W=1u L=0.18u
Cl343 out343 0 10f
Mn344 out344 in 0 0 nch W=0.5u L=0.18u
Mp344 out344 in vdd vdd pch W=1u L=0.18u
Cl344 out344 0 10f
Mn345 out345 in 0 0 nch W=0.5u L=0.18u
Mp345 out345 in vdd vdd pch W=1u L=0.18u
Cl345 out345 0 10f
Mn346 out346 in 0 0 nch W=0.5u L=0.18u
Mp346 out346 in vdd vdd pch W=1u L=0.18u
Cl346 out346 0 10f
Mn347 out347 in 0 0 nch W=0.5u L=0.18u
Mp347 out347 in vdd vdd pch W=1u L=0.18u
Cl347 out347 0 10f
Mn348 out348 in 0 0 nch W=0.5u L=0.18u
Mp348 out348 in vdd vdd pch W=1u L=0.18u
Cl348 out348 0 10f
Mn349 out349 in 0 0 nch W=0.5u L=0.18u
Mp349 out349 in vdd vdd pch W=1u L=0.18u
Cl349 out349 0 10f
Mn350 out350 in 0 0 nch W=0.5u L=0.18u
Mp350 out350 in vdd vdd pch W=1u L=0.18u
Cl350 out350 0 10f
Mn351 out351 in 0 0 nch W=0.5u L=0.18u
Mp351 out351 in vdd vdd pch W=1u L=0.18u
Cl351 out351 0 10f
Mn352 out352 in 0 0 nch W=0.5u L=0.18u
Mp352 out352 in vdd vdd pch W=1u L=0.18u
Cl352 out352 0 10f
Mn353 out353 in 0 0 nch W=0.5u L=0.18u
Mp353 out353 in vdd vdd pch W=1u L=0.18u
Cl353 out353 0 10f
Mn354 out354 in 0 0 nch W=0.5u L=0.18u
Mp354 out354 in vdd vdd pch W=1u L=0.18u
Cl354 out354 0 10f
Mn355 out355 in 0 0 nch W=0.5u L=0.18u
Mp355 out355 in vdd vdd pch W=1u L=0.18u
Cl355 out355 0 10f
Mn356 out356 in 0 0 nch W=0.5u L=0.18u
Mp356 out356 in vdd vdd pch W=1u L=0.18u
Cl356 out356 0 10f
Mn357 out357 in 0 0 nch W=0.5u L=0.18u
Mp357 out357 in vdd vdd pch W=1u L=0.18u
Cl357 out357 0 10f
Mn358 out358 in 0 0 nch W=0.5u L=0.18u
Mp358 out358 in vdd vdd pch W=1u L=0.18u
Cl358 out358 0 10f
Mn359 out359 in 0 0 nch W=0.5u L=0.18u
Mp359 out359 in vdd vdd pch W=1u L=0.18u
Cl359 out359 0 10f
Mn360 out360 in 0 0 nch W=0.5u L=0.18u
Mp360 out360 in vdd vdd pch W=1u L=0.18u
Cl360 out360 0 10f
Mn361 out361 in 0 0 nch W=0.5u L=0.18u
Mp361 out361 in vdd vdd pch W=1u L=0.18u
Cl361 out361 0 10f
Mn362 out362 in 0 0 nch W=0.5u L=0.18u
Mp362 out362 in vdd vdd pch W=1u L=0.18u
Cl362 out362 0 10f
Mn363 out363 in 0 0 nch W=0.5u L=0.18u
Mp363 out363 in vdd vdd pch W=1u L=0.18u
Cl363 out363 0 10f
Mn364 out364 in 0 0 nch W=0.5u L=0.18u
Mp364 out364 in vdd vdd pch W=1u L=0.18u
Cl364 out364 0 10f
Mn365 out365 in 0 0 nch W=0.5u L=0.18u
Mp365 out365 in vdd vdd pch W=1u L=0.18u
Cl365 out365 0 10f
Mn366 out366 in 0 0 nch W=0.5u L=0.18u
Mp366 out366 in vdd vdd pch W=1u L=0.18u
Cl366 out366 0 10f
Mn367 out367 in 0 0 nch W=0.5u L=0.18u
Mp367 out367 in vdd vdd pch W=1u L=0.18u
Cl367 out367 0 10f
Mn368 out368 in 0 0 nch W=0.5u L=0.18u
Mp368 out368 in vdd vdd pch W=1u L=0.18u
Cl368 out368 0 10f
Mn369 out369 in 0 0 nch W=0.5u L=0.18u
Mp369 out369 in vdd vdd pch W=1u L=0.18u
Cl369 out369 0 10f
Mn370 out370 in 0 0 nch W=0.5u L=0.18u
Mp370 out370 in vdd vdd pch W=1u L=0.18u
Cl370 out370 0 10f
Mn371 out371 in 0 0 nch W=0.5u L=0.18u
Mp371 out371 in vdd vdd pch W=1u L=0.18u
Cl371 out371 0 10f
Mn372 out372 in 0 0 nch W=0.5u L=0.18u
Mp372 out372 in vdd vdd pch W=1u L=0.18u
Cl372 out372 0 10f
Mn373 out373 in 0 0 nch W=0.5u L=0.18u
Mp373 out373 in vdd vdd pch W=1u L=0.18u
Cl373 out373 0 10f
Mn374 out374 in 0 0 nch W=0.5u L=0.18u
Mp374 out374 in vdd vdd pch W=1u L=0.18u
Cl374 out374 0 10f
Mn375 out375 in 0 0 nch W=0.5u L=0.18u
Mp375 out375 in vdd vdd pch W=1u L=0.18u
Cl375 out375 0 10f
Mn376 out376 in 0 0 nch W=0.5u L=0.18u
Mp376 out376 in vdd vdd pch W=1u L=0.18u
Cl376 out376 0 10f
Mn377 out377 in 0 0 nch W=0.5u L=0.18u
Mp377 out377 in vdd vdd pch W=1u L=0.18u
Cl377 out377 0 10f
Mn378 out378 in 0 0 nch W=0.5u L=0.18u
Mp378 out378 in vdd vdd pch W=1u L=0.18u
Cl378 out378 0 10f
Mn379 out379 in 0 0 nch W=0.5u L=0.18u
Mp379 out379 in vdd vdd pch W=1u L=0.18u
Cl379 out379 0 10f
Mn380 out380 in 0 0 nch W=0.5u L=0.18u
Mp380 out380 in vdd vdd pch W=1u L=0.18u
Cl380 out380 0 10f
Mn381 out381 in 0 0 nch W=0.5u L=0.18u
Mp381 out381 in vdd vdd pch W=1u L=0.18u
Cl381 out381 0 10f
Mn382 out382 in 0 0 nch W=0.5u L=0.18u
Mp382 out382 in vdd vdd pch W=1u L=0.18u
Cl382 out382 0 10f
Mn383 out383 in 0 0 nch W=0.5u L=0.18u
Mp383 out383 in vdd vdd pch W=1u L=0.18u
Cl383 out383 0 10f
Mn384 out384 in 0 0 nch W=0.5u L=0.18u
Mp384 out384 in vdd vdd pch W=1u L=0.18u
Cl384 out384 0 10f
Mn385 out385 in 0 0 nch W=0.5u L=0.18u
Mp385 out385 in vdd vdd pch W=1u L=0.18u
Cl385 out385 0 10f
Mn386 out386 in 0 0 nch W=0.5u L=0.18u
Mp386 out386 in vdd vdd pch W=1u L=0.18u
Cl386 out386 0 10f
Mn387 out387 in 0 0 nch W=0.5u L=0.18u
Mp387 out387 in vdd vdd pch W=1u L=0.18u
Cl387 out387 0 10f
Mn388 out388 in 0 0 nch W=0.5u L=0.18u
Mp388 out388 in vdd vdd pch W=1u L=0.18u
Cl388 out388 0 10f
Mn389 out389 in 0 0 nch W=0.5u L=0.18u
Mp389 out389 in vdd vdd pch W=1u L=0.18u
Cl389 out389 0 10f
Mn390 out390 in 0 0 nch W=0.5u L=0.18u
Mp390 out390 in vdd vdd pch W=1u L=0.18u
Cl390 out390 0 10f
Mn391 out391 in 0 0 nch W=0.5u L=0.18u
Mp391 out391 in vdd vdd pch W=1u L=0.18u
Cl391 out391 0 10f
Mn392 out392 in 0 0 nch W=0.5u L=0.18u
Mp392 out392 in vdd vdd pch W=1u L=0.18u
Cl392 out392 0 10f
Mn393 out393 in 0 0 nch W=0.5u L=0.18u
Mp393 out393 in vdd vdd pch W=1u L=0.18u
Cl393 out393 0 10f
Mn394 out394 in 0 0 nch W=0.5u L=0.18u
Mp394 out394 in vdd vdd pch W=1u L=0.18u
Cl394 out394 0 10f
Mn395 out395 in 0 0 nch W=0.5u L=0.18u
Mp395 out395 in vdd vdd pch W=1u L=0.18u
Cl395 out395 0 10f
Mn396 out396 in 0 0 nch W=0.5u L=0.18u
Mp396 out396 in vdd vdd pch W=1u L=0.18u
Cl396 out396 0 10f
Mn397 out397 in 0 0 nch W=0.5u L=0.18u
Mp397 out397 in vdd vdd pch W=1u L=0.18u
Cl397 out397 0 10f
Mn398 out398 in 0 0 nch W=0.5u L=0.18u
Mp398 out398 in vdd vdd pch W=1u L=0.18u
Cl398 out398 0 10f
Mn399 out399 in 0 0 nch W=0.5u L=0.18u
Mp399 out399 in vdd vdd pch W=1u L=0.18u
Cl399 out399 0 10f
Mn400 out400 in 0 0 nch W=0.5u L=0.18u
Mp400 out400 in vdd vdd pch W=1u L=0.18u
Cl400 out400 0 10f
Mn401 out401 in 0 0 nch W=0.5u L=0.18u
Mp401 out401 in vdd vdd pch W=1u L=0.18u
Cl401 out401 0 10f
Mn402 out402 in 0 0 nch W=0.5u L=0.18u
Mp402 out402 in vdd vdd pch W=1u L=0.18u
Cl402 out402 0 10f
Mn403 out403 in 0 0 nch W=0.5u L=0.18u
Mp403 out403 in vdd vdd pch W=1u L=0.18u
Cl403 out403 0 10f
Mn404 out404 in 0 0 nch W=0.5u L=0.18u
Mp404 out404 in vdd vdd pch W=1u L=0.18u
Cl404 out404 0 10f
Mn405 out405 in 0 0 nch W=0.5u L=0.18u
Mp405 out405 in vdd vdd pch W=1u L=0.18u
Cl405 out405 0 10f
Mn406 out406 in 0 0 nch W=0.5u L=0.18u
Mp406 out406 in vdd vdd pch W=1u L=0.18u
Cl406 out406 0 10f
Mn407 out407 in 0 0 nch W=0.5u L=0.18u
Mp407 out407 in vdd vdd pch W=1u L=0.18u
Cl407 out407 0 10f
Mn408 out408 in 0 0 nch W=0.5u L=0.18u
Mp408 out408 in vdd vdd pch W=1u L=0.18u
Cl408 out408 0 10f
Mn409 out409 in 0 0 nch W=0.5u L=0.18u
Mp409 out409 in vdd vdd pch W=1u L=0.18u
Cl409 out409 0 10f
Mn410 out410 in 0 0 nch W=0.5u L=0.18u
Mp410 out410 in vdd vdd pch W=1u L=0.18u
Cl410 out410 0 10f
Mn411 out411 in 0 0 nch W=0.5u L=0.18u
Mp411 out411 in vdd vdd pch W=1u L=0.18u
Cl411 out411 0 10f
Mn412 out412 in 0 0 nch W=0.5u L=0.18u
Mp412 out412 in vdd vdd pch W=1u L=0.18u
Cl412 out412 0 10f
Mn413 out413 in 0 0 nch W=0.5u L=0.18u
Mp413 out413 in vdd vdd pch W=1u L=0.18u
Cl413 out413 0 10f
Mn414 out414 in 0 0 nch W=0.5u L=0.18u
Mp414 out414 in vdd vdd pch W=1u L=0.18u
Cl414 out414 0 10f
Mn415 out415 in 0 0 nch W=0.5u L=0.18u
Mp415 out415 in vdd vdd pch W=1u L=0.18u
Cl415 out415 0 10f
Mn416 out416 in 0 0 nch W=0.5u L=0.18u
Mp416 out416 in vdd vdd pch W=1u L=0.18u
Cl416 out416 0 10f
Mn417 out417 in 0 0 nch W=0.5u L=0.18u
Mp417 out417 in vdd vdd pch W=1u L=0.18u
Cl417 out417 0 10f
Mn418 out418 in 0 0 nch W=0.5u L=0.18u
Mp418 out418 in vdd vdd pch W=1u L=0.18u
Cl418 out418 0 10f
Mn419 out419 in 0 0 nch W=0.5u L=0.18u
Mp419 out419 in vdd vdd pch W=1u L=0.18u
Cl419 out419 0 10f
Mn420 out420 in 0 0 nch W=0.5u L=0.18u
Mp420 out420 in vdd vdd pch W=1u L=0.18u
Cl420 out420 0 10f
Mn421 out421 in 0 0 nch W=0.5u L=0.18u
Mp421 out421 in vdd vdd pch W=1u L=0.18u
Cl421 out421 0 10f
Mn422 out422 in 0 0 nch W=0.5u L=0.18u
Mp422 out422 in vdd vdd pch W=1u L=0.18u
Cl422 out422 0 10f
Mn423 out423 in 0 0 nch W=0.5u L=0.18u
Mp423 out423 in vdd vdd pch W=1u L=0.18u
Cl423 out423 0 10f
Mn424 out424 in 0 0 nch W=0.5u L=0.18u
Mp424 out424 in vdd vdd pch W=1u L=0.18u
Cl424 out424 0 10f
Mn425 out425 in 0 0 nch W=0.5u L=0.18u
Mp425 out425 in vdd vdd pch W=1u L=0.18u
Cl425 out425 0 10f
Mn426 out426 in 0 0 nch W=0.5u L=0.18u
Mp426 out426 in vdd vdd pch W=1u L=0.18u
Cl426 out426 0 10f
Mn427 out427 in 0 0 nch W=0.5u L=0.18u
Mp427 out427 in vdd vdd pch W=1u L=0.18u
Cl427 out427 0 10f
Mn428 out428 in 0 0 nch W=0.5u L=0.18u
Mp428 out428 in vdd vdd pch W=1u L=0.18u
Cl428 out428 0 10f
Mn429 out429 in 0 0 nch W=0.5u L=0.18u
Mp429 out429 in vdd vdd pch W=1u L=0.18u
Cl429 out429 0 10f
Mn430 out430 in 0 0 nch W=0.5u L=0.18u
Mp430 out430 in vdd vdd pch W=1u L=0.18u
Cl430 out430 0 10f
Mn431 out431 in 0 0 nch W=0.5u L=0.18u
Mp431 out431 in vdd vdd pch W=1u L=0.18u
Cl431 out431 0 10f
Mn432 out432 in 0 0 nch W=0.5u L=0.18u
Mp432 out432 in vdd vdd pch W=1u L=0.18u
Cl432 out432 0 10f
Mn433 out433 in 0 0 nch W=0.5u L=0.18u
Mp433 out433 in vdd vdd pch W=1u L=0.18u
Cl433 out433 0 10f
Mn434 out434 in 0 0 nch W=0.5u L=0.18u
Mp434 out434 in vdd vdd pch W=1u L=0.18u
Cl434 out434 0 10f
Mn435 out435 in 0 0 nch W=0.5u L=0.18u
Mp435 out435 in vdd vdd pch W=1u L=0.18u
Cl435 out435 0 10f
Mn436 out436 in 0 0 nch W=0.5u L=0.18u
Mp436 out436 in vdd vdd pch W=1u L=0.18u
Cl436 out436 0 10f
Mn437 out437 in 0 0 nch W=0.5u L=0.18u
Mp437 out437 in vdd vdd pch W=1u L=0.18u
Cl437 out437 0 10f
Mn438 out438 in 0 0 nch W=0.5u L=0.18u
Mp438 out438 in vdd vdd pch W=1u L=0.18u
Cl438 out438 0 10f
Mn439 out439 in 0 0 nch W=0.5u L=0.18u
Mp439 out439 in vdd vdd pch W=1u L=0.18u
Cl439 out439 0 10f
Mn440 out440 in 0 0 nch W=0.5u L=0.18u
Mp440 out440 in vdd vdd pch W=1u L=0.18u
Cl440 out440 0 10f
Mn441 out441 in 0 0 nch W=0.5u L=0.18u
Mp441 out441 in vdd vdd pch W=1u L=0.18u
Cl441 out441 0 10f
Mn442 out442 in 0 0 nch W=0.5u L=0.18u
Mp442 out442 in vdd vdd pch W=1u L=0.18u
Cl442 out442 0 10f
Mn443 out443 in 0 0 nch W=0.5u L=0.18u
Mp443 out443 in vdd vdd pch W=1u L=0.18u
Cl443 out443 0 10f
Mn444 out444 in 0 0 nch W=0.5u L=0.18u
Mp444 out444 in vdd vdd pch W=1u L=0.18u
Cl444 out444 0 10f
Mn445 out445 in 0 0 nch W=0.5u L=0.18u
Mp445 out445 in vdd vdd pch W=1u L=0.18u
Cl445 out445 0 10f
Mn446 out446 in 0 0 nch W=0.5u L=0.18u
Mp446 out446 in vdd vdd pch W=1u L=0.18u
Cl446 out446 0 10f
Mn447 out447 in 0 0 nch W=0.5u L=0.18u
Mp447 out447 in vdd vdd pch W=1u L=0.18u
Cl447 out447 0 10f
Mn448 out448 in 0 0 nch W=0.5u L=0.18u
Mp448 out448 in vdd vdd pch W=1u L=0.18u
Cl448 out448 0 10f
Mn449 out449 in 0 0 nch W=0.5u L=0.18u
Mp449 out449 in vdd vdd pch W=1u L=0.18u
Cl449 out449 0 10f
Mn450 out450 in 0 0 nch W=0.5u L=0.18u
Mp450 out450 in vdd vdd pch W=1u L=0.18u
Cl450 out450 0 10f
Mn451 out451 in 0 0 nch W=0.5u L=0.18u
Mp451 out451 in vdd vdd pch W=1u L=0.18u
Cl451 out451 0 10f
Mn452 out452 in 0 0 nch W=0.5u L=0.18u
Mp452 out452 in vdd vdd pch W=1u L=0.18u
Cl452 out452 0 10f
Mn453 out453 in 0 0 nch W=0.5u L=0.18u
Mp453 out453 in vdd vdd pch W=1u L=0.18u
Cl453 out453 0 10f
Mn454 out454 in 0 0 nch W=0.5u L=0.18u
Mp454 out454 in vdd vdd pch W=1u L=0.18u
Cl454 out454 0 10f
Mn455 out455 in 0 0 nch W=0.5u L=0.18u
Mp455 out455 in vdd vdd pch W=1u L=0.18u
Cl455 out455 0 10f
Mn456 out456 in 0 0 nch W=0.5u L=0.18u
Mp456 out456 in vdd vdd pch W=1u L=0.18u
Cl456 out456 0 10f
Mn457 out457 in 0 0 nch W=0.5u L=0.18u
Mp457 out457 in vdd vdd pch W=1u L=0.18u
Cl457 out457 0 10f
Mn458 out458 in 0 0 nch W=0.5u L=0.18u
Mp458 out458 in vdd vdd pch W=1u L=0.18u
Cl458 out458 0 10f
Mn459 out459 in 0 0 nch W=0.5u L=0.18u
Mp459 out459 in vdd vdd pch W=1u L=0.18u
Cl459 out459 0 10f
Mn460 out460 in 0 0 nch W=0.5u L=0.18u
Mp460 out460 in vdd vdd pch W=1u L=0.18u
Cl460 out460 0 10f
Mn461 out461 in 0 0 nch W=0.5u L=0.18u
Mp461 out461 in vdd vdd pch W=1u L=0.18u
Cl461 out461 0 10f
Mn462 out462 in 0 0 nch W=0.5u L=0.18u
Mp462 out462 in vdd vdd pch W=1u L=0.18u
Cl462 out462 0 10f
Mn463 out463 in 0 0 nch W=0.5u L=0.18u
Mp463 out463 in vdd vdd pch W=1u L=0.18u
Cl463 out463 0 10f
Mn464 out464 in 0 0 nch W=0.5u L=0.18u
Mp464 out464 in vdd vdd pch W=1u L=0.18u
Cl464 out464 0 10f
Mn465 out465 in 0 0 nch W=0.5u L=0.18u
Mp465 out465 in vdd vdd pch W=1u L=0.18u
Cl465 out465 0 10f
Mn466 out466 in 0 0 nch W=0.5u L=0.18u
Mp466 out466 in vdd vdd pch W=1u L=0.18u
Cl466 out466 0 10f
Mn467 out467 in 0 0 nch W=0.5u L=0.18u
Mp467 out467 in vdd vdd pch W=1u L=0.18u
Cl467 out467 0 10f
Mn468 out468 in 0 0 nch W=0.5u L=0.18u
Mp468 out468 in vdd vdd pch W=1u L=0.18u
Cl468 out468 0 10f
Mn469 out469 in 0 0 nch W=0.5u L=0.18u
Mp469 out469 in vdd vdd pch W=1u L=0.18u
Cl469 out469 0 10f
Mn470 out470 in 0 0 nch W=0.5u L=0.18u
Mp470 out470 in vdd vdd pch W=1u L=0.18u
Cl470 out470 0 10f
Mn471 out471 in 0 0 nch W=0.5u L=0.18u
Mp471 out471 in vdd vdd pch W=1u L=0.18u
Cl471 out471 0 10f
Mn472 out472 in 0 0 nch W=0.5u L=0.18u
Mp472 out472 in vdd vdd pch W=1u L=0.18u
Cl472 out472 0 10f
Mn473 out473 in 0 0 nch W=0.5u L=0.18u
Mp473 out473 in vdd vdd pch W=1u L=0.18u
Cl473 out473 0 10f
Mn474 out474 in 0 0 nch W=0.5u L=0.18u
Mp474 out474 in vdd vdd pch W=1u L=0.18u
Cl474 out474 0 10f
Mn475 out475 in 0 0 nch W=0.5u L=0.18u
Mp475 out475 in vdd vdd pch W=1u L=0.18u
Cl475 out475 0 10f
Mn476 out476 in 0 0 nch W=0.5u L=0.18u
Mp476 out476 in vdd vdd pch W=1u L=0.18u
Cl476 out476 0 10f
Mn477 out477 in 0 0 nch W=0.5u L=0.18u
Mp477 out477 in vdd vdd pch W=1u L=0.18u
Cl477 out477 0 10f
Mn478 out478 in 0 0 nch W=0.5u L=0.18u
Mp478 out478 in vdd vdd pch W=1u L=0.18u
Cl478 out478 0 10f
Mn479 out479 in 0 0 nch W=0.5u L=0.18u
Mp479 out479 in vdd vdd pch W=1u L=0.18u
Cl479 out479 0 10f
Mn480 out480 in 0 0 nch W=0.5u L=0.18u
Mp480 out480 in vdd vdd pch W=1u L=0.18u
Cl480 out480 0 10f
Mn481 out481 in 0 0 nch W=0.5u L=0.18u
Mp481 out481 in vdd vdd pch W=1u L=0.18u
Cl481 out481 0 10f
Mn482 out482 in 0 0 nch W=0.5u L=0.18u
Mp482 out482 in vdd vdd pch W=1u L=0.18u
Cl482 out482 0 10f
Mn483 out483 in 0 0 nch W=0.5u L=0.18u
Mp483 out483 in vdd vdd pch W=1u L=0.18u
Cl483 out483 0 10f
Mn484 out484 in 0 0 nch W=0.5u L=0.18u
Mp484 out484 in vdd vdd pch W=1u L=0.18u
Cl484 out484 0 10f
Mn485 out485 in 0 0 nch W=0.5u L=0.18u
Mp485 out485 in vdd vdd pch W=1u L=0.18u
Cl485 out485 0 10f
Mn486 out486 in 0 0 nch W=0.5u L=0.18u
Mp486 out486 in vdd vdd pch W=1u L=0.18u
Cl486 out486 0 10f
Mn487 out487 in 0 0 nch W=0.5u L=0.18u
Mp487 out487 in vdd vdd pch W=1u L=0.18u
Cl487 out487 0 10f
Mn488 out488 in 0 0 nch W=0.5u L=0.18u
Mp488 out488 in vdd vdd pch W=1u L=0.18u
Cl488 out488 0 10f
Mn489 out489 in 0 0 nch W=0.5u L=0.18u
Mp489 out489 in vdd vdd pch W=1u L=0.18u
Cl489 out489 0 10f
Mn490 out490 in 0 0 nch W=0.5u L=0.18u
Mp490 out490 in vdd vdd pch W=1u L=0.18u
Cl490 out490 0 10f
Mn491 out491 in 0 0 nch W=0.5u L=0.18u
Mp491 out491 in vdd vdd pch W=1u L=0.18u
Cl491 out491 0 10f
Mn492 out492 in 0 0 nch W=0.5u L=0.18u
Mp492 out492 in vdd vdd pch W=1u L=0.18u
Cl492 out492 0 10f
Mn493 out493 in 0 0 nch W=0.5u L=0.18u
Mp493 out493 in vdd vdd pch W=1u L=0.18u
Cl493 out493 0 10f
Mn494 out494 in 0 0 nch W=0.5u L=0.18u
Mp494 out494 in vdd vdd pch W=1u L=0.18u
Cl494 out494 0 10f
Mn495 out495 in 0 0 nch W=0.5u L=0.18u
Mp495 out495 in vdd vdd pch W=1u L=0.18u
Cl495 out495 0 10f
Mn496 out496 in 0 0 nch W=0.5u L=0.18u
Mp496 out496 in vdd vdd pch W=1u L=0.18u
Cl496 out496 0 10f
Mn497 out497 in 0 0 nch W=0.5u L=0.18u
Mp497 out497 in vdd vdd pch W=1u L=0.18u
Cl497 out497 0 10f
Mn498 out498 in 0 0 nch W=0.5u L=0.18u
Mp498 out498 in vdd vdd pch W=1u L=0.18u
Cl498 out498 0 10f
Mn499 out499 in 0 0 nch W=0.5u L=0.18u
Mp499 out499 in vdd vdd pch W=1u L=0.18u
Cl499 out499 0 10f
Mn500 out500 in 0 0 nch W=0.5u L=0.18u
Mp500 out500 in vdd vdd pch W=1u L=0.18u
Cl500 out500 0 10f
.tran 0.1n 50n
.end
