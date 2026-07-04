* Parallel CMOS inverters: 2000 instances — GPU batch stress test
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
Mn501 out501 in 0 0 nch W=0.5u L=0.18u
Mp501 out501 in vdd vdd pch W=1u L=0.18u
Cl501 out501 0 10f
Mn502 out502 in 0 0 nch W=0.5u L=0.18u
Mp502 out502 in vdd vdd pch W=1u L=0.18u
Cl502 out502 0 10f
Mn503 out503 in 0 0 nch W=0.5u L=0.18u
Mp503 out503 in vdd vdd pch W=1u L=0.18u
Cl503 out503 0 10f
Mn504 out504 in 0 0 nch W=0.5u L=0.18u
Mp504 out504 in vdd vdd pch W=1u L=0.18u
Cl504 out504 0 10f
Mn505 out505 in 0 0 nch W=0.5u L=0.18u
Mp505 out505 in vdd vdd pch W=1u L=0.18u
Cl505 out505 0 10f
Mn506 out506 in 0 0 nch W=0.5u L=0.18u
Mp506 out506 in vdd vdd pch W=1u L=0.18u
Cl506 out506 0 10f
Mn507 out507 in 0 0 nch W=0.5u L=0.18u
Mp507 out507 in vdd vdd pch W=1u L=0.18u
Cl507 out507 0 10f
Mn508 out508 in 0 0 nch W=0.5u L=0.18u
Mp508 out508 in vdd vdd pch W=1u L=0.18u
Cl508 out508 0 10f
Mn509 out509 in 0 0 nch W=0.5u L=0.18u
Mp509 out509 in vdd vdd pch W=1u L=0.18u
Cl509 out509 0 10f
Mn510 out510 in 0 0 nch W=0.5u L=0.18u
Mp510 out510 in vdd vdd pch W=1u L=0.18u
Cl510 out510 0 10f
Mn511 out511 in 0 0 nch W=0.5u L=0.18u
Mp511 out511 in vdd vdd pch W=1u L=0.18u
Cl511 out511 0 10f
Mn512 out512 in 0 0 nch W=0.5u L=0.18u
Mp512 out512 in vdd vdd pch W=1u L=0.18u
Cl512 out512 0 10f
Mn513 out513 in 0 0 nch W=0.5u L=0.18u
Mp513 out513 in vdd vdd pch W=1u L=0.18u
Cl513 out513 0 10f
Mn514 out514 in 0 0 nch W=0.5u L=0.18u
Mp514 out514 in vdd vdd pch W=1u L=0.18u
Cl514 out514 0 10f
Mn515 out515 in 0 0 nch W=0.5u L=0.18u
Mp515 out515 in vdd vdd pch W=1u L=0.18u
Cl515 out515 0 10f
Mn516 out516 in 0 0 nch W=0.5u L=0.18u
Mp516 out516 in vdd vdd pch W=1u L=0.18u
Cl516 out516 0 10f
Mn517 out517 in 0 0 nch W=0.5u L=0.18u
Mp517 out517 in vdd vdd pch W=1u L=0.18u
Cl517 out517 0 10f
Mn518 out518 in 0 0 nch W=0.5u L=0.18u
Mp518 out518 in vdd vdd pch W=1u L=0.18u
Cl518 out518 0 10f
Mn519 out519 in 0 0 nch W=0.5u L=0.18u
Mp519 out519 in vdd vdd pch W=1u L=0.18u
Cl519 out519 0 10f
Mn520 out520 in 0 0 nch W=0.5u L=0.18u
Mp520 out520 in vdd vdd pch W=1u L=0.18u
Cl520 out520 0 10f
Mn521 out521 in 0 0 nch W=0.5u L=0.18u
Mp521 out521 in vdd vdd pch W=1u L=0.18u
Cl521 out521 0 10f
Mn522 out522 in 0 0 nch W=0.5u L=0.18u
Mp522 out522 in vdd vdd pch W=1u L=0.18u
Cl522 out522 0 10f
Mn523 out523 in 0 0 nch W=0.5u L=0.18u
Mp523 out523 in vdd vdd pch W=1u L=0.18u
Cl523 out523 0 10f
Mn524 out524 in 0 0 nch W=0.5u L=0.18u
Mp524 out524 in vdd vdd pch W=1u L=0.18u
Cl524 out524 0 10f
Mn525 out525 in 0 0 nch W=0.5u L=0.18u
Mp525 out525 in vdd vdd pch W=1u L=0.18u
Cl525 out525 0 10f
Mn526 out526 in 0 0 nch W=0.5u L=0.18u
Mp526 out526 in vdd vdd pch W=1u L=0.18u
Cl526 out526 0 10f
Mn527 out527 in 0 0 nch W=0.5u L=0.18u
Mp527 out527 in vdd vdd pch W=1u L=0.18u
Cl527 out527 0 10f
Mn528 out528 in 0 0 nch W=0.5u L=0.18u
Mp528 out528 in vdd vdd pch W=1u L=0.18u
Cl528 out528 0 10f
Mn529 out529 in 0 0 nch W=0.5u L=0.18u
Mp529 out529 in vdd vdd pch W=1u L=0.18u
Cl529 out529 0 10f
Mn530 out530 in 0 0 nch W=0.5u L=0.18u
Mp530 out530 in vdd vdd pch W=1u L=0.18u
Cl530 out530 0 10f
Mn531 out531 in 0 0 nch W=0.5u L=0.18u
Mp531 out531 in vdd vdd pch W=1u L=0.18u
Cl531 out531 0 10f
Mn532 out532 in 0 0 nch W=0.5u L=0.18u
Mp532 out532 in vdd vdd pch W=1u L=0.18u
Cl532 out532 0 10f
Mn533 out533 in 0 0 nch W=0.5u L=0.18u
Mp533 out533 in vdd vdd pch W=1u L=0.18u
Cl533 out533 0 10f
Mn534 out534 in 0 0 nch W=0.5u L=0.18u
Mp534 out534 in vdd vdd pch W=1u L=0.18u
Cl534 out534 0 10f
Mn535 out535 in 0 0 nch W=0.5u L=0.18u
Mp535 out535 in vdd vdd pch W=1u L=0.18u
Cl535 out535 0 10f
Mn536 out536 in 0 0 nch W=0.5u L=0.18u
Mp536 out536 in vdd vdd pch W=1u L=0.18u
Cl536 out536 0 10f
Mn537 out537 in 0 0 nch W=0.5u L=0.18u
Mp537 out537 in vdd vdd pch W=1u L=0.18u
Cl537 out537 0 10f
Mn538 out538 in 0 0 nch W=0.5u L=0.18u
Mp538 out538 in vdd vdd pch W=1u L=0.18u
Cl538 out538 0 10f
Mn539 out539 in 0 0 nch W=0.5u L=0.18u
Mp539 out539 in vdd vdd pch W=1u L=0.18u
Cl539 out539 0 10f
Mn540 out540 in 0 0 nch W=0.5u L=0.18u
Mp540 out540 in vdd vdd pch W=1u L=0.18u
Cl540 out540 0 10f
Mn541 out541 in 0 0 nch W=0.5u L=0.18u
Mp541 out541 in vdd vdd pch W=1u L=0.18u
Cl541 out541 0 10f
Mn542 out542 in 0 0 nch W=0.5u L=0.18u
Mp542 out542 in vdd vdd pch W=1u L=0.18u
Cl542 out542 0 10f
Mn543 out543 in 0 0 nch W=0.5u L=0.18u
Mp543 out543 in vdd vdd pch W=1u L=0.18u
Cl543 out543 0 10f
Mn544 out544 in 0 0 nch W=0.5u L=0.18u
Mp544 out544 in vdd vdd pch W=1u L=0.18u
Cl544 out544 0 10f
Mn545 out545 in 0 0 nch W=0.5u L=0.18u
Mp545 out545 in vdd vdd pch W=1u L=0.18u
Cl545 out545 0 10f
Mn546 out546 in 0 0 nch W=0.5u L=0.18u
Mp546 out546 in vdd vdd pch W=1u L=0.18u
Cl546 out546 0 10f
Mn547 out547 in 0 0 nch W=0.5u L=0.18u
Mp547 out547 in vdd vdd pch W=1u L=0.18u
Cl547 out547 0 10f
Mn548 out548 in 0 0 nch W=0.5u L=0.18u
Mp548 out548 in vdd vdd pch W=1u L=0.18u
Cl548 out548 0 10f
Mn549 out549 in 0 0 nch W=0.5u L=0.18u
Mp549 out549 in vdd vdd pch W=1u L=0.18u
Cl549 out549 0 10f
Mn550 out550 in 0 0 nch W=0.5u L=0.18u
Mp550 out550 in vdd vdd pch W=1u L=0.18u
Cl550 out550 0 10f
Mn551 out551 in 0 0 nch W=0.5u L=0.18u
Mp551 out551 in vdd vdd pch W=1u L=0.18u
Cl551 out551 0 10f
Mn552 out552 in 0 0 nch W=0.5u L=0.18u
Mp552 out552 in vdd vdd pch W=1u L=0.18u
Cl552 out552 0 10f
Mn553 out553 in 0 0 nch W=0.5u L=0.18u
Mp553 out553 in vdd vdd pch W=1u L=0.18u
Cl553 out553 0 10f
Mn554 out554 in 0 0 nch W=0.5u L=0.18u
Mp554 out554 in vdd vdd pch W=1u L=0.18u
Cl554 out554 0 10f
Mn555 out555 in 0 0 nch W=0.5u L=0.18u
Mp555 out555 in vdd vdd pch W=1u L=0.18u
Cl555 out555 0 10f
Mn556 out556 in 0 0 nch W=0.5u L=0.18u
Mp556 out556 in vdd vdd pch W=1u L=0.18u
Cl556 out556 0 10f
Mn557 out557 in 0 0 nch W=0.5u L=0.18u
Mp557 out557 in vdd vdd pch W=1u L=0.18u
Cl557 out557 0 10f
Mn558 out558 in 0 0 nch W=0.5u L=0.18u
Mp558 out558 in vdd vdd pch W=1u L=0.18u
Cl558 out558 0 10f
Mn559 out559 in 0 0 nch W=0.5u L=0.18u
Mp559 out559 in vdd vdd pch W=1u L=0.18u
Cl559 out559 0 10f
Mn560 out560 in 0 0 nch W=0.5u L=0.18u
Mp560 out560 in vdd vdd pch W=1u L=0.18u
Cl560 out560 0 10f
Mn561 out561 in 0 0 nch W=0.5u L=0.18u
Mp561 out561 in vdd vdd pch W=1u L=0.18u
Cl561 out561 0 10f
Mn562 out562 in 0 0 nch W=0.5u L=0.18u
Mp562 out562 in vdd vdd pch W=1u L=0.18u
Cl562 out562 0 10f
Mn563 out563 in 0 0 nch W=0.5u L=0.18u
Mp563 out563 in vdd vdd pch W=1u L=0.18u
Cl563 out563 0 10f
Mn564 out564 in 0 0 nch W=0.5u L=0.18u
Mp564 out564 in vdd vdd pch W=1u L=0.18u
Cl564 out564 0 10f
Mn565 out565 in 0 0 nch W=0.5u L=0.18u
Mp565 out565 in vdd vdd pch W=1u L=0.18u
Cl565 out565 0 10f
Mn566 out566 in 0 0 nch W=0.5u L=0.18u
Mp566 out566 in vdd vdd pch W=1u L=0.18u
Cl566 out566 0 10f
Mn567 out567 in 0 0 nch W=0.5u L=0.18u
Mp567 out567 in vdd vdd pch W=1u L=0.18u
Cl567 out567 0 10f
Mn568 out568 in 0 0 nch W=0.5u L=0.18u
Mp568 out568 in vdd vdd pch W=1u L=0.18u
Cl568 out568 0 10f
Mn569 out569 in 0 0 nch W=0.5u L=0.18u
Mp569 out569 in vdd vdd pch W=1u L=0.18u
Cl569 out569 0 10f
Mn570 out570 in 0 0 nch W=0.5u L=0.18u
Mp570 out570 in vdd vdd pch W=1u L=0.18u
Cl570 out570 0 10f
Mn571 out571 in 0 0 nch W=0.5u L=0.18u
Mp571 out571 in vdd vdd pch W=1u L=0.18u
Cl571 out571 0 10f
Mn572 out572 in 0 0 nch W=0.5u L=0.18u
Mp572 out572 in vdd vdd pch W=1u L=0.18u
Cl572 out572 0 10f
Mn573 out573 in 0 0 nch W=0.5u L=0.18u
Mp573 out573 in vdd vdd pch W=1u L=0.18u
Cl573 out573 0 10f
Mn574 out574 in 0 0 nch W=0.5u L=0.18u
Mp574 out574 in vdd vdd pch W=1u L=0.18u
Cl574 out574 0 10f
Mn575 out575 in 0 0 nch W=0.5u L=0.18u
Mp575 out575 in vdd vdd pch W=1u L=0.18u
Cl575 out575 0 10f
Mn576 out576 in 0 0 nch W=0.5u L=0.18u
Mp576 out576 in vdd vdd pch W=1u L=0.18u
Cl576 out576 0 10f
Mn577 out577 in 0 0 nch W=0.5u L=0.18u
Mp577 out577 in vdd vdd pch W=1u L=0.18u
Cl577 out577 0 10f
Mn578 out578 in 0 0 nch W=0.5u L=0.18u
Mp578 out578 in vdd vdd pch W=1u L=0.18u
Cl578 out578 0 10f
Mn579 out579 in 0 0 nch W=0.5u L=0.18u
Mp579 out579 in vdd vdd pch W=1u L=0.18u
Cl579 out579 0 10f
Mn580 out580 in 0 0 nch W=0.5u L=0.18u
Mp580 out580 in vdd vdd pch W=1u L=0.18u
Cl580 out580 0 10f
Mn581 out581 in 0 0 nch W=0.5u L=0.18u
Mp581 out581 in vdd vdd pch W=1u L=0.18u
Cl581 out581 0 10f
Mn582 out582 in 0 0 nch W=0.5u L=0.18u
Mp582 out582 in vdd vdd pch W=1u L=0.18u
Cl582 out582 0 10f
Mn583 out583 in 0 0 nch W=0.5u L=0.18u
Mp583 out583 in vdd vdd pch W=1u L=0.18u
Cl583 out583 0 10f
Mn584 out584 in 0 0 nch W=0.5u L=0.18u
Mp584 out584 in vdd vdd pch W=1u L=0.18u
Cl584 out584 0 10f
Mn585 out585 in 0 0 nch W=0.5u L=0.18u
Mp585 out585 in vdd vdd pch W=1u L=0.18u
Cl585 out585 0 10f
Mn586 out586 in 0 0 nch W=0.5u L=0.18u
Mp586 out586 in vdd vdd pch W=1u L=0.18u
Cl586 out586 0 10f
Mn587 out587 in 0 0 nch W=0.5u L=0.18u
Mp587 out587 in vdd vdd pch W=1u L=0.18u
Cl587 out587 0 10f
Mn588 out588 in 0 0 nch W=0.5u L=0.18u
Mp588 out588 in vdd vdd pch W=1u L=0.18u
Cl588 out588 0 10f
Mn589 out589 in 0 0 nch W=0.5u L=0.18u
Mp589 out589 in vdd vdd pch W=1u L=0.18u
Cl589 out589 0 10f
Mn590 out590 in 0 0 nch W=0.5u L=0.18u
Mp590 out590 in vdd vdd pch W=1u L=0.18u
Cl590 out590 0 10f
Mn591 out591 in 0 0 nch W=0.5u L=0.18u
Mp591 out591 in vdd vdd pch W=1u L=0.18u
Cl591 out591 0 10f
Mn592 out592 in 0 0 nch W=0.5u L=0.18u
Mp592 out592 in vdd vdd pch W=1u L=0.18u
Cl592 out592 0 10f
Mn593 out593 in 0 0 nch W=0.5u L=0.18u
Mp593 out593 in vdd vdd pch W=1u L=0.18u
Cl593 out593 0 10f
Mn594 out594 in 0 0 nch W=0.5u L=0.18u
Mp594 out594 in vdd vdd pch W=1u L=0.18u
Cl594 out594 0 10f
Mn595 out595 in 0 0 nch W=0.5u L=0.18u
Mp595 out595 in vdd vdd pch W=1u L=0.18u
Cl595 out595 0 10f
Mn596 out596 in 0 0 nch W=0.5u L=0.18u
Mp596 out596 in vdd vdd pch W=1u L=0.18u
Cl596 out596 0 10f
Mn597 out597 in 0 0 nch W=0.5u L=0.18u
Mp597 out597 in vdd vdd pch W=1u L=0.18u
Cl597 out597 0 10f
Mn598 out598 in 0 0 nch W=0.5u L=0.18u
Mp598 out598 in vdd vdd pch W=1u L=0.18u
Cl598 out598 0 10f
Mn599 out599 in 0 0 nch W=0.5u L=0.18u
Mp599 out599 in vdd vdd pch W=1u L=0.18u
Cl599 out599 0 10f
Mn600 out600 in 0 0 nch W=0.5u L=0.18u
Mp600 out600 in vdd vdd pch W=1u L=0.18u
Cl600 out600 0 10f
Mn601 out601 in 0 0 nch W=0.5u L=0.18u
Mp601 out601 in vdd vdd pch W=1u L=0.18u
Cl601 out601 0 10f
Mn602 out602 in 0 0 nch W=0.5u L=0.18u
Mp602 out602 in vdd vdd pch W=1u L=0.18u
Cl602 out602 0 10f
Mn603 out603 in 0 0 nch W=0.5u L=0.18u
Mp603 out603 in vdd vdd pch W=1u L=0.18u
Cl603 out603 0 10f
Mn604 out604 in 0 0 nch W=0.5u L=0.18u
Mp604 out604 in vdd vdd pch W=1u L=0.18u
Cl604 out604 0 10f
Mn605 out605 in 0 0 nch W=0.5u L=0.18u
Mp605 out605 in vdd vdd pch W=1u L=0.18u
Cl605 out605 0 10f
Mn606 out606 in 0 0 nch W=0.5u L=0.18u
Mp606 out606 in vdd vdd pch W=1u L=0.18u
Cl606 out606 0 10f
Mn607 out607 in 0 0 nch W=0.5u L=0.18u
Mp607 out607 in vdd vdd pch W=1u L=0.18u
Cl607 out607 0 10f
Mn608 out608 in 0 0 nch W=0.5u L=0.18u
Mp608 out608 in vdd vdd pch W=1u L=0.18u
Cl608 out608 0 10f
Mn609 out609 in 0 0 nch W=0.5u L=0.18u
Mp609 out609 in vdd vdd pch W=1u L=0.18u
Cl609 out609 0 10f
Mn610 out610 in 0 0 nch W=0.5u L=0.18u
Mp610 out610 in vdd vdd pch W=1u L=0.18u
Cl610 out610 0 10f
Mn611 out611 in 0 0 nch W=0.5u L=0.18u
Mp611 out611 in vdd vdd pch W=1u L=0.18u
Cl611 out611 0 10f
Mn612 out612 in 0 0 nch W=0.5u L=0.18u
Mp612 out612 in vdd vdd pch W=1u L=0.18u
Cl612 out612 0 10f
Mn613 out613 in 0 0 nch W=0.5u L=0.18u
Mp613 out613 in vdd vdd pch W=1u L=0.18u
Cl613 out613 0 10f
Mn614 out614 in 0 0 nch W=0.5u L=0.18u
Mp614 out614 in vdd vdd pch W=1u L=0.18u
Cl614 out614 0 10f
Mn615 out615 in 0 0 nch W=0.5u L=0.18u
Mp615 out615 in vdd vdd pch W=1u L=0.18u
Cl615 out615 0 10f
Mn616 out616 in 0 0 nch W=0.5u L=0.18u
Mp616 out616 in vdd vdd pch W=1u L=0.18u
Cl616 out616 0 10f
Mn617 out617 in 0 0 nch W=0.5u L=0.18u
Mp617 out617 in vdd vdd pch W=1u L=0.18u
Cl617 out617 0 10f
Mn618 out618 in 0 0 nch W=0.5u L=0.18u
Mp618 out618 in vdd vdd pch W=1u L=0.18u
Cl618 out618 0 10f
Mn619 out619 in 0 0 nch W=0.5u L=0.18u
Mp619 out619 in vdd vdd pch W=1u L=0.18u
Cl619 out619 0 10f
Mn620 out620 in 0 0 nch W=0.5u L=0.18u
Mp620 out620 in vdd vdd pch W=1u L=0.18u
Cl620 out620 0 10f
Mn621 out621 in 0 0 nch W=0.5u L=0.18u
Mp621 out621 in vdd vdd pch W=1u L=0.18u
Cl621 out621 0 10f
Mn622 out622 in 0 0 nch W=0.5u L=0.18u
Mp622 out622 in vdd vdd pch W=1u L=0.18u
Cl622 out622 0 10f
Mn623 out623 in 0 0 nch W=0.5u L=0.18u
Mp623 out623 in vdd vdd pch W=1u L=0.18u
Cl623 out623 0 10f
Mn624 out624 in 0 0 nch W=0.5u L=0.18u
Mp624 out624 in vdd vdd pch W=1u L=0.18u
Cl624 out624 0 10f
Mn625 out625 in 0 0 nch W=0.5u L=0.18u
Mp625 out625 in vdd vdd pch W=1u L=0.18u
Cl625 out625 0 10f
Mn626 out626 in 0 0 nch W=0.5u L=0.18u
Mp626 out626 in vdd vdd pch W=1u L=0.18u
Cl626 out626 0 10f
Mn627 out627 in 0 0 nch W=0.5u L=0.18u
Mp627 out627 in vdd vdd pch W=1u L=0.18u
Cl627 out627 0 10f
Mn628 out628 in 0 0 nch W=0.5u L=0.18u
Mp628 out628 in vdd vdd pch W=1u L=0.18u
Cl628 out628 0 10f
Mn629 out629 in 0 0 nch W=0.5u L=0.18u
Mp629 out629 in vdd vdd pch W=1u L=0.18u
Cl629 out629 0 10f
Mn630 out630 in 0 0 nch W=0.5u L=0.18u
Mp630 out630 in vdd vdd pch W=1u L=0.18u
Cl630 out630 0 10f
Mn631 out631 in 0 0 nch W=0.5u L=0.18u
Mp631 out631 in vdd vdd pch W=1u L=0.18u
Cl631 out631 0 10f
Mn632 out632 in 0 0 nch W=0.5u L=0.18u
Mp632 out632 in vdd vdd pch W=1u L=0.18u
Cl632 out632 0 10f
Mn633 out633 in 0 0 nch W=0.5u L=0.18u
Mp633 out633 in vdd vdd pch W=1u L=0.18u
Cl633 out633 0 10f
Mn634 out634 in 0 0 nch W=0.5u L=0.18u
Mp634 out634 in vdd vdd pch W=1u L=0.18u
Cl634 out634 0 10f
Mn635 out635 in 0 0 nch W=0.5u L=0.18u
Mp635 out635 in vdd vdd pch W=1u L=0.18u
Cl635 out635 0 10f
Mn636 out636 in 0 0 nch W=0.5u L=0.18u
Mp636 out636 in vdd vdd pch W=1u L=0.18u
Cl636 out636 0 10f
Mn637 out637 in 0 0 nch W=0.5u L=0.18u
Mp637 out637 in vdd vdd pch W=1u L=0.18u
Cl637 out637 0 10f
Mn638 out638 in 0 0 nch W=0.5u L=0.18u
Mp638 out638 in vdd vdd pch W=1u L=0.18u
Cl638 out638 0 10f
Mn639 out639 in 0 0 nch W=0.5u L=0.18u
Mp639 out639 in vdd vdd pch W=1u L=0.18u
Cl639 out639 0 10f
Mn640 out640 in 0 0 nch W=0.5u L=0.18u
Mp640 out640 in vdd vdd pch W=1u L=0.18u
Cl640 out640 0 10f
Mn641 out641 in 0 0 nch W=0.5u L=0.18u
Mp641 out641 in vdd vdd pch W=1u L=0.18u
Cl641 out641 0 10f
Mn642 out642 in 0 0 nch W=0.5u L=0.18u
Mp642 out642 in vdd vdd pch W=1u L=0.18u
Cl642 out642 0 10f
Mn643 out643 in 0 0 nch W=0.5u L=0.18u
Mp643 out643 in vdd vdd pch W=1u L=0.18u
Cl643 out643 0 10f
Mn644 out644 in 0 0 nch W=0.5u L=0.18u
Mp644 out644 in vdd vdd pch W=1u L=0.18u
Cl644 out644 0 10f
Mn645 out645 in 0 0 nch W=0.5u L=0.18u
Mp645 out645 in vdd vdd pch W=1u L=0.18u
Cl645 out645 0 10f
Mn646 out646 in 0 0 nch W=0.5u L=0.18u
Mp646 out646 in vdd vdd pch W=1u L=0.18u
Cl646 out646 0 10f
Mn647 out647 in 0 0 nch W=0.5u L=0.18u
Mp647 out647 in vdd vdd pch W=1u L=0.18u
Cl647 out647 0 10f
Mn648 out648 in 0 0 nch W=0.5u L=0.18u
Mp648 out648 in vdd vdd pch W=1u L=0.18u
Cl648 out648 0 10f
Mn649 out649 in 0 0 nch W=0.5u L=0.18u
Mp649 out649 in vdd vdd pch W=1u L=0.18u
Cl649 out649 0 10f
Mn650 out650 in 0 0 nch W=0.5u L=0.18u
Mp650 out650 in vdd vdd pch W=1u L=0.18u
Cl650 out650 0 10f
Mn651 out651 in 0 0 nch W=0.5u L=0.18u
Mp651 out651 in vdd vdd pch W=1u L=0.18u
Cl651 out651 0 10f
Mn652 out652 in 0 0 nch W=0.5u L=0.18u
Mp652 out652 in vdd vdd pch W=1u L=0.18u
Cl652 out652 0 10f
Mn653 out653 in 0 0 nch W=0.5u L=0.18u
Mp653 out653 in vdd vdd pch W=1u L=0.18u
Cl653 out653 0 10f
Mn654 out654 in 0 0 nch W=0.5u L=0.18u
Mp654 out654 in vdd vdd pch W=1u L=0.18u
Cl654 out654 0 10f
Mn655 out655 in 0 0 nch W=0.5u L=0.18u
Mp655 out655 in vdd vdd pch W=1u L=0.18u
Cl655 out655 0 10f
Mn656 out656 in 0 0 nch W=0.5u L=0.18u
Mp656 out656 in vdd vdd pch W=1u L=0.18u
Cl656 out656 0 10f
Mn657 out657 in 0 0 nch W=0.5u L=0.18u
Mp657 out657 in vdd vdd pch W=1u L=0.18u
Cl657 out657 0 10f
Mn658 out658 in 0 0 nch W=0.5u L=0.18u
Mp658 out658 in vdd vdd pch W=1u L=0.18u
Cl658 out658 0 10f
Mn659 out659 in 0 0 nch W=0.5u L=0.18u
Mp659 out659 in vdd vdd pch W=1u L=0.18u
Cl659 out659 0 10f
Mn660 out660 in 0 0 nch W=0.5u L=0.18u
Mp660 out660 in vdd vdd pch W=1u L=0.18u
Cl660 out660 0 10f
Mn661 out661 in 0 0 nch W=0.5u L=0.18u
Mp661 out661 in vdd vdd pch W=1u L=0.18u
Cl661 out661 0 10f
Mn662 out662 in 0 0 nch W=0.5u L=0.18u
Mp662 out662 in vdd vdd pch W=1u L=0.18u
Cl662 out662 0 10f
Mn663 out663 in 0 0 nch W=0.5u L=0.18u
Mp663 out663 in vdd vdd pch W=1u L=0.18u
Cl663 out663 0 10f
Mn664 out664 in 0 0 nch W=0.5u L=0.18u
Mp664 out664 in vdd vdd pch W=1u L=0.18u
Cl664 out664 0 10f
Mn665 out665 in 0 0 nch W=0.5u L=0.18u
Mp665 out665 in vdd vdd pch W=1u L=0.18u
Cl665 out665 0 10f
Mn666 out666 in 0 0 nch W=0.5u L=0.18u
Mp666 out666 in vdd vdd pch W=1u L=0.18u
Cl666 out666 0 10f
Mn667 out667 in 0 0 nch W=0.5u L=0.18u
Mp667 out667 in vdd vdd pch W=1u L=0.18u
Cl667 out667 0 10f
Mn668 out668 in 0 0 nch W=0.5u L=0.18u
Mp668 out668 in vdd vdd pch W=1u L=0.18u
Cl668 out668 0 10f
Mn669 out669 in 0 0 nch W=0.5u L=0.18u
Mp669 out669 in vdd vdd pch W=1u L=0.18u
Cl669 out669 0 10f
Mn670 out670 in 0 0 nch W=0.5u L=0.18u
Mp670 out670 in vdd vdd pch W=1u L=0.18u
Cl670 out670 0 10f
Mn671 out671 in 0 0 nch W=0.5u L=0.18u
Mp671 out671 in vdd vdd pch W=1u L=0.18u
Cl671 out671 0 10f
Mn672 out672 in 0 0 nch W=0.5u L=0.18u
Mp672 out672 in vdd vdd pch W=1u L=0.18u
Cl672 out672 0 10f
Mn673 out673 in 0 0 nch W=0.5u L=0.18u
Mp673 out673 in vdd vdd pch W=1u L=0.18u
Cl673 out673 0 10f
Mn674 out674 in 0 0 nch W=0.5u L=0.18u
Mp674 out674 in vdd vdd pch W=1u L=0.18u
Cl674 out674 0 10f
Mn675 out675 in 0 0 nch W=0.5u L=0.18u
Mp675 out675 in vdd vdd pch W=1u L=0.18u
Cl675 out675 0 10f
Mn676 out676 in 0 0 nch W=0.5u L=0.18u
Mp676 out676 in vdd vdd pch W=1u L=0.18u
Cl676 out676 0 10f
Mn677 out677 in 0 0 nch W=0.5u L=0.18u
Mp677 out677 in vdd vdd pch W=1u L=0.18u
Cl677 out677 0 10f
Mn678 out678 in 0 0 nch W=0.5u L=0.18u
Mp678 out678 in vdd vdd pch W=1u L=0.18u
Cl678 out678 0 10f
Mn679 out679 in 0 0 nch W=0.5u L=0.18u
Mp679 out679 in vdd vdd pch W=1u L=0.18u
Cl679 out679 0 10f
Mn680 out680 in 0 0 nch W=0.5u L=0.18u
Mp680 out680 in vdd vdd pch W=1u L=0.18u
Cl680 out680 0 10f
Mn681 out681 in 0 0 nch W=0.5u L=0.18u
Mp681 out681 in vdd vdd pch W=1u L=0.18u
Cl681 out681 0 10f
Mn682 out682 in 0 0 nch W=0.5u L=0.18u
Mp682 out682 in vdd vdd pch W=1u L=0.18u
Cl682 out682 0 10f
Mn683 out683 in 0 0 nch W=0.5u L=0.18u
Mp683 out683 in vdd vdd pch W=1u L=0.18u
Cl683 out683 0 10f
Mn684 out684 in 0 0 nch W=0.5u L=0.18u
Mp684 out684 in vdd vdd pch W=1u L=0.18u
Cl684 out684 0 10f
Mn685 out685 in 0 0 nch W=0.5u L=0.18u
Mp685 out685 in vdd vdd pch W=1u L=0.18u
Cl685 out685 0 10f
Mn686 out686 in 0 0 nch W=0.5u L=0.18u
Mp686 out686 in vdd vdd pch W=1u L=0.18u
Cl686 out686 0 10f
Mn687 out687 in 0 0 nch W=0.5u L=0.18u
Mp687 out687 in vdd vdd pch W=1u L=0.18u
Cl687 out687 0 10f
Mn688 out688 in 0 0 nch W=0.5u L=0.18u
Mp688 out688 in vdd vdd pch W=1u L=0.18u
Cl688 out688 0 10f
Mn689 out689 in 0 0 nch W=0.5u L=0.18u
Mp689 out689 in vdd vdd pch W=1u L=0.18u
Cl689 out689 0 10f
Mn690 out690 in 0 0 nch W=0.5u L=0.18u
Mp690 out690 in vdd vdd pch W=1u L=0.18u
Cl690 out690 0 10f
Mn691 out691 in 0 0 nch W=0.5u L=0.18u
Mp691 out691 in vdd vdd pch W=1u L=0.18u
Cl691 out691 0 10f
Mn692 out692 in 0 0 nch W=0.5u L=0.18u
Mp692 out692 in vdd vdd pch W=1u L=0.18u
Cl692 out692 0 10f
Mn693 out693 in 0 0 nch W=0.5u L=0.18u
Mp693 out693 in vdd vdd pch W=1u L=0.18u
Cl693 out693 0 10f
Mn694 out694 in 0 0 nch W=0.5u L=0.18u
Mp694 out694 in vdd vdd pch W=1u L=0.18u
Cl694 out694 0 10f
Mn695 out695 in 0 0 nch W=0.5u L=0.18u
Mp695 out695 in vdd vdd pch W=1u L=0.18u
Cl695 out695 0 10f
Mn696 out696 in 0 0 nch W=0.5u L=0.18u
Mp696 out696 in vdd vdd pch W=1u L=0.18u
Cl696 out696 0 10f
Mn697 out697 in 0 0 nch W=0.5u L=0.18u
Mp697 out697 in vdd vdd pch W=1u L=0.18u
Cl697 out697 0 10f
Mn698 out698 in 0 0 nch W=0.5u L=0.18u
Mp698 out698 in vdd vdd pch W=1u L=0.18u
Cl698 out698 0 10f
Mn699 out699 in 0 0 nch W=0.5u L=0.18u
Mp699 out699 in vdd vdd pch W=1u L=0.18u
Cl699 out699 0 10f
Mn700 out700 in 0 0 nch W=0.5u L=0.18u
Mp700 out700 in vdd vdd pch W=1u L=0.18u
Cl700 out700 0 10f
Mn701 out701 in 0 0 nch W=0.5u L=0.18u
Mp701 out701 in vdd vdd pch W=1u L=0.18u
Cl701 out701 0 10f
Mn702 out702 in 0 0 nch W=0.5u L=0.18u
Mp702 out702 in vdd vdd pch W=1u L=0.18u
Cl702 out702 0 10f
Mn703 out703 in 0 0 nch W=0.5u L=0.18u
Mp703 out703 in vdd vdd pch W=1u L=0.18u
Cl703 out703 0 10f
Mn704 out704 in 0 0 nch W=0.5u L=0.18u
Mp704 out704 in vdd vdd pch W=1u L=0.18u
Cl704 out704 0 10f
Mn705 out705 in 0 0 nch W=0.5u L=0.18u
Mp705 out705 in vdd vdd pch W=1u L=0.18u
Cl705 out705 0 10f
Mn706 out706 in 0 0 nch W=0.5u L=0.18u
Mp706 out706 in vdd vdd pch W=1u L=0.18u
Cl706 out706 0 10f
Mn707 out707 in 0 0 nch W=0.5u L=0.18u
Mp707 out707 in vdd vdd pch W=1u L=0.18u
Cl707 out707 0 10f
Mn708 out708 in 0 0 nch W=0.5u L=0.18u
Mp708 out708 in vdd vdd pch W=1u L=0.18u
Cl708 out708 0 10f
Mn709 out709 in 0 0 nch W=0.5u L=0.18u
Mp709 out709 in vdd vdd pch W=1u L=0.18u
Cl709 out709 0 10f
Mn710 out710 in 0 0 nch W=0.5u L=0.18u
Mp710 out710 in vdd vdd pch W=1u L=0.18u
Cl710 out710 0 10f
Mn711 out711 in 0 0 nch W=0.5u L=0.18u
Mp711 out711 in vdd vdd pch W=1u L=0.18u
Cl711 out711 0 10f
Mn712 out712 in 0 0 nch W=0.5u L=0.18u
Mp712 out712 in vdd vdd pch W=1u L=0.18u
Cl712 out712 0 10f
Mn713 out713 in 0 0 nch W=0.5u L=0.18u
Mp713 out713 in vdd vdd pch W=1u L=0.18u
Cl713 out713 0 10f
Mn714 out714 in 0 0 nch W=0.5u L=0.18u
Mp714 out714 in vdd vdd pch W=1u L=0.18u
Cl714 out714 0 10f
Mn715 out715 in 0 0 nch W=0.5u L=0.18u
Mp715 out715 in vdd vdd pch W=1u L=0.18u
Cl715 out715 0 10f
Mn716 out716 in 0 0 nch W=0.5u L=0.18u
Mp716 out716 in vdd vdd pch W=1u L=0.18u
Cl716 out716 0 10f
Mn717 out717 in 0 0 nch W=0.5u L=0.18u
Mp717 out717 in vdd vdd pch W=1u L=0.18u
Cl717 out717 0 10f
Mn718 out718 in 0 0 nch W=0.5u L=0.18u
Mp718 out718 in vdd vdd pch W=1u L=0.18u
Cl718 out718 0 10f
Mn719 out719 in 0 0 nch W=0.5u L=0.18u
Mp719 out719 in vdd vdd pch W=1u L=0.18u
Cl719 out719 0 10f
Mn720 out720 in 0 0 nch W=0.5u L=0.18u
Mp720 out720 in vdd vdd pch W=1u L=0.18u
Cl720 out720 0 10f
Mn721 out721 in 0 0 nch W=0.5u L=0.18u
Mp721 out721 in vdd vdd pch W=1u L=0.18u
Cl721 out721 0 10f
Mn722 out722 in 0 0 nch W=0.5u L=0.18u
Mp722 out722 in vdd vdd pch W=1u L=0.18u
Cl722 out722 0 10f
Mn723 out723 in 0 0 nch W=0.5u L=0.18u
Mp723 out723 in vdd vdd pch W=1u L=0.18u
Cl723 out723 0 10f
Mn724 out724 in 0 0 nch W=0.5u L=0.18u
Mp724 out724 in vdd vdd pch W=1u L=0.18u
Cl724 out724 0 10f
Mn725 out725 in 0 0 nch W=0.5u L=0.18u
Mp725 out725 in vdd vdd pch W=1u L=0.18u
Cl725 out725 0 10f
Mn726 out726 in 0 0 nch W=0.5u L=0.18u
Mp726 out726 in vdd vdd pch W=1u L=0.18u
Cl726 out726 0 10f
Mn727 out727 in 0 0 nch W=0.5u L=0.18u
Mp727 out727 in vdd vdd pch W=1u L=0.18u
Cl727 out727 0 10f
Mn728 out728 in 0 0 nch W=0.5u L=0.18u
Mp728 out728 in vdd vdd pch W=1u L=0.18u
Cl728 out728 0 10f
Mn729 out729 in 0 0 nch W=0.5u L=0.18u
Mp729 out729 in vdd vdd pch W=1u L=0.18u
Cl729 out729 0 10f
Mn730 out730 in 0 0 nch W=0.5u L=0.18u
Mp730 out730 in vdd vdd pch W=1u L=0.18u
Cl730 out730 0 10f
Mn731 out731 in 0 0 nch W=0.5u L=0.18u
Mp731 out731 in vdd vdd pch W=1u L=0.18u
Cl731 out731 0 10f
Mn732 out732 in 0 0 nch W=0.5u L=0.18u
Mp732 out732 in vdd vdd pch W=1u L=0.18u
Cl732 out732 0 10f
Mn733 out733 in 0 0 nch W=0.5u L=0.18u
Mp733 out733 in vdd vdd pch W=1u L=0.18u
Cl733 out733 0 10f
Mn734 out734 in 0 0 nch W=0.5u L=0.18u
Mp734 out734 in vdd vdd pch W=1u L=0.18u
Cl734 out734 0 10f
Mn735 out735 in 0 0 nch W=0.5u L=0.18u
Mp735 out735 in vdd vdd pch W=1u L=0.18u
Cl735 out735 0 10f
Mn736 out736 in 0 0 nch W=0.5u L=0.18u
Mp736 out736 in vdd vdd pch W=1u L=0.18u
Cl736 out736 0 10f
Mn737 out737 in 0 0 nch W=0.5u L=0.18u
Mp737 out737 in vdd vdd pch W=1u L=0.18u
Cl737 out737 0 10f
Mn738 out738 in 0 0 nch W=0.5u L=0.18u
Mp738 out738 in vdd vdd pch W=1u L=0.18u
Cl738 out738 0 10f
Mn739 out739 in 0 0 nch W=0.5u L=0.18u
Mp739 out739 in vdd vdd pch W=1u L=0.18u
Cl739 out739 0 10f
Mn740 out740 in 0 0 nch W=0.5u L=0.18u
Mp740 out740 in vdd vdd pch W=1u L=0.18u
Cl740 out740 0 10f
Mn741 out741 in 0 0 nch W=0.5u L=0.18u
Mp741 out741 in vdd vdd pch W=1u L=0.18u
Cl741 out741 0 10f
Mn742 out742 in 0 0 nch W=0.5u L=0.18u
Mp742 out742 in vdd vdd pch W=1u L=0.18u
Cl742 out742 0 10f
Mn743 out743 in 0 0 nch W=0.5u L=0.18u
Mp743 out743 in vdd vdd pch W=1u L=0.18u
Cl743 out743 0 10f
Mn744 out744 in 0 0 nch W=0.5u L=0.18u
Mp744 out744 in vdd vdd pch W=1u L=0.18u
Cl744 out744 0 10f
Mn745 out745 in 0 0 nch W=0.5u L=0.18u
Mp745 out745 in vdd vdd pch W=1u L=0.18u
Cl745 out745 0 10f
Mn746 out746 in 0 0 nch W=0.5u L=0.18u
Mp746 out746 in vdd vdd pch W=1u L=0.18u
Cl746 out746 0 10f
Mn747 out747 in 0 0 nch W=0.5u L=0.18u
Mp747 out747 in vdd vdd pch W=1u L=0.18u
Cl747 out747 0 10f
Mn748 out748 in 0 0 nch W=0.5u L=0.18u
Mp748 out748 in vdd vdd pch W=1u L=0.18u
Cl748 out748 0 10f
Mn749 out749 in 0 0 nch W=0.5u L=0.18u
Mp749 out749 in vdd vdd pch W=1u L=0.18u
Cl749 out749 0 10f
Mn750 out750 in 0 0 nch W=0.5u L=0.18u
Mp750 out750 in vdd vdd pch W=1u L=0.18u
Cl750 out750 0 10f
Mn751 out751 in 0 0 nch W=0.5u L=0.18u
Mp751 out751 in vdd vdd pch W=1u L=0.18u
Cl751 out751 0 10f
Mn752 out752 in 0 0 nch W=0.5u L=0.18u
Mp752 out752 in vdd vdd pch W=1u L=0.18u
Cl752 out752 0 10f
Mn753 out753 in 0 0 nch W=0.5u L=0.18u
Mp753 out753 in vdd vdd pch W=1u L=0.18u
Cl753 out753 0 10f
Mn754 out754 in 0 0 nch W=0.5u L=0.18u
Mp754 out754 in vdd vdd pch W=1u L=0.18u
Cl754 out754 0 10f
Mn755 out755 in 0 0 nch W=0.5u L=0.18u
Mp755 out755 in vdd vdd pch W=1u L=0.18u
Cl755 out755 0 10f
Mn756 out756 in 0 0 nch W=0.5u L=0.18u
Mp756 out756 in vdd vdd pch W=1u L=0.18u
Cl756 out756 0 10f
Mn757 out757 in 0 0 nch W=0.5u L=0.18u
Mp757 out757 in vdd vdd pch W=1u L=0.18u
Cl757 out757 0 10f
Mn758 out758 in 0 0 nch W=0.5u L=0.18u
Mp758 out758 in vdd vdd pch W=1u L=0.18u
Cl758 out758 0 10f
Mn759 out759 in 0 0 nch W=0.5u L=0.18u
Mp759 out759 in vdd vdd pch W=1u L=0.18u
Cl759 out759 0 10f
Mn760 out760 in 0 0 nch W=0.5u L=0.18u
Mp760 out760 in vdd vdd pch W=1u L=0.18u
Cl760 out760 0 10f
Mn761 out761 in 0 0 nch W=0.5u L=0.18u
Mp761 out761 in vdd vdd pch W=1u L=0.18u
Cl761 out761 0 10f
Mn762 out762 in 0 0 nch W=0.5u L=0.18u
Mp762 out762 in vdd vdd pch W=1u L=0.18u
Cl762 out762 0 10f
Mn763 out763 in 0 0 nch W=0.5u L=0.18u
Mp763 out763 in vdd vdd pch W=1u L=0.18u
Cl763 out763 0 10f
Mn764 out764 in 0 0 nch W=0.5u L=0.18u
Mp764 out764 in vdd vdd pch W=1u L=0.18u
Cl764 out764 0 10f
Mn765 out765 in 0 0 nch W=0.5u L=0.18u
Mp765 out765 in vdd vdd pch W=1u L=0.18u
Cl765 out765 0 10f
Mn766 out766 in 0 0 nch W=0.5u L=0.18u
Mp766 out766 in vdd vdd pch W=1u L=0.18u
Cl766 out766 0 10f
Mn767 out767 in 0 0 nch W=0.5u L=0.18u
Mp767 out767 in vdd vdd pch W=1u L=0.18u
Cl767 out767 0 10f
Mn768 out768 in 0 0 nch W=0.5u L=0.18u
Mp768 out768 in vdd vdd pch W=1u L=0.18u
Cl768 out768 0 10f
Mn769 out769 in 0 0 nch W=0.5u L=0.18u
Mp769 out769 in vdd vdd pch W=1u L=0.18u
Cl769 out769 0 10f
Mn770 out770 in 0 0 nch W=0.5u L=0.18u
Mp770 out770 in vdd vdd pch W=1u L=0.18u
Cl770 out770 0 10f
Mn771 out771 in 0 0 nch W=0.5u L=0.18u
Mp771 out771 in vdd vdd pch W=1u L=0.18u
Cl771 out771 0 10f
Mn772 out772 in 0 0 nch W=0.5u L=0.18u
Mp772 out772 in vdd vdd pch W=1u L=0.18u
Cl772 out772 0 10f
Mn773 out773 in 0 0 nch W=0.5u L=0.18u
Mp773 out773 in vdd vdd pch W=1u L=0.18u
Cl773 out773 0 10f
Mn774 out774 in 0 0 nch W=0.5u L=0.18u
Mp774 out774 in vdd vdd pch W=1u L=0.18u
Cl774 out774 0 10f
Mn775 out775 in 0 0 nch W=0.5u L=0.18u
Mp775 out775 in vdd vdd pch W=1u L=0.18u
Cl775 out775 0 10f
Mn776 out776 in 0 0 nch W=0.5u L=0.18u
Mp776 out776 in vdd vdd pch W=1u L=0.18u
Cl776 out776 0 10f
Mn777 out777 in 0 0 nch W=0.5u L=0.18u
Mp777 out777 in vdd vdd pch W=1u L=0.18u
Cl777 out777 0 10f
Mn778 out778 in 0 0 nch W=0.5u L=0.18u
Mp778 out778 in vdd vdd pch W=1u L=0.18u
Cl778 out778 0 10f
Mn779 out779 in 0 0 nch W=0.5u L=0.18u
Mp779 out779 in vdd vdd pch W=1u L=0.18u
Cl779 out779 0 10f
Mn780 out780 in 0 0 nch W=0.5u L=0.18u
Mp780 out780 in vdd vdd pch W=1u L=0.18u
Cl780 out780 0 10f
Mn781 out781 in 0 0 nch W=0.5u L=0.18u
Mp781 out781 in vdd vdd pch W=1u L=0.18u
Cl781 out781 0 10f
Mn782 out782 in 0 0 nch W=0.5u L=0.18u
Mp782 out782 in vdd vdd pch W=1u L=0.18u
Cl782 out782 0 10f
Mn783 out783 in 0 0 nch W=0.5u L=0.18u
Mp783 out783 in vdd vdd pch W=1u L=0.18u
Cl783 out783 0 10f
Mn784 out784 in 0 0 nch W=0.5u L=0.18u
Mp784 out784 in vdd vdd pch W=1u L=0.18u
Cl784 out784 0 10f
Mn785 out785 in 0 0 nch W=0.5u L=0.18u
Mp785 out785 in vdd vdd pch W=1u L=0.18u
Cl785 out785 0 10f
Mn786 out786 in 0 0 nch W=0.5u L=0.18u
Mp786 out786 in vdd vdd pch W=1u L=0.18u
Cl786 out786 0 10f
Mn787 out787 in 0 0 nch W=0.5u L=0.18u
Mp787 out787 in vdd vdd pch W=1u L=0.18u
Cl787 out787 0 10f
Mn788 out788 in 0 0 nch W=0.5u L=0.18u
Mp788 out788 in vdd vdd pch W=1u L=0.18u
Cl788 out788 0 10f
Mn789 out789 in 0 0 nch W=0.5u L=0.18u
Mp789 out789 in vdd vdd pch W=1u L=0.18u
Cl789 out789 0 10f
Mn790 out790 in 0 0 nch W=0.5u L=0.18u
Mp790 out790 in vdd vdd pch W=1u L=0.18u
Cl790 out790 0 10f
Mn791 out791 in 0 0 nch W=0.5u L=0.18u
Mp791 out791 in vdd vdd pch W=1u L=0.18u
Cl791 out791 0 10f
Mn792 out792 in 0 0 nch W=0.5u L=0.18u
Mp792 out792 in vdd vdd pch W=1u L=0.18u
Cl792 out792 0 10f
Mn793 out793 in 0 0 nch W=0.5u L=0.18u
Mp793 out793 in vdd vdd pch W=1u L=0.18u
Cl793 out793 0 10f
Mn794 out794 in 0 0 nch W=0.5u L=0.18u
Mp794 out794 in vdd vdd pch W=1u L=0.18u
Cl794 out794 0 10f
Mn795 out795 in 0 0 nch W=0.5u L=0.18u
Mp795 out795 in vdd vdd pch W=1u L=0.18u
Cl795 out795 0 10f
Mn796 out796 in 0 0 nch W=0.5u L=0.18u
Mp796 out796 in vdd vdd pch W=1u L=0.18u
Cl796 out796 0 10f
Mn797 out797 in 0 0 nch W=0.5u L=0.18u
Mp797 out797 in vdd vdd pch W=1u L=0.18u
Cl797 out797 0 10f
Mn798 out798 in 0 0 nch W=0.5u L=0.18u
Mp798 out798 in vdd vdd pch W=1u L=0.18u
Cl798 out798 0 10f
Mn799 out799 in 0 0 nch W=0.5u L=0.18u
Mp799 out799 in vdd vdd pch W=1u L=0.18u
Cl799 out799 0 10f
Mn800 out800 in 0 0 nch W=0.5u L=0.18u
Mp800 out800 in vdd vdd pch W=1u L=0.18u
Cl800 out800 0 10f
Mn801 out801 in 0 0 nch W=0.5u L=0.18u
Mp801 out801 in vdd vdd pch W=1u L=0.18u
Cl801 out801 0 10f
Mn802 out802 in 0 0 nch W=0.5u L=0.18u
Mp802 out802 in vdd vdd pch W=1u L=0.18u
Cl802 out802 0 10f
Mn803 out803 in 0 0 nch W=0.5u L=0.18u
Mp803 out803 in vdd vdd pch W=1u L=0.18u
Cl803 out803 0 10f
Mn804 out804 in 0 0 nch W=0.5u L=0.18u
Mp804 out804 in vdd vdd pch W=1u L=0.18u
Cl804 out804 0 10f
Mn805 out805 in 0 0 nch W=0.5u L=0.18u
Mp805 out805 in vdd vdd pch W=1u L=0.18u
Cl805 out805 0 10f
Mn806 out806 in 0 0 nch W=0.5u L=0.18u
Mp806 out806 in vdd vdd pch W=1u L=0.18u
Cl806 out806 0 10f
Mn807 out807 in 0 0 nch W=0.5u L=0.18u
Mp807 out807 in vdd vdd pch W=1u L=0.18u
Cl807 out807 0 10f
Mn808 out808 in 0 0 nch W=0.5u L=0.18u
Mp808 out808 in vdd vdd pch W=1u L=0.18u
Cl808 out808 0 10f
Mn809 out809 in 0 0 nch W=0.5u L=0.18u
Mp809 out809 in vdd vdd pch W=1u L=0.18u
Cl809 out809 0 10f
Mn810 out810 in 0 0 nch W=0.5u L=0.18u
Mp810 out810 in vdd vdd pch W=1u L=0.18u
Cl810 out810 0 10f
Mn811 out811 in 0 0 nch W=0.5u L=0.18u
Mp811 out811 in vdd vdd pch W=1u L=0.18u
Cl811 out811 0 10f
Mn812 out812 in 0 0 nch W=0.5u L=0.18u
Mp812 out812 in vdd vdd pch W=1u L=0.18u
Cl812 out812 0 10f
Mn813 out813 in 0 0 nch W=0.5u L=0.18u
Mp813 out813 in vdd vdd pch W=1u L=0.18u
Cl813 out813 0 10f
Mn814 out814 in 0 0 nch W=0.5u L=0.18u
Mp814 out814 in vdd vdd pch W=1u L=0.18u
Cl814 out814 0 10f
Mn815 out815 in 0 0 nch W=0.5u L=0.18u
Mp815 out815 in vdd vdd pch W=1u L=0.18u
Cl815 out815 0 10f
Mn816 out816 in 0 0 nch W=0.5u L=0.18u
Mp816 out816 in vdd vdd pch W=1u L=0.18u
Cl816 out816 0 10f
Mn817 out817 in 0 0 nch W=0.5u L=0.18u
Mp817 out817 in vdd vdd pch W=1u L=0.18u
Cl817 out817 0 10f
Mn818 out818 in 0 0 nch W=0.5u L=0.18u
Mp818 out818 in vdd vdd pch W=1u L=0.18u
Cl818 out818 0 10f
Mn819 out819 in 0 0 nch W=0.5u L=0.18u
Mp819 out819 in vdd vdd pch W=1u L=0.18u
Cl819 out819 0 10f
Mn820 out820 in 0 0 nch W=0.5u L=0.18u
Mp820 out820 in vdd vdd pch W=1u L=0.18u
Cl820 out820 0 10f
Mn821 out821 in 0 0 nch W=0.5u L=0.18u
Mp821 out821 in vdd vdd pch W=1u L=0.18u
Cl821 out821 0 10f
Mn822 out822 in 0 0 nch W=0.5u L=0.18u
Mp822 out822 in vdd vdd pch W=1u L=0.18u
Cl822 out822 0 10f
Mn823 out823 in 0 0 nch W=0.5u L=0.18u
Mp823 out823 in vdd vdd pch W=1u L=0.18u
Cl823 out823 0 10f
Mn824 out824 in 0 0 nch W=0.5u L=0.18u
Mp824 out824 in vdd vdd pch W=1u L=0.18u
Cl824 out824 0 10f
Mn825 out825 in 0 0 nch W=0.5u L=0.18u
Mp825 out825 in vdd vdd pch W=1u L=0.18u
Cl825 out825 0 10f
Mn826 out826 in 0 0 nch W=0.5u L=0.18u
Mp826 out826 in vdd vdd pch W=1u L=0.18u
Cl826 out826 0 10f
Mn827 out827 in 0 0 nch W=0.5u L=0.18u
Mp827 out827 in vdd vdd pch W=1u L=0.18u
Cl827 out827 0 10f
Mn828 out828 in 0 0 nch W=0.5u L=0.18u
Mp828 out828 in vdd vdd pch W=1u L=0.18u
Cl828 out828 0 10f
Mn829 out829 in 0 0 nch W=0.5u L=0.18u
Mp829 out829 in vdd vdd pch W=1u L=0.18u
Cl829 out829 0 10f
Mn830 out830 in 0 0 nch W=0.5u L=0.18u
Mp830 out830 in vdd vdd pch W=1u L=0.18u
Cl830 out830 0 10f
Mn831 out831 in 0 0 nch W=0.5u L=0.18u
Mp831 out831 in vdd vdd pch W=1u L=0.18u
Cl831 out831 0 10f
Mn832 out832 in 0 0 nch W=0.5u L=0.18u
Mp832 out832 in vdd vdd pch W=1u L=0.18u
Cl832 out832 0 10f
Mn833 out833 in 0 0 nch W=0.5u L=0.18u
Mp833 out833 in vdd vdd pch W=1u L=0.18u
Cl833 out833 0 10f
Mn834 out834 in 0 0 nch W=0.5u L=0.18u
Mp834 out834 in vdd vdd pch W=1u L=0.18u
Cl834 out834 0 10f
Mn835 out835 in 0 0 nch W=0.5u L=0.18u
Mp835 out835 in vdd vdd pch W=1u L=0.18u
Cl835 out835 0 10f
Mn836 out836 in 0 0 nch W=0.5u L=0.18u
Mp836 out836 in vdd vdd pch W=1u L=0.18u
Cl836 out836 0 10f
Mn837 out837 in 0 0 nch W=0.5u L=0.18u
Mp837 out837 in vdd vdd pch W=1u L=0.18u
Cl837 out837 0 10f
Mn838 out838 in 0 0 nch W=0.5u L=0.18u
Mp838 out838 in vdd vdd pch W=1u L=0.18u
Cl838 out838 0 10f
Mn839 out839 in 0 0 nch W=0.5u L=0.18u
Mp839 out839 in vdd vdd pch W=1u L=0.18u
Cl839 out839 0 10f
Mn840 out840 in 0 0 nch W=0.5u L=0.18u
Mp840 out840 in vdd vdd pch W=1u L=0.18u
Cl840 out840 0 10f
Mn841 out841 in 0 0 nch W=0.5u L=0.18u
Mp841 out841 in vdd vdd pch W=1u L=0.18u
Cl841 out841 0 10f
Mn842 out842 in 0 0 nch W=0.5u L=0.18u
Mp842 out842 in vdd vdd pch W=1u L=0.18u
Cl842 out842 0 10f
Mn843 out843 in 0 0 nch W=0.5u L=0.18u
Mp843 out843 in vdd vdd pch W=1u L=0.18u
Cl843 out843 0 10f
Mn844 out844 in 0 0 nch W=0.5u L=0.18u
Mp844 out844 in vdd vdd pch W=1u L=0.18u
Cl844 out844 0 10f
Mn845 out845 in 0 0 nch W=0.5u L=0.18u
Mp845 out845 in vdd vdd pch W=1u L=0.18u
Cl845 out845 0 10f
Mn846 out846 in 0 0 nch W=0.5u L=0.18u
Mp846 out846 in vdd vdd pch W=1u L=0.18u
Cl846 out846 0 10f
Mn847 out847 in 0 0 nch W=0.5u L=0.18u
Mp847 out847 in vdd vdd pch W=1u L=0.18u
Cl847 out847 0 10f
Mn848 out848 in 0 0 nch W=0.5u L=0.18u
Mp848 out848 in vdd vdd pch W=1u L=0.18u
Cl848 out848 0 10f
Mn849 out849 in 0 0 nch W=0.5u L=0.18u
Mp849 out849 in vdd vdd pch W=1u L=0.18u
Cl849 out849 0 10f
Mn850 out850 in 0 0 nch W=0.5u L=0.18u
Mp850 out850 in vdd vdd pch W=1u L=0.18u
Cl850 out850 0 10f
Mn851 out851 in 0 0 nch W=0.5u L=0.18u
Mp851 out851 in vdd vdd pch W=1u L=0.18u
Cl851 out851 0 10f
Mn852 out852 in 0 0 nch W=0.5u L=0.18u
Mp852 out852 in vdd vdd pch W=1u L=0.18u
Cl852 out852 0 10f
Mn853 out853 in 0 0 nch W=0.5u L=0.18u
Mp853 out853 in vdd vdd pch W=1u L=0.18u
Cl853 out853 0 10f
Mn854 out854 in 0 0 nch W=0.5u L=0.18u
Mp854 out854 in vdd vdd pch W=1u L=0.18u
Cl854 out854 0 10f
Mn855 out855 in 0 0 nch W=0.5u L=0.18u
Mp855 out855 in vdd vdd pch W=1u L=0.18u
Cl855 out855 0 10f
Mn856 out856 in 0 0 nch W=0.5u L=0.18u
Mp856 out856 in vdd vdd pch W=1u L=0.18u
Cl856 out856 0 10f
Mn857 out857 in 0 0 nch W=0.5u L=0.18u
Mp857 out857 in vdd vdd pch W=1u L=0.18u
Cl857 out857 0 10f
Mn858 out858 in 0 0 nch W=0.5u L=0.18u
Mp858 out858 in vdd vdd pch W=1u L=0.18u
Cl858 out858 0 10f
Mn859 out859 in 0 0 nch W=0.5u L=0.18u
Mp859 out859 in vdd vdd pch W=1u L=0.18u
Cl859 out859 0 10f
Mn860 out860 in 0 0 nch W=0.5u L=0.18u
Mp860 out860 in vdd vdd pch W=1u L=0.18u
Cl860 out860 0 10f
Mn861 out861 in 0 0 nch W=0.5u L=0.18u
Mp861 out861 in vdd vdd pch W=1u L=0.18u
Cl861 out861 0 10f
Mn862 out862 in 0 0 nch W=0.5u L=0.18u
Mp862 out862 in vdd vdd pch W=1u L=0.18u
Cl862 out862 0 10f
Mn863 out863 in 0 0 nch W=0.5u L=0.18u
Mp863 out863 in vdd vdd pch W=1u L=0.18u
Cl863 out863 0 10f
Mn864 out864 in 0 0 nch W=0.5u L=0.18u
Mp864 out864 in vdd vdd pch W=1u L=0.18u
Cl864 out864 0 10f
Mn865 out865 in 0 0 nch W=0.5u L=0.18u
Mp865 out865 in vdd vdd pch W=1u L=0.18u
Cl865 out865 0 10f
Mn866 out866 in 0 0 nch W=0.5u L=0.18u
Mp866 out866 in vdd vdd pch W=1u L=0.18u
Cl866 out866 0 10f
Mn867 out867 in 0 0 nch W=0.5u L=0.18u
Mp867 out867 in vdd vdd pch W=1u L=0.18u
Cl867 out867 0 10f
Mn868 out868 in 0 0 nch W=0.5u L=0.18u
Mp868 out868 in vdd vdd pch W=1u L=0.18u
Cl868 out868 0 10f
Mn869 out869 in 0 0 nch W=0.5u L=0.18u
Mp869 out869 in vdd vdd pch W=1u L=0.18u
Cl869 out869 0 10f
Mn870 out870 in 0 0 nch W=0.5u L=0.18u
Mp870 out870 in vdd vdd pch W=1u L=0.18u
Cl870 out870 0 10f
Mn871 out871 in 0 0 nch W=0.5u L=0.18u
Mp871 out871 in vdd vdd pch W=1u L=0.18u
Cl871 out871 0 10f
Mn872 out872 in 0 0 nch W=0.5u L=0.18u
Mp872 out872 in vdd vdd pch W=1u L=0.18u
Cl872 out872 0 10f
Mn873 out873 in 0 0 nch W=0.5u L=0.18u
Mp873 out873 in vdd vdd pch W=1u L=0.18u
Cl873 out873 0 10f
Mn874 out874 in 0 0 nch W=0.5u L=0.18u
Mp874 out874 in vdd vdd pch W=1u L=0.18u
Cl874 out874 0 10f
Mn875 out875 in 0 0 nch W=0.5u L=0.18u
Mp875 out875 in vdd vdd pch W=1u L=0.18u
Cl875 out875 0 10f
Mn876 out876 in 0 0 nch W=0.5u L=0.18u
Mp876 out876 in vdd vdd pch W=1u L=0.18u
Cl876 out876 0 10f
Mn877 out877 in 0 0 nch W=0.5u L=0.18u
Mp877 out877 in vdd vdd pch W=1u L=0.18u
Cl877 out877 0 10f
Mn878 out878 in 0 0 nch W=0.5u L=0.18u
Mp878 out878 in vdd vdd pch W=1u L=0.18u
Cl878 out878 0 10f
Mn879 out879 in 0 0 nch W=0.5u L=0.18u
Mp879 out879 in vdd vdd pch W=1u L=0.18u
Cl879 out879 0 10f
Mn880 out880 in 0 0 nch W=0.5u L=0.18u
Mp880 out880 in vdd vdd pch W=1u L=0.18u
Cl880 out880 0 10f
Mn881 out881 in 0 0 nch W=0.5u L=0.18u
Mp881 out881 in vdd vdd pch W=1u L=0.18u
Cl881 out881 0 10f
Mn882 out882 in 0 0 nch W=0.5u L=0.18u
Mp882 out882 in vdd vdd pch W=1u L=0.18u
Cl882 out882 0 10f
Mn883 out883 in 0 0 nch W=0.5u L=0.18u
Mp883 out883 in vdd vdd pch W=1u L=0.18u
Cl883 out883 0 10f
Mn884 out884 in 0 0 nch W=0.5u L=0.18u
Mp884 out884 in vdd vdd pch W=1u L=0.18u
Cl884 out884 0 10f
Mn885 out885 in 0 0 nch W=0.5u L=0.18u
Mp885 out885 in vdd vdd pch W=1u L=0.18u
Cl885 out885 0 10f
Mn886 out886 in 0 0 nch W=0.5u L=0.18u
Mp886 out886 in vdd vdd pch W=1u L=0.18u
Cl886 out886 0 10f
Mn887 out887 in 0 0 nch W=0.5u L=0.18u
Mp887 out887 in vdd vdd pch W=1u L=0.18u
Cl887 out887 0 10f
Mn888 out888 in 0 0 nch W=0.5u L=0.18u
Mp888 out888 in vdd vdd pch W=1u L=0.18u
Cl888 out888 0 10f
Mn889 out889 in 0 0 nch W=0.5u L=0.18u
Mp889 out889 in vdd vdd pch W=1u L=0.18u
Cl889 out889 0 10f
Mn890 out890 in 0 0 nch W=0.5u L=0.18u
Mp890 out890 in vdd vdd pch W=1u L=0.18u
Cl890 out890 0 10f
Mn891 out891 in 0 0 nch W=0.5u L=0.18u
Mp891 out891 in vdd vdd pch W=1u L=0.18u
Cl891 out891 0 10f
Mn892 out892 in 0 0 nch W=0.5u L=0.18u
Mp892 out892 in vdd vdd pch W=1u L=0.18u
Cl892 out892 0 10f
Mn893 out893 in 0 0 nch W=0.5u L=0.18u
Mp893 out893 in vdd vdd pch W=1u L=0.18u
Cl893 out893 0 10f
Mn894 out894 in 0 0 nch W=0.5u L=0.18u
Mp894 out894 in vdd vdd pch W=1u L=0.18u
Cl894 out894 0 10f
Mn895 out895 in 0 0 nch W=0.5u L=0.18u
Mp895 out895 in vdd vdd pch W=1u L=0.18u
Cl895 out895 0 10f
Mn896 out896 in 0 0 nch W=0.5u L=0.18u
Mp896 out896 in vdd vdd pch W=1u L=0.18u
Cl896 out896 0 10f
Mn897 out897 in 0 0 nch W=0.5u L=0.18u
Mp897 out897 in vdd vdd pch W=1u L=0.18u
Cl897 out897 0 10f
Mn898 out898 in 0 0 nch W=0.5u L=0.18u
Mp898 out898 in vdd vdd pch W=1u L=0.18u
Cl898 out898 0 10f
Mn899 out899 in 0 0 nch W=0.5u L=0.18u
Mp899 out899 in vdd vdd pch W=1u L=0.18u
Cl899 out899 0 10f
Mn900 out900 in 0 0 nch W=0.5u L=0.18u
Mp900 out900 in vdd vdd pch W=1u L=0.18u
Cl900 out900 0 10f
Mn901 out901 in 0 0 nch W=0.5u L=0.18u
Mp901 out901 in vdd vdd pch W=1u L=0.18u
Cl901 out901 0 10f
Mn902 out902 in 0 0 nch W=0.5u L=0.18u
Mp902 out902 in vdd vdd pch W=1u L=0.18u
Cl902 out902 0 10f
Mn903 out903 in 0 0 nch W=0.5u L=0.18u
Mp903 out903 in vdd vdd pch W=1u L=0.18u
Cl903 out903 0 10f
Mn904 out904 in 0 0 nch W=0.5u L=0.18u
Mp904 out904 in vdd vdd pch W=1u L=0.18u
Cl904 out904 0 10f
Mn905 out905 in 0 0 nch W=0.5u L=0.18u
Mp905 out905 in vdd vdd pch W=1u L=0.18u
Cl905 out905 0 10f
Mn906 out906 in 0 0 nch W=0.5u L=0.18u
Mp906 out906 in vdd vdd pch W=1u L=0.18u
Cl906 out906 0 10f
Mn907 out907 in 0 0 nch W=0.5u L=0.18u
Mp907 out907 in vdd vdd pch W=1u L=0.18u
Cl907 out907 0 10f
Mn908 out908 in 0 0 nch W=0.5u L=0.18u
Mp908 out908 in vdd vdd pch W=1u L=0.18u
Cl908 out908 0 10f
Mn909 out909 in 0 0 nch W=0.5u L=0.18u
Mp909 out909 in vdd vdd pch W=1u L=0.18u
Cl909 out909 0 10f
Mn910 out910 in 0 0 nch W=0.5u L=0.18u
Mp910 out910 in vdd vdd pch W=1u L=0.18u
Cl910 out910 0 10f
Mn911 out911 in 0 0 nch W=0.5u L=0.18u
Mp911 out911 in vdd vdd pch W=1u L=0.18u
Cl911 out911 0 10f
Mn912 out912 in 0 0 nch W=0.5u L=0.18u
Mp912 out912 in vdd vdd pch W=1u L=0.18u
Cl912 out912 0 10f
Mn913 out913 in 0 0 nch W=0.5u L=0.18u
Mp913 out913 in vdd vdd pch W=1u L=0.18u
Cl913 out913 0 10f
Mn914 out914 in 0 0 nch W=0.5u L=0.18u
Mp914 out914 in vdd vdd pch W=1u L=0.18u
Cl914 out914 0 10f
Mn915 out915 in 0 0 nch W=0.5u L=0.18u
Mp915 out915 in vdd vdd pch W=1u L=0.18u
Cl915 out915 0 10f
Mn916 out916 in 0 0 nch W=0.5u L=0.18u
Mp916 out916 in vdd vdd pch W=1u L=0.18u
Cl916 out916 0 10f
Mn917 out917 in 0 0 nch W=0.5u L=0.18u
Mp917 out917 in vdd vdd pch W=1u L=0.18u
Cl917 out917 0 10f
Mn918 out918 in 0 0 nch W=0.5u L=0.18u
Mp918 out918 in vdd vdd pch W=1u L=0.18u
Cl918 out918 0 10f
Mn919 out919 in 0 0 nch W=0.5u L=0.18u
Mp919 out919 in vdd vdd pch W=1u L=0.18u
Cl919 out919 0 10f
Mn920 out920 in 0 0 nch W=0.5u L=0.18u
Mp920 out920 in vdd vdd pch W=1u L=0.18u
Cl920 out920 0 10f
Mn921 out921 in 0 0 nch W=0.5u L=0.18u
Mp921 out921 in vdd vdd pch W=1u L=0.18u
Cl921 out921 0 10f
Mn922 out922 in 0 0 nch W=0.5u L=0.18u
Mp922 out922 in vdd vdd pch W=1u L=0.18u
Cl922 out922 0 10f
Mn923 out923 in 0 0 nch W=0.5u L=0.18u
Mp923 out923 in vdd vdd pch W=1u L=0.18u
Cl923 out923 0 10f
Mn924 out924 in 0 0 nch W=0.5u L=0.18u
Mp924 out924 in vdd vdd pch W=1u L=0.18u
Cl924 out924 0 10f
Mn925 out925 in 0 0 nch W=0.5u L=0.18u
Mp925 out925 in vdd vdd pch W=1u L=0.18u
Cl925 out925 0 10f
Mn926 out926 in 0 0 nch W=0.5u L=0.18u
Mp926 out926 in vdd vdd pch W=1u L=0.18u
Cl926 out926 0 10f
Mn927 out927 in 0 0 nch W=0.5u L=0.18u
Mp927 out927 in vdd vdd pch W=1u L=0.18u
Cl927 out927 0 10f
Mn928 out928 in 0 0 nch W=0.5u L=0.18u
Mp928 out928 in vdd vdd pch W=1u L=0.18u
Cl928 out928 0 10f
Mn929 out929 in 0 0 nch W=0.5u L=0.18u
Mp929 out929 in vdd vdd pch W=1u L=0.18u
Cl929 out929 0 10f
Mn930 out930 in 0 0 nch W=0.5u L=0.18u
Mp930 out930 in vdd vdd pch W=1u L=0.18u
Cl930 out930 0 10f
Mn931 out931 in 0 0 nch W=0.5u L=0.18u
Mp931 out931 in vdd vdd pch W=1u L=0.18u
Cl931 out931 0 10f
Mn932 out932 in 0 0 nch W=0.5u L=0.18u
Mp932 out932 in vdd vdd pch W=1u L=0.18u
Cl932 out932 0 10f
Mn933 out933 in 0 0 nch W=0.5u L=0.18u
Mp933 out933 in vdd vdd pch W=1u L=0.18u
Cl933 out933 0 10f
Mn934 out934 in 0 0 nch W=0.5u L=0.18u
Mp934 out934 in vdd vdd pch W=1u L=0.18u
Cl934 out934 0 10f
Mn935 out935 in 0 0 nch W=0.5u L=0.18u
Mp935 out935 in vdd vdd pch W=1u L=0.18u
Cl935 out935 0 10f
Mn936 out936 in 0 0 nch W=0.5u L=0.18u
Mp936 out936 in vdd vdd pch W=1u L=0.18u
Cl936 out936 0 10f
Mn937 out937 in 0 0 nch W=0.5u L=0.18u
Mp937 out937 in vdd vdd pch W=1u L=0.18u
Cl937 out937 0 10f
Mn938 out938 in 0 0 nch W=0.5u L=0.18u
Mp938 out938 in vdd vdd pch W=1u L=0.18u
Cl938 out938 0 10f
Mn939 out939 in 0 0 nch W=0.5u L=0.18u
Mp939 out939 in vdd vdd pch W=1u L=0.18u
Cl939 out939 0 10f
Mn940 out940 in 0 0 nch W=0.5u L=0.18u
Mp940 out940 in vdd vdd pch W=1u L=0.18u
Cl940 out940 0 10f
Mn941 out941 in 0 0 nch W=0.5u L=0.18u
Mp941 out941 in vdd vdd pch W=1u L=0.18u
Cl941 out941 0 10f
Mn942 out942 in 0 0 nch W=0.5u L=0.18u
Mp942 out942 in vdd vdd pch W=1u L=0.18u
Cl942 out942 0 10f
Mn943 out943 in 0 0 nch W=0.5u L=0.18u
Mp943 out943 in vdd vdd pch W=1u L=0.18u
Cl943 out943 0 10f
Mn944 out944 in 0 0 nch W=0.5u L=0.18u
Mp944 out944 in vdd vdd pch W=1u L=0.18u
Cl944 out944 0 10f
Mn945 out945 in 0 0 nch W=0.5u L=0.18u
Mp945 out945 in vdd vdd pch W=1u L=0.18u
Cl945 out945 0 10f
Mn946 out946 in 0 0 nch W=0.5u L=0.18u
Mp946 out946 in vdd vdd pch W=1u L=0.18u
Cl946 out946 0 10f
Mn947 out947 in 0 0 nch W=0.5u L=0.18u
Mp947 out947 in vdd vdd pch W=1u L=0.18u
Cl947 out947 0 10f
Mn948 out948 in 0 0 nch W=0.5u L=0.18u
Mp948 out948 in vdd vdd pch W=1u L=0.18u
Cl948 out948 0 10f
Mn949 out949 in 0 0 nch W=0.5u L=0.18u
Mp949 out949 in vdd vdd pch W=1u L=0.18u
Cl949 out949 0 10f
Mn950 out950 in 0 0 nch W=0.5u L=0.18u
Mp950 out950 in vdd vdd pch W=1u L=0.18u
Cl950 out950 0 10f
Mn951 out951 in 0 0 nch W=0.5u L=0.18u
Mp951 out951 in vdd vdd pch W=1u L=0.18u
Cl951 out951 0 10f
Mn952 out952 in 0 0 nch W=0.5u L=0.18u
Mp952 out952 in vdd vdd pch W=1u L=0.18u
Cl952 out952 0 10f
Mn953 out953 in 0 0 nch W=0.5u L=0.18u
Mp953 out953 in vdd vdd pch W=1u L=0.18u
Cl953 out953 0 10f
Mn954 out954 in 0 0 nch W=0.5u L=0.18u
Mp954 out954 in vdd vdd pch W=1u L=0.18u
Cl954 out954 0 10f
Mn955 out955 in 0 0 nch W=0.5u L=0.18u
Mp955 out955 in vdd vdd pch W=1u L=0.18u
Cl955 out955 0 10f
Mn956 out956 in 0 0 nch W=0.5u L=0.18u
Mp956 out956 in vdd vdd pch W=1u L=0.18u
Cl956 out956 0 10f
Mn957 out957 in 0 0 nch W=0.5u L=0.18u
Mp957 out957 in vdd vdd pch W=1u L=0.18u
Cl957 out957 0 10f
Mn958 out958 in 0 0 nch W=0.5u L=0.18u
Mp958 out958 in vdd vdd pch W=1u L=0.18u
Cl958 out958 0 10f
Mn959 out959 in 0 0 nch W=0.5u L=0.18u
Mp959 out959 in vdd vdd pch W=1u L=0.18u
Cl959 out959 0 10f
Mn960 out960 in 0 0 nch W=0.5u L=0.18u
Mp960 out960 in vdd vdd pch W=1u L=0.18u
Cl960 out960 0 10f
Mn961 out961 in 0 0 nch W=0.5u L=0.18u
Mp961 out961 in vdd vdd pch W=1u L=0.18u
Cl961 out961 0 10f
Mn962 out962 in 0 0 nch W=0.5u L=0.18u
Mp962 out962 in vdd vdd pch W=1u L=0.18u
Cl962 out962 0 10f
Mn963 out963 in 0 0 nch W=0.5u L=0.18u
Mp963 out963 in vdd vdd pch W=1u L=0.18u
Cl963 out963 0 10f
Mn964 out964 in 0 0 nch W=0.5u L=0.18u
Mp964 out964 in vdd vdd pch W=1u L=0.18u
Cl964 out964 0 10f
Mn965 out965 in 0 0 nch W=0.5u L=0.18u
Mp965 out965 in vdd vdd pch W=1u L=0.18u
Cl965 out965 0 10f
Mn966 out966 in 0 0 nch W=0.5u L=0.18u
Mp966 out966 in vdd vdd pch W=1u L=0.18u
Cl966 out966 0 10f
Mn967 out967 in 0 0 nch W=0.5u L=0.18u
Mp967 out967 in vdd vdd pch W=1u L=0.18u
Cl967 out967 0 10f
Mn968 out968 in 0 0 nch W=0.5u L=0.18u
Mp968 out968 in vdd vdd pch W=1u L=0.18u
Cl968 out968 0 10f
Mn969 out969 in 0 0 nch W=0.5u L=0.18u
Mp969 out969 in vdd vdd pch W=1u L=0.18u
Cl969 out969 0 10f
Mn970 out970 in 0 0 nch W=0.5u L=0.18u
Mp970 out970 in vdd vdd pch W=1u L=0.18u
Cl970 out970 0 10f
Mn971 out971 in 0 0 nch W=0.5u L=0.18u
Mp971 out971 in vdd vdd pch W=1u L=0.18u
Cl971 out971 0 10f
Mn972 out972 in 0 0 nch W=0.5u L=0.18u
Mp972 out972 in vdd vdd pch W=1u L=0.18u
Cl972 out972 0 10f
Mn973 out973 in 0 0 nch W=0.5u L=0.18u
Mp973 out973 in vdd vdd pch W=1u L=0.18u
Cl973 out973 0 10f
Mn974 out974 in 0 0 nch W=0.5u L=0.18u
Mp974 out974 in vdd vdd pch W=1u L=0.18u
Cl974 out974 0 10f
Mn975 out975 in 0 0 nch W=0.5u L=0.18u
Mp975 out975 in vdd vdd pch W=1u L=0.18u
Cl975 out975 0 10f
Mn976 out976 in 0 0 nch W=0.5u L=0.18u
Mp976 out976 in vdd vdd pch W=1u L=0.18u
Cl976 out976 0 10f
Mn977 out977 in 0 0 nch W=0.5u L=0.18u
Mp977 out977 in vdd vdd pch W=1u L=0.18u
Cl977 out977 0 10f
Mn978 out978 in 0 0 nch W=0.5u L=0.18u
Mp978 out978 in vdd vdd pch W=1u L=0.18u
Cl978 out978 0 10f
Mn979 out979 in 0 0 nch W=0.5u L=0.18u
Mp979 out979 in vdd vdd pch W=1u L=0.18u
Cl979 out979 0 10f
Mn980 out980 in 0 0 nch W=0.5u L=0.18u
Mp980 out980 in vdd vdd pch W=1u L=0.18u
Cl980 out980 0 10f
Mn981 out981 in 0 0 nch W=0.5u L=0.18u
Mp981 out981 in vdd vdd pch W=1u L=0.18u
Cl981 out981 0 10f
Mn982 out982 in 0 0 nch W=0.5u L=0.18u
Mp982 out982 in vdd vdd pch W=1u L=0.18u
Cl982 out982 0 10f
Mn983 out983 in 0 0 nch W=0.5u L=0.18u
Mp983 out983 in vdd vdd pch W=1u L=0.18u
Cl983 out983 0 10f
Mn984 out984 in 0 0 nch W=0.5u L=0.18u
Mp984 out984 in vdd vdd pch W=1u L=0.18u
Cl984 out984 0 10f
Mn985 out985 in 0 0 nch W=0.5u L=0.18u
Mp985 out985 in vdd vdd pch W=1u L=0.18u
Cl985 out985 0 10f
Mn986 out986 in 0 0 nch W=0.5u L=0.18u
Mp986 out986 in vdd vdd pch W=1u L=0.18u
Cl986 out986 0 10f
Mn987 out987 in 0 0 nch W=0.5u L=0.18u
Mp987 out987 in vdd vdd pch W=1u L=0.18u
Cl987 out987 0 10f
Mn988 out988 in 0 0 nch W=0.5u L=0.18u
Mp988 out988 in vdd vdd pch W=1u L=0.18u
Cl988 out988 0 10f
Mn989 out989 in 0 0 nch W=0.5u L=0.18u
Mp989 out989 in vdd vdd pch W=1u L=0.18u
Cl989 out989 0 10f
Mn990 out990 in 0 0 nch W=0.5u L=0.18u
Mp990 out990 in vdd vdd pch W=1u L=0.18u
Cl990 out990 0 10f
Mn991 out991 in 0 0 nch W=0.5u L=0.18u
Mp991 out991 in vdd vdd pch W=1u L=0.18u
Cl991 out991 0 10f
Mn992 out992 in 0 0 nch W=0.5u L=0.18u
Mp992 out992 in vdd vdd pch W=1u L=0.18u
Cl992 out992 0 10f
Mn993 out993 in 0 0 nch W=0.5u L=0.18u
Mp993 out993 in vdd vdd pch W=1u L=0.18u
Cl993 out993 0 10f
Mn994 out994 in 0 0 nch W=0.5u L=0.18u
Mp994 out994 in vdd vdd pch W=1u L=0.18u
Cl994 out994 0 10f
Mn995 out995 in 0 0 nch W=0.5u L=0.18u
Mp995 out995 in vdd vdd pch W=1u L=0.18u
Cl995 out995 0 10f
Mn996 out996 in 0 0 nch W=0.5u L=0.18u
Mp996 out996 in vdd vdd pch W=1u L=0.18u
Cl996 out996 0 10f
Mn997 out997 in 0 0 nch W=0.5u L=0.18u
Mp997 out997 in vdd vdd pch W=1u L=0.18u
Cl997 out997 0 10f
Mn998 out998 in 0 0 nch W=0.5u L=0.18u
Mp998 out998 in vdd vdd pch W=1u L=0.18u
Cl998 out998 0 10f
Mn999 out999 in 0 0 nch W=0.5u L=0.18u
Mp999 out999 in vdd vdd pch W=1u L=0.18u
Cl999 out999 0 10f
Mn1000 out1000 in 0 0 nch W=0.5u L=0.18u
Mp1000 out1000 in vdd vdd pch W=1u L=0.18u
Cl1000 out1000 0 10f
Mn1001 out1001 in 0 0 nch W=0.5u L=0.18u
Mp1001 out1001 in vdd vdd pch W=1u L=0.18u
Cl1001 out1001 0 10f
Mn1002 out1002 in 0 0 nch W=0.5u L=0.18u
Mp1002 out1002 in vdd vdd pch W=1u L=0.18u
Cl1002 out1002 0 10f
Mn1003 out1003 in 0 0 nch W=0.5u L=0.18u
Mp1003 out1003 in vdd vdd pch W=1u L=0.18u
Cl1003 out1003 0 10f
Mn1004 out1004 in 0 0 nch W=0.5u L=0.18u
Mp1004 out1004 in vdd vdd pch W=1u L=0.18u
Cl1004 out1004 0 10f
Mn1005 out1005 in 0 0 nch W=0.5u L=0.18u
Mp1005 out1005 in vdd vdd pch W=1u L=0.18u
Cl1005 out1005 0 10f
Mn1006 out1006 in 0 0 nch W=0.5u L=0.18u
Mp1006 out1006 in vdd vdd pch W=1u L=0.18u
Cl1006 out1006 0 10f
Mn1007 out1007 in 0 0 nch W=0.5u L=0.18u
Mp1007 out1007 in vdd vdd pch W=1u L=0.18u
Cl1007 out1007 0 10f
Mn1008 out1008 in 0 0 nch W=0.5u L=0.18u
Mp1008 out1008 in vdd vdd pch W=1u L=0.18u
Cl1008 out1008 0 10f
Mn1009 out1009 in 0 0 nch W=0.5u L=0.18u
Mp1009 out1009 in vdd vdd pch W=1u L=0.18u
Cl1009 out1009 0 10f
Mn1010 out1010 in 0 0 nch W=0.5u L=0.18u
Mp1010 out1010 in vdd vdd pch W=1u L=0.18u
Cl1010 out1010 0 10f
Mn1011 out1011 in 0 0 nch W=0.5u L=0.18u
Mp1011 out1011 in vdd vdd pch W=1u L=0.18u
Cl1011 out1011 0 10f
Mn1012 out1012 in 0 0 nch W=0.5u L=0.18u
Mp1012 out1012 in vdd vdd pch W=1u L=0.18u
Cl1012 out1012 0 10f
Mn1013 out1013 in 0 0 nch W=0.5u L=0.18u
Mp1013 out1013 in vdd vdd pch W=1u L=0.18u
Cl1013 out1013 0 10f
Mn1014 out1014 in 0 0 nch W=0.5u L=0.18u
Mp1014 out1014 in vdd vdd pch W=1u L=0.18u
Cl1014 out1014 0 10f
Mn1015 out1015 in 0 0 nch W=0.5u L=0.18u
Mp1015 out1015 in vdd vdd pch W=1u L=0.18u
Cl1015 out1015 0 10f
Mn1016 out1016 in 0 0 nch W=0.5u L=0.18u
Mp1016 out1016 in vdd vdd pch W=1u L=0.18u
Cl1016 out1016 0 10f
Mn1017 out1017 in 0 0 nch W=0.5u L=0.18u
Mp1017 out1017 in vdd vdd pch W=1u L=0.18u
Cl1017 out1017 0 10f
Mn1018 out1018 in 0 0 nch W=0.5u L=0.18u
Mp1018 out1018 in vdd vdd pch W=1u L=0.18u
Cl1018 out1018 0 10f
Mn1019 out1019 in 0 0 nch W=0.5u L=0.18u
Mp1019 out1019 in vdd vdd pch W=1u L=0.18u
Cl1019 out1019 0 10f
Mn1020 out1020 in 0 0 nch W=0.5u L=0.18u
Mp1020 out1020 in vdd vdd pch W=1u L=0.18u
Cl1020 out1020 0 10f
Mn1021 out1021 in 0 0 nch W=0.5u L=0.18u
Mp1021 out1021 in vdd vdd pch W=1u L=0.18u
Cl1021 out1021 0 10f
Mn1022 out1022 in 0 0 nch W=0.5u L=0.18u
Mp1022 out1022 in vdd vdd pch W=1u L=0.18u
Cl1022 out1022 0 10f
Mn1023 out1023 in 0 0 nch W=0.5u L=0.18u
Mp1023 out1023 in vdd vdd pch W=1u L=0.18u
Cl1023 out1023 0 10f
Mn1024 out1024 in 0 0 nch W=0.5u L=0.18u
Mp1024 out1024 in vdd vdd pch W=1u L=0.18u
Cl1024 out1024 0 10f
Mn1025 out1025 in 0 0 nch W=0.5u L=0.18u
Mp1025 out1025 in vdd vdd pch W=1u L=0.18u
Cl1025 out1025 0 10f
Mn1026 out1026 in 0 0 nch W=0.5u L=0.18u
Mp1026 out1026 in vdd vdd pch W=1u L=0.18u
Cl1026 out1026 0 10f
Mn1027 out1027 in 0 0 nch W=0.5u L=0.18u
Mp1027 out1027 in vdd vdd pch W=1u L=0.18u
Cl1027 out1027 0 10f
Mn1028 out1028 in 0 0 nch W=0.5u L=0.18u
Mp1028 out1028 in vdd vdd pch W=1u L=0.18u
Cl1028 out1028 0 10f
Mn1029 out1029 in 0 0 nch W=0.5u L=0.18u
Mp1029 out1029 in vdd vdd pch W=1u L=0.18u
Cl1029 out1029 0 10f
Mn1030 out1030 in 0 0 nch W=0.5u L=0.18u
Mp1030 out1030 in vdd vdd pch W=1u L=0.18u
Cl1030 out1030 0 10f
Mn1031 out1031 in 0 0 nch W=0.5u L=0.18u
Mp1031 out1031 in vdd vdd pch W=1u L=0.18u
Cl1031 out1031 0 10f
Mn1032 out1032 in 0 0 nch W=0.5u L=0.18u
Mp1032 out1032 in vdd vdd pch W=1u L=0.18u
Cl1032 out1032 0 10f
Mn1033 out1033 in 0 0 nch W=0.5u L=0.18u
Mp1033 out1033 in vdd vdd pch W=1u L=0.18u
Cl1033 out1033 0 10f
Mn1034 out1034 in 0 0 nch W=0.5u L=0.18u
Mp1034 out1034 in vdd vdd pch W=1u L=0.18u
Cl1034 out1034 0 10f
Mn1035 out1035 in 0 0 nch W=0.5u L=0.18u
Mp1035 out1035 in vdd vdd pch W=1u L=0.18u
Cl1035 out1035 0 10f
Mn1036 out1036 in 0 0 nch W=0.5u L=0.18u
Mp1036 out1036 in vdd vdd pch W=1u L=0.18u
Cl1036 out1036 0 10f
Mn1037 out1037 in 0 0 nch W=0.5u L=0.18u
Mp1037 out1037 in vdd vdd pch W=1u L=0.18u
Cl1037 out1037 0 10f
Mn1038 out1038 in 0 0 nch W=0.5u L=0.18u
Mp1038 out1038 in vdd vdd pch W=1u L=0.18u
Cl1038 out1038 0 10f
Mn1039 out1039 in 0 0 nch W=0.5u L=0.18u
Mp1039 out1039 in vdd vdd pch W=1u L=0.18u
Cl1039 out1039 0 10f
Mn1040 out1040 in 0 0 nch W=0.5u L=0.18u
Mp1040 out1040 in vdd vdd pch W=1u L=0.18u
Cl1040 out1040 0 10f
Mn1041 out1041 in 0 0 nch W=0.5u L=0.18u
Mp1041 out1041 in vdd vdd pch W=1u L=0.18u
Cl1041 out1041 0 10f
Mn1042 out1042 in 0 0 nch W=0.5u L=0.18u
Mp1042 out1042 in vdd vdd pch W=1u L=0.18u
Cl1042 out1042 0 10f
Mn1043 out1043 in 0 0 nch W=0.5u L=0.18u
Mp1043 out1043 in vdd vdd pch W=1u L=0.18u
Cl1043 out1043 0 10f
Mn1044 out1044 in 0 0 nch W=0.5u L=0.18u
Mp1044 out1044 in vdd vdd pch W=1u L=0.18u
Cl1044 out1044 0 10f
Mn1045 out1045 in 0 0 nch W=0.5u L=0.18u
Mp1045 out1045 in vdd vdd pch W=1u L=0.18u
Cl1045 out1045 0 10f
Mn1046 out1046 in 0 0 nch W=0.5u L=0.18u
Mp1046 out1046 in vdd vdd pch W=1u L=0.18u
Cl1046 out1046 0 10f
Mn1047 out1047 in 0 0 nch W=0.5u L=0.18u
Mp1047 out1047 in vdd vdd pch W=1u L=0.18u
Cl1047 out1047 0 10f
Mn1048 out1048 in 0 0 nch W=0.5u L=0.18u
Mp1048 out1048 in vdd vdd pch W=1u L=0.18u
Cl1048 out1048 0 10f
Mn1049 out1049 in 0 0 nch W=0.5u L=0.18u
Mp1049 out1049 in vdd vdd pch W=1u L=0.18u
Cl1049 out1049 0 10f
Mn1050 out1050 in 0 0 nch W=0.5u L=0.18u
Mp1050 out1050 in vdd vdd pch W=1u L=0.18u
Cl1050 out1050 0 10f
Mn1051 out1051 in 0 0 nch W=0.5u L=0.18u
Mp1051 out1051 in vdd vdd pch W=1u L=0.18u
Cl1051 out1051 0 10f
Mn1052 out1052 in 0 0 nch W=0.5u L=0.18u
Mp1052 out1052 in vdd vdd pch W=1u L=0.18u
Cl1052 out1052 0 10f
Mn1053 out1053 in 0 0 nch W=0.5u L=0.18u
Mp1053 out1053 in vdd vdd pch W=1u L=0.18u
Cl1053 out1053 0 10f
Mn1054 out1054 in 0 0 nch W=0.5u L=0.18u
Mp1054 out1054 in vdd vdd pch W=1u L=0.18u
Cl1054 out1054 0 10f
Mn1055 out1055 in 0 0 nch W=0.5u L=0.18u
Mp1055 out1055 in vdd vdd pch W=1u L=0.18u
Cl1055 out1055 0 10f
Mn1056 out1056 in 0 0 nch W=0.5u L=0.18u
Mp1056 out1056 in vdd vdd pch W=1u L=0.18u
Cl1056 out1056 0 10f
Mn1057 out1057 in 0 0 nch W=0.5u L=0.18u
Mp1057 out1057 in vdd vdd pch W=1u L=0.18u
Cl1057 out1057 0 10f
Mn1058 out1058 in 0 0 nch W=0.5u L=0.18u
Mp1058 out1058 in vdd vdd pch W=1u L=0.18u
Cl1058 out1058 0 10f
Mn1059 out1059 in 0 0 nch W=0.5u L=0.18u
Mp1059 out1059 in vdd vdd pch W=1u L=0.18u
Cl1059 out1059 0 10f
Mn1060 out1060 in 0 0 nch W=0.5u L=0.18u
Mp1060 out1060 in vdd vdd pch W=1u L=0.18u
Cl1060 out1060 0 10f
Mn1061 out1061 in 0 0 nch W=0.5u L=0.18u
Mp1061 out1061 in vdd vdd pch W=1u L=0.18u
Cl1061 out1061 0 10f
Mn1062 out1062 in 0 0 nch W=0.5u L=0.18u
Mp1062 out1062 in vdd vdd pch W=1u L=0.18u
Cl1062 out1062 0 10f
Mn1063 out1063 in 0 0 nch W=0.5u L=0.18u
Mp1063 out1063 in vdd vdd pch W=1u L=0.18u
Cl1063 out1063 0 10f
Mn1064 out1064 in 0 0 nch W=0.5u L=0.18u
Mp1064 out1064 in vdd vdd pch W=1u L=0.18u
Cl1064 out1064 0 10f
Mn1065 out1065 in 0 0 nch W=0.5u L=0.18u
Mp1065 out1065 in vdd vdd pch W=1u L=0.18u
Cl1065 out1065 0 10f
Mn1066 out1066 in 0 0 nch W=0.5u L=0.18u
Mp1066 out1066 in vdd vdd pch W=1u L=0.18u
Cl1066 out1066 0 10f
Mn1067 out1067 in 0 0 nch W=0.5u L=0.18u
Mp1067 out1067 in vdd vdd pch W=1u L=0.18u
Cl1067 out1067 0 10f
Mn1068 out1068 in 0 0 nch W=0.5u L=0.18u
Mp1068 out1068 in vdd vdd pch W=1u L=0.18u
Cl1068 out1068 0 10f
Mn1069 out1069 in 0 0 nch W=0.5u L=0.18u
Mp1069 out1069 in vdd vdd pch W=1u L=0.18u
Cl1069 out1069 0 10f
Mn1070 out1070 in 0 0 nch W=0.5u L=0.18u
Mp1070 out1070 in vdd vdd pch W=1u L=0.18u
Cl1070 out1070 0 10f
Mn1071 out1071 in 0 0 nch W=0.5u L=0.18u
Mp1071 out1071 in vdd vdd pch W=1u L=0.18u
Cl1071 out1071 0 10f
Mn1072 out1072 in 0 0 nch W=0.5u L=0.18u
Mp1072 out1072 in vdd vdd pch W=1u L=0.18u
Cl1072 out1072 0 10f
Mn1073 out1073 in 0 0 nch W=0.5u L=0.18u
Mp1073 out1073 in vdd vdd pch W=1u L=0.18u
Cl1073 out1073 0 10f
Mn1074 out1074 in 0 0 nch W=0.5u L=0.18u
Mp1074 out1074 in vdd vdd pch W=1u L=0.18u
Cl1074 out1074 0 10f
Mn1075 out1075 in 0 0 nch W=0.5u L=0.18u
Mp1075 out1075 in vdd vdd pch W=1u L=0.18u
Cl1075 out1075 0 10f
Mn1076 out1076 in 0 0 nch W=0.5u L=0.18u
Mp1076 out1076 in vdd vdd pch W=1u L=0.18u
Cl1076 out1076 0 10f
Mn1077 out1077 in 0 0 nch W=0.5u L=0.18u
Mp1077 out1077 in vdd vdd pch W=1u L=0.18u
Cl1077 out1077 0 10f
Mn1078 out1078 in 0 0 nch W=0.5u L=0.18u
Mp1078 out1078 in vdd vdd pch W=1u L=0.18u
Cl1078 out1078 0 10f
Mn1079 out1079 in 0 0 nch W=0.5u L=0.18u
Mp1079 out1079 in vdd vdd pch W=1u L=0.18u
Cl1079 out1079 0 10f
Mn1080 out1080 in 0 0 nch W=0.5u L=0.18u
Mp1080 out1080 in vdd vdd pch W=1u L=0.18u
Cl1080 out1080 0 10f
Mn1081 out1081 in 0 0 nch W=0.5u L=0.18u
Mp1081 out1081 in vdd vdd pch W=1u L=0.18u
Cl1081 out1081 0 10f
Mn1082 out1082 in 0 0 nch W=0.5u L=0.18u
Mp1082 out1082 in vdd vdd pch W=1u L=0.18u
Cl1082 out1082 0 10f
Mn1083 out1083 in 0 0 nch W=0.5u L=0.18u
Mp1083 out1083 in vdd vdd pch W=1u L=0.18u
Cl1083 out1083 0 10f
Mn1084 out1084 in 0 0 nch W=0.5u L=0.18u
Mp1084 out1084 in vdd vdd pch W=1u L=0.18u
Cl1084 out1084 0 10f
Mn1085 out1085 in 0 0 nch W=0.5u L=0.18u
Mp1085 out1085 in vdd vdd pch W=1u L=0.18u
Cl1085 out1085 0 10f
Mn1086 out1086 in 0 0 nch W=0.5u L=0.18u
Mp1086 out1086 in vdd vdd pch W=1u L=0.18u
Cl1086 out1086 0 10f
Mn1087 out1087 in 0 0 nch W=0.5u L=0.18u
Mp1087 out1087 in vdd vdd pch W=1u L=0.18u
Cl1087 out1087 0 10f
Mn1088 out1088 in 0 0 nch W=0.5u L=0.18u
Mp1088 out1088 in vdd vdd pch W=1u L=0.18u
Cl1088 out1088 0 10f
Mn1089 out1089 in 0 0 nch W=0.5u L=0.18u
Mp1089 out1089 in vdd vdd pch W=1u L=0.18u
Cl1089 out1089 0 10f
Mn1090 out1090 in 0 0 nch W=0.5u L=0.18u
Mp1090 out1090 in vdd vdd pch W=1u L=0.18u
Cl1090 out1090 0 10f
Mn1091 out1091 in 0 0 nch W=0.5u L=0.18u
Mp1091 out1091 in vdd vdd pch W=1u L=0.18u
Cl1091 out1091 0 10f
Mn1092 out1092 in 0 0 nch W=0.5u L=0.18u
Mp1092 out1092 in vdd vdd pch W=1u L=0.18u
Cl1092 out1092 0 10f
Mn1093 out1093 in 0 0 nch W=0.5u L=0.18u
Mp1093 out1093 in vdd vdd pch W=1u L=0.18u
Cl1093 out1093 0 10f
Mn1094 out1094 in 0 0 nch W=0.5u L=0.18u
Mp1094 out1094 in vdd vdd pch W=1u L=0.18u
Cl1094 out1094 0 10f
Mn1095 out1095 in 0 0 nch W=0.5u L=0.18u
Mp1095 out1095 in vdd vdd pch W=1u L=0.18u
Cl1095 out1095 0 10f
Mn1096 out1096 in 0 0 nch W=0.5u L=0.18u
Mp1096 out1096 in vdd vdd pch W=1u L=0.18u
Cl1096 out1096 0 10f
Mn1097 out1097 in 0 0 nch W=0.5u L=0.18u
Mp1097 out1097 in vdd vdd pch W=1u L=0.18u
Cl1097 out1097 0 10f
Mn1098 out1098 in 0 0 nch W=0.5u L=0.18u
Mp1098 out1098 in vdd vdd pch W=1u L=0.18u
Cl1098 out1098 0 10f
Mn1099 out1099 in 0 0 nch W=0.5u L=0.18u
Mp1099 out1099 in vdd vdd pch W=1u L=0.18u
Cl1099 out1099 0 10f
Mn1100 out1100 in 0 0 nch W=0.5u L=0.18u
Mp1100 out1100 in vdd vdd pch W=1u L=0.18u
Cl1100 out1100 0 10f
Mn1101 out1101 in 0 0 nch W=0.5u L=0.18u
Mp1101 out1101 in vdd vdd pch W=1u L=0.18u
Cl1101 out1101 0 10f
Mn1102 out1102 in 0 0 nch W=0.5u L=0.18u
Mp1102 out1102 in vdd vdd pch W=1u L=0.18u
Cl1102 out1102 0 10f
Mn1103 out1103 in 0 0 nch W=0.5u L=0.18u
Mp1103 out1103 in vdd vdd pch W=1u L=0.18u
Cl1103 out1103 0 10f
Mn1104 out1104 in 0 0 nch W=0.5u L=0.18u
Mp1104 out1104 in vdd vdd pch W=1u L=0.18u
Cl1104 out1104 0 10f
Mn1105 out1105 in 0 0 nch W=0.5u L=0.18u
Mp1105 out1105 in vdd vdd pch W=1u L=0.18u
Cl1105 out1105 0 10f
Mn1106 out1106 in 0 0 nch W=0.5u L=0.18u
Mp1106 out1106 in vdd vdd pch W=1u L=0.18u
Cl1106 out1106 0 10f
Mn1107 out1107 in 0 0 nch W=0.5u L=0.18u
Mp1107 out1107 in vdd vdd pch W=1u L=0.18u
Cl1107 out1107 0 10f
Mn1108 out1108 in 0 0 nch W=0.5u L=0.18u
Mp1108 out1108 in vdd vdd pch W=1u L=0.18u
Cl1108 out1108 0 10f
Mn1109 out1109 in 0 0 nch W=0.5u L=0.18u
Mp1109 out1109 in vdd vdd pch W=1u L=0.18u
Cl1109 out1109 0 10f
Mn1110 out1110 in 0 0 nch W=0.5u L=0.18u
Mp1110 out1110 in vdd vdd pch W=1u L=0.18u
Cl1110 out1110 0 10f
Mn1111 out1111 in 0 0 nch W=0.5u L=0.18u
Mp1111 out1111 in vdd vdd pch W=1u L=0.18u
Cl1111 out1111 0 10f
Mn1112 out1112 in 0 0 nch W=0.5u L=0.18u
Mp1112 out1112 in vdd vdd pch W=1u L=0.18u
Cl1112 out1112 0 10f
Mn1113 out1113 in 0 0 nch W=0.5u L=0.18u
Mp1113 out1113 in vdd vdd pch W=1u L=0.18u
Cl1113 out1113 0 10f
Mn1114 out1114 in 0 0 nch W=0.5u L=0.18u
Mp1114 out1114 in vdd vdd pch W=1u L=0.18u
Cl1114 out1114 0 10f
Mn1115 out1115 in 0 0 nch W=0.5u L=0.18u
Mp1115 out1115 in vdd vdd pch W=1u L=0.18u
Cl1115 out1115 0 10f
Mn1116 out1116 in 0 0 nch W=0.5u L=0.18u
Mp1116 out1116 in vdd vdd pch W=1u L=0.18u
Cl1116 out1116 0 10f
Mn1117 out1117 in 0 0 nch W=0.5u L=0.18u
Mp1117 out1117 in vdd vdd pch W=1u L=0.18u
Cl1117 out1117 0 10f
Mn1118 out1118 in 0 0 nch W=0.5u L=0.18u
Mp1118 out1118 in vdd vdd pch W=1u L=0.18u
Cl1118 out1118 0 10f
Mn1119 out1119 in 0 0 nch W=0.5u L=0.18u
Mp1119 out1119 in vdd vdd pch W=1u L=0.18u
Cl1119 out1119 0 10f
Mn1120 out1120 in 0 0 nch W=0.5u L=0.18u
Mp1120 out1120 in vdd vdd pch W=1u L=0.18u
Cl1120 out1120 0 10f
Mn1121 out1121 in 0 0 nch W=0.5u L=0.18u
Mp1121 out1121 in vdd vdd pch W=1u L=0.18u
Cl1121 out1121 0 10f
Mn1122 out1122 in 0 0 nch W=0.5u L=0.18u
Mp1122 out1122 in vdd vdd pch W=1u L=0.18u
Cl1122 out1122 0 10f
Mn1123 out1123 in 0 0 nch W=0.5u L=0.18u
Mp1123 out1123 in vdd vdd pch W=1u L=0.18u
Cl1123 out1123 0 10f
Mn1124 out1124 in 0 0 nch W=0.5u L=0.18u
Mp1124 out1124 in vdd vdd pch W=1u L=0.18u
Cl1124 out1124 0 10f
Mn1125 out1125 in 0 0 nch W=0.5u L=0.18u
Mp1125 out1125 in vdd vdd pch W=1u L=0.18u
Cl1125 out1125 0 10f
Mn1126 out1126 in 0 0 nch W=0.5u L=0.18u
Mp1126 out1126 in vdd vdd pch W=1u L=0.18u
Cl1126 out1126 0 10f
Mn1127 out1127 in 0 0 nch W=0.5u L=0.18u
Mp1127 out1127 in vdd vdd pch W=1u L=0.18u
Cl1127 out1127 0 10f
Mn1128 out1128 in 0 0 nch W=0.5u L=0.18u
Mp1128 out1128 in vdd vdd pch W=1u L=0.18u
Cl1128 out1128 0 10f
Mn1129 out1129 in 0 0 nch W=0.5u L=0.18u
Mp1129 out1129 in vdd vdd pch W=1u L=0.18u
Cl1129 out1129 0 10f
Mn1130 out1130 in 0 0 nch W=0.5u L=0.18u
Mp1130 out1130 in vdd vdd pch W=1u L=0.18u
Cl1130 out1130 0 10f
Mn1131 out1131 in 0 0 nch W=0.5u L=0.18u
Mp1131 out1131 in vdd vdd pch W=1u L=0.18u
Cl1131 out1131 0 10f
Mn1132 out1132 in 0 0 nch W=0.5u L=0.18u
Mp1132 out1132 in vdd vdd pch W=1u L=0.18u
Cl1132 out1132 0 10f
Mn1133 out1133 in 0 0 nch W=0.5u L=0.18u
Mp1133 out1133 in vdd vdd pch W=1u L=0.18u
Cl1133 out1133 0 10f
Mn1134 out1134 in 0 0 nch W=0.5u L=0.18u
Mp1134 out1134 in vdd vdd pch W=1u L=0.18u
Cl1134 out1134 0 10f
Mn1135 out1135 in 0 0 nch W=0.5u L=0.18u
Mp1135 out1135 in vdd vdd pch W=1u L=0.18u
Cl1135 out1135 0 10f
Mn1136 out1136 in 0 0 nch W=0.5u L=0.18u
Mp1136 out1136 in vdd vdd pch W=1u L=0.18u
Cl1136 out1136 0 10f
Mn1137 out1137 in 0 0 nch W=0.5u L=0.18u
Mp1137 out1137 in vdd vdd pch W=1u L=0.18u
Cl1137 out1137 0 10f
Mn1138 out1138 in 0 0 nch W=0.5u L=0.18u
Mp1138 out1138 in vdd vdd pch W=1u L=0.18u
Cl1138 out1138 0 10f
Mn1139 out1139 in 0 0 nch W=0.5u L=0.18u
Mp1139 out1139 in vdd vdd pch W=1u L=0.18u
Cl1139 out1139 0 10f
Mn1140 out1140 in 0 0 nch W=0.5u L=0.18u
Mp1140 out1140 in vdd vdd pch W=1u L=0.18u
Cl1140 out1140 0 10f
Mn1141 out1141 in 0 0 nch W=0.5u L=0.18u
Mp1141 out1141 in vdd vdd pch W=1u L=0.18u
Cl1141 out1141 0 10f
Mn1142 out1142 in 0 0 nch W=0.5u L=0.18u
Mp1142 out1142 in vdd vdd pch W=1u L=0.18u
Cl1142 out1142 0 10f
Mn1143 out1143 in 0 0 nch W=0.5u L=0.18u
Mp1143 out1143 in vdd vdd pch W=1u L=0.18u
Cl1143 out1143 0 10f
Mn1144 out1144 in 0 0 nch W=0.5u L=0.18u
Mp1144 out1144 in vdd vdd pch W=1u L=0.18u
Cl1144 out1144 0 10f
Mn1145 out1145 in 0 0 nch W=0.5u L=0.18u
Mp1145 out1145 in vdd vdd pch W=1u L=0.18u
Cl1145 out1145 0 10f
Mn1146 out1146 in 0 0 nch W=0.5u L=0.18u
Mp1146 out1146 in vdd vdd pch W=1u L=0.18u
Cl1146 out1146 0 10f
Mn1147 out1147 in 0 0 nch W=0.5u L=0.18u
Mp1147 out1147 in vdd vdd pch W=1u L=0.18u
Cl1147 out1147 0 10f
Mn1148 out1148 in 0 0 nch W=0.5u L=0.18u
Mp1148 out1148 in vdd vdd pch W=1u L=0.18u
Cl1148 out1148 0 10f
Mn1149 out1149 in 0 0 nch W=0.5u L=0.18u
Mp1149 out1149 in vdd vdd pch W=1u L=0.18u
Cl1149 out1149 0 10f
Mn1150 out1150 in 0 0 nch W=0.5u L=0.18u
Mp1150 out1150 in vdd vdd pch W=1u L=0.18u
Cl1150 out1150 0 10f
Mn1151 out1151 in 0 0 nch W=0.5u L=0.18u
Mp1151 out1151 in vdd vdd pch W=1u L=0.18u
Cl1151 out1151 0 10f
Mn1152 out1152 in 0 0 nch W=0.5u L=0.18u
Mp1152 out1152 in vdd vdd pch W=1u L=0.18u
Cl1152 out1152 0 10f
Mn1153 out1153 in 0 0 nch W=0.5u L=0.18u
Mp1153 out1153 in vdd vdd pch W=1u L=0.18u
Cl1153 out1153 0 10f
Mn1154 out1154 in 0 0 nch W=0.5u L=0.18u
Mp1154 out1154 in vdd vdd pch W=1u L=0.18u
Cl1154 out1154 0 10f
Mn1155 out1155 in 0 0 nch W=0.5u L=0.18u
Mp1155 out1155 in vdd vdd pch W=1u L=0.18u
Cl1155 out1155 0 10f
Mn1156 out1156 in 0 0 nch W=0.5u L=0.18u
Mp1156 out1156 in vdd vdd pch W=1u L=0.18u
Cl1156 out1156 0 10f
Mn1157 out1157 in 0 0 nch W=0.5u L=0.18u
Mp1157 out1157 in vdd vdd pch W=1u L=0.18u
Cl1157 out1157 0 10f
Mn1158 out1158 in 0 0 nch W=0.5u L=0.18u
Mp1158 out1158 in vdd vdd pch W=1u L=0.18u
Cl1158 out1158 0 10f
Mn1159 out1159 in 0 0 nch W=0.5u L=0.18u
Mp1159 out1159 in vdd vdd pch W=1u L=0.18u
Cl1159 out1159 0 10f
Mn1160 out1160 in 0 0 nch W=0.5u L=0.18u
Mp1160 out1160 in vdd vdd pch W=1u L=0.18u
Cl1160 out1160 0 10f
Mn1161 out1161 in 0 0 nch W=0.5u L=0.18u
Mp1161 out1161 in vdd vdd pch W=1u L=0.18u
Cl1161 out1161 0 10f
Mn1162 out1162 in 0 0 nch W=0.5u L=0.18u
Mp1162 out1162 in vdd vdd pch W=1u L=0.18u
Cl1162 out1162 0 10f
Mn1163 out1163 in 0 0 nch W=0.5u L=0.18u
Mp1163 out1163 in vdd vdd pch W=1u L=0.18u
Cl1163 out1163 0 10f
Mn1164 out1164 in 0 0 nch W=0.5u L=0.18u
Mp1164 out1164 in vdd vdd pch W=1u L=0.18u
Cl1164 out1164 0 10f
Mn1165 out1165 in 0 0 nch W=0.5u L=0.18u
Mp1165 out1165 in vdd vdd pch W=1u L=0.18u
Cl1165 out1165 0 10f
Mn1166 out1166 in 0 0 nch W=0.5u L=0.18u
Mp1166 out1166 in vdd vdd pch W=1u L=0.18u
Cl1166 out1166 0 10f
Mn1167 out1167 in 0 0 nch W=0.5u L=0.18u
Mp1167 out1167 in vdd vdd pch W=1u L=0.18u
Cl1167 out1167 0 10f
Mn1168 out1168 in 0 0 nch W=0.5u L=0.18u
Mp1168 out1168 in vdd vdd pch W=1u L=0.18u
Cl1168 out1168 0 10f
Mn1169 out1169 in 0 0 nch W=0.5u L=0.18u
Mp1169 out1169 in vdd vdd pch W=1u L=0.18u
Cl1169 out1169 0 10f
Mn1170 out1170 in 0 0 nch W=0.5u L=0.18u
Mp1170 out1170 in vdd vdd pch W=1u L=0.18u
Cl1170 out1170 0 10f
Mn1171 out1171 in 0 0 nch W=0.5u L=0.18u
Mp1171 out1171 in vdd vdd pch W=1u L=0.18u
Cl1171 out1171 0 10f
Mn1172 out1172 in 0 0 nch W=0.5u L=0.18u
Mp1172 out1172 in vdd vdd pch W=1u L=0.18u
Cl1172 out1172 0 10f
Mn1173 out1173 in 0 0 nch W=0.5u L=0.18u
Mp1173 out1173 in vdd vdd pch W=1u L=0.18u
Cl1173 out1173 0 10f
Mn1174 out1174 in 0 0 nch W=0.5u L=0.18u
Mp1174 out1174 in vdd vdd pch W=1u L=0.18u
Cl1174 out1174 0 10f
Mn1175 out1175 in 0 0 nch W=0.5u L=0.18u
Mp1175 out1175 in vdd vdd pch W=1u L=0.18u
Cl1175 out1175 0 10f
Mn1176 out1176 in 0 0 nch W=0.5u L=0.18u
Mp1176 out1176 in vdd vdd pch W=1u L=0.18u
Cl1176 out1176 0 10f
Mn1177 out1177 in 0 0 nch W=0.5u L=0.18u
Mp1177 out1177 in vdd vdd pch W=1u L=0.18u
Cl1177 out1177 0 10f
Mn1178 out1178 in 0 0 nch W=0.5u L=0.18u
Mp1178 out1178 in vdd vdd pch W=1u L=0.18u
Cl1178 out1178 0 10f
Mn1179 out1179 in 0 0 nch W=0.5u L=0.18u
Mp1179 out1179 in vdd vdd pch W=1u L=0.18u
Cl1179 out1179 0 10f
Mn1180 out1180 in 0 0 nch W=0.5u L=0.18u
Mp1180 out1180 in vdd vdd pch W=1u L=0.18u
Cl1180 out1180 0 10f
Mn1181 out1181 in 0 0 nch W=0.5u L=0.18u
Mp1181 out1181 in vdd vdd pch W=1u L=0.18u
Cl1181 out1181 0 10f
Mn1182 out1182 in 0 0 nch W=0.5u L=0.18u
Mp1182 out1182 in vdd vdd pch W=1u L=0.18u
Cl1182 out1182 0 10f
Mn1183 out1183 in 0 0 nch W=0.5u L=0.18u
Mp1183 out1183 in vdd vdd pch W=1u L=0.18u
Cl1183 out1183 0 10f
Mn1184 out1184 in 0 0 nch W=0.5u L=0.18u
Mp1184 out1184 in vdd vdd pch W=1u L=0.18u
Cl1184 out1184 0 10f
Mn1185 out1185 in 0 0 nch W=0.5u L=0.18u
Mp1185 out1185 in vdd vdd pch W=1u L=0.18u
Cl1185 out1185 0 10f
Mn1186 out1186 in 0 0 nch W=0.5u L=0.18u
Mp1186 out1186 in vdd vdd pch W=1u L=0.18u
Cl1186 out1186 0 10f
Mn1187 out1187 in 0 0 nch W=0.5u L=0.18u
Mp1187 out1187 in vdd vdd pch W=1u L=0.18u
Cl1187 out1187 0 10f
Mn1188 out1188 in 0 0 nch W=0.5u L=0.18u
Mp1188 out1188 in vdd vdd pch W=1u L=0.18u
Cl1188 out1188 0 10f
Mn1189 out1189 in 0 0 nch W=0.5u L=0.18u
Mp1189 out1189 in vdd vdd pch W=1u L=0.18u
Cl1189 out1189 0 10f
Mn1190 out1190 in 0 0 nch W=0.5u L=0.18u
Mp1190 out1190 in vdd vdd pch W=1u L=0.18u
Cl1190 out1190 0 10f
Mn1191 out1191 in 0 0 nch W=0.5u L=0.18u
Mp1191 out1191 in vdd vdd pch W=1u L=0.18u
Cl1191 out1191 0 10f
Mn1192 out1192 in 0 0 nch W=0.5u L=0.18u
Mp1192 out1192 in vdd vdd pch W=1u L=0.18u
Cl1192 out1192 0 10f
Mn1193 out1193 in 0 0 nch W=0.5u L=0.18u
Mp1193 out1193 in vdd vdd pch W=1u L=0.18u
Cl1193 out1193 0 10f
Mn1194 out1194 in 0 0 nch W=0.5u L=0.18u
Mp1194 out1194 in vdd vdd pch W=1u L=0.18u
Cl1194 out1194 0 10f
Mn1195 out1195 in 0 0 nch W=0.5u L=0.18u
Mp1195 out1195 in vdd vdd pch W=1u L=0.18u
Cl1195 out1195 0 10f
Mn1196 out1196 in 0 0 nch W=0.5u L=0.18u
Mp1196 out1196 in vdd vdd pch W=1u L=0.18u
Cl1196 out1196 0 10f
Mn1197 out1197 in 0 0 nch W=0.5u L=0.18u
Mp1197 out1197 in vdd vdd pch W=1u L=0.18u
Cl1197 out1197 0 10f
Mn1198 out1198 in 0 0 nch W=0.5u L=0.18u
Mp1198 out1198 in vdd vdd pch W=1u L=0.18u
Cl1198 out1198 0 10f
Mn1199 out1199 in 0 0 nch W=0.5u L=0.18u
Mp1199 out1199 in vdd vdd pch W=1u L=0.18u
Cl1199 out1199 0 10f
Mn1200 out1200 in 0 0 nch W=0.5u L=0.18u
Mp1200 out1200 in vdd vdd pch W=1u L=0.18u
Cl1200 out1200 0 10f
Mn1201 out1201 in 0 0 nch W=0.5u L=0.18u
Mp1201 out1201 in vdd vdd pch W=1u L=0.18u
Cl1201 out1201 0 10f
Mn1202 out1202 in 0 0 nch W=0.5u L=0.18u
Mp1202 out1202 in vdd vdd pch W=1u L=0.18u
Cl1202 out1202 0 10f
Mn1203 out1203 in 0 0 nch W=0.5u L=0.18u
Mp1203 out1203 in vdd vdd pch W=1u L=0.18u
Cl1203 out1203 0 10f
Mn1204 out1204 in 0 0 nch W=0.5u L=0.18u
Mp1204 out1204 in vdd vdd pch W=1u L=0.18u
Cl1204 out1204 0 10f
Mn1205 out1205 in 0 0 nch W=0.5u L=0.18u
Mp1205 out1205 in vdd vdd pch W=1u L=0.18u
Cl1205 out1205 0 10f
Mn1206 out1206 in 0 0 nch W=0.5u L=0.18u
Mp1206 out1206 in vdd vdd pch W=1u L=0.18u
Cl1206 out1206 0 10f
Mn1207 out1207 in 0 0 nch W=0.5u L=0.18u
Mp1207 out1207 in vdd vdd pch W=1u L=0.18u
Cl1207 out1207 0 10f
Mn1208 out1208 in 0 0 nch W=0.5u L=0.18u
Mp1208 out1208 in vdd vdd pch W=1u L=0.18u
Cl1208 out1208 0 10f
Mn1209 out1209 in 0 0 nch W=0.5u L=0.18u
Mp1209 out1209 in vdd vdd pch W=1u L=0.18u
Cl1209 out1209 0 10f
Mn1210 out1210 in 0 0 nch W=0.5u L=0.18u
Mp1210 out1210 in vdd vdd pch W=1u L=0.18u
Cl1210 out1210 0 10f
Mn1211 out1211 in 0 0 nch W=0.5u L=0.18u
Mp1211 out1211 in vdd vdd pch W=1u L=0.18u
Cl1211 out1211 0 10f
Mn1212 out1212 in 0 0 nch W=0.5u L=0.18u
Mp1212 out1212 in vdd vdd pch W=1u L=0.18u
Cl1212 out1212 0 10f
Mn1213 out1213 in 0 0 nch W=0.5u L=0.18u
Mp1213 out1213 in vdd vdd pch W=1u L=0.18u
Cl1213 out1213 0 10f
Mn1214 out1214 in 0 0 nch W=0.5u L=0.18u
Mp1214 out1214 in vdd vdd pch W=1u L=0.18u
Cl1214 out1214 0 10f
Mn1215 out1215 in 0 0 nch W=0.5u L=0.18u
Mp1215 out1215 in vdd vdd pch W=1u L=0.18u
Cl1215 out1215 0 10f
Mn1216 out1216 in 0 0 nch W=0.5u L=0.18u
Mp1216 out1216 in vdd vdd pch W=1u L=0.18u
Cl1216 out1216 0 10f
Mn1217 out1217 in 0 0 nch W=0.5u L=0.18u
Mp1217 out1217 in vdd vdd pch W=1u L=0.18u
Cl1217 out1217 0 10f
Mn1218 out1218 in 0 0 nch W=0.5u L=0.18u
Mp1218 out1218 in vdd vdd pch W=1u L=0.18u
Cl1218 out1218 0 10f
Mn1219 out1219 in 0 0 nch W=0.5u L=0.18u
Mp1219 out1219 in vdd vdd pch W=1u L=0.18u
Cl1219 out1219 0 10f
Mn1220 out1220 in 0 0 nch W=0.5u L=0.18u
Mp1220 out1220 in vdd vdd pch W=1u L=0.18u
Cl1220 out1220 0 10f
Mn1221 out1221 in 0 0 nch W=0.5u L=0.18u
Mp1221 out1221 in vdd vdd pch W=1u L=0.18u
Cl1221 out1221 0 10f
Mn1222 out1222 in 0 0 nch W=0.5u L=0.18u
Mp1222 out1222 in vdd vdd pch W=1u L=0.18u
Cl1222 out1222 0 10f
Mn1223 out1223 in 0 0 nch W=0.5u L=0.18u
Mp1223 out1223 in vdd vdd pch W=1u L=0.18u
Cl1223 out1223 0 10f
Mn1224 out1224 in 0 0 nch W=0.5u L=0.18u
Mp1224 out1224 in vdd vdd pch W=1u L=0.18u
Cl1224 out1224 0 10f
Mn1225 out1225 in 0 0 nch W=0.5u L=0.18u
Mp1225 out1225 in vdd vdd pch W=1u L=0.18u
Cl1225 out1225 0 10f
Mn1226 out1226 in 0 0 nch W=0.5u L=0.18u
Mp1226 out1226 in vdd vdd pch W=1u L=0.18u
Cl1226 out1226 0 10f
Mn1227 out1227 in 0 0 nch W=0.5u L=0.18u
Mp1227 out1227 in vdd vdd pch W=1u L=0.18u
Cl1227 out1227 0 10f
Mn1228 out1228 in 0 0 nch W=0.5u L=0.18u
Mp1228 out1228 in vdd vdd pch W=1u L=0.18u
Cl1228 out1228 0 10f
Mn1229 out1229 in 0 0 nch W=0.5u L=0.18u
Mp1229 out1229 in vdd vdd pch W=1u L=0.18u
Cl1229 out1229 0 10f
Mn1230 out1230 in 0 0 nch W=0.5u L=0.18u
Mp1230 out1230 in vdd vdd pch W=1u L=0.18u
Cl1230 out1230 0 10f
Mn1231 out1231 in 0 0 nch W=0.5u L=0.18u
Mp1231 out1231 in vdd vdd pch W=1u L=0.18u
Cl1231 out1231 0 10f
Mn1232 out1232 in 0 0 nch W=0.5u L=0.18u
Mp1232 out1232 in vdd vdd pch W=1u L=0.18u
Cl1232 out1232 0 10f
Mn1233 out1233 in 0 0 nch W=0.5u L=0.18u
Mp1233 out1233 in vdd vdd pch W=1u L=0.18u
Cl1233 out1233 0 10f
Mn1234 out1234 in 0 0 nch W=0.5u L=0.18u
Mp1234 out1234 in vdd vdd pch W=1u L=0.18u
Cl1234 out1234 0 10f
Mn1235 out1235 in 0 0 nch W=0.5u L=0.18u
Mp1235 out1235 in vdd vdd pch W=1u L=0.18u
Cl1235 out1235 0 10f
Mn1236 out1236 in 0 0 nch W=0.5u L=0.18u
Mp1236 out1236 in vdd vdd pch W=1u L=0.18u
Cl1236 out1236 0 10f
Mn1237 out1237 in 0 0 nch W=0.5u L=0.18u
Mp1237 out1237 in vdd vdd pch W=1u L=0.18u
Cl1237 out1237 0 10f
Mn1238 out1238 in 0 0 nch W=0.5u L=0.18u
Mp1238 out1238 in vdd vdd pch W=1u L=0.18u
Cl1238 out1238 0 10f
Mn1239 out1239 in 0 0 nch W=0.5u L=0.18u
Mp1239 out1239 in vdd vdd pch W=1u L=0.18u
Cl1239 out1239 0 10f
Mn1240 out1240 in 0 0 nch W=0.5u L=0.18u
Mp1240 out1240 in vdd vdd pch W=1u L=0.18u
Cl1240 out1240 0 10f
Mn1241 out1241 in 0 0 nch W=0.5u L=0.18u
Mp1241 out1241 in vdd vdd pch W=1u L=0.18u
Cl1241 out1241 0 10f
Mn1242 out1242 in 0 0 nch W=0.5u L=0.18u
Mp1242 out1242 in vdd vdd pch W=1u L=0.18u
Cl1242 out1242 0 10f
Mn1243 out1243 in 0 0 nch W=0.5u L=0.18u
Mp1243 out1243 in vdd vdd pch W=1u L=0.18u
Cl1243 out1243 0 10f
Mn1244 out1244 in 0 0 nch W=0.5u L=0.18u
Mp1244 out1244 in vdd vdd pch W=1u L=0.18u
Cl1244 out1244 0 10f
Mn1245 out1245 in 0 0 nch W=0.5u L=0.18u
Mp1245 out1245 in vdd vdd pch W=1u L=0.18u
Cl1245 out1245 0 10f
Mn1246 out1246 in 0 0 nch W=0.5u L=0.18u
Mp1246 out1246 in vdd vdd pch W=1u L=0.18u
Cl1246 out1246 0 10f
Mn1247 out1247 in 0 0 nch W=0.5u L=0.18u
Mp1247 out1247 in vdd vdd pch W=1u L=0.18u
Cl1247 out1247 0 10f
Mn1248 out1248 in 0 0 nch W=0.5u L=0.18u
Mp1248 out1248 in vdd vdd pch W=1u L=0.18u
Cl1248 out1248 0 10f
Mn1249 out1249 in 0 0 nch W=0.5u L=0.18u
Mp1249 out1249 in vdd vdd pch W=1u L=0.18u
Cl1249 out1249 0 10f
Mn1250 out1250 in 0 0 nch W=0.5u L=0.18u
Mp1250 out1250 in vdd vdd pch W=1u L=0.18u
Cl1250 out1250 0 10f
Mn1251 out1251 in 0 0 nch W=0.5u L=0.18u
Mp1251 out1251 in vdd vdd pch W=1u L=0.18u
Cl1251 out1251 0 10f
Mn1252 out1252 in 0 0 nch W=0.5u L=0.18u
Mp1252 out1252 in vdd vdd pch W=1u L=0.18u
Cl1252 out1252 0 10f
Mn1253 out1253 in 0 0 nch W=0.5u L=0.18u
Mp1253 out1253 in vdd vdd pch W=1u L=0.18u
Cl1253 out1253 0 10f
Mn1254 out1254 in 0 0 nch W=0.5u L=0.18u
Mp1254 out1254 in vdd vdd pch W=1u L=0.18u
Cl1254 out1254 0 10f
Mn1255 out1255 in 0 0 nch W=0.5u L=0.18u
Mp1255 out1255 in vdd vdd pch W=1u L=0.18u
Cl1255 out1255 0 10f
Mn1256 out1256 in 0 0 nch W=0.5u L=0.18u
Mp1256 out1256 in vdd vdd pch W=1u L=0.18u
Cl1256 out1256 0 10f
Mn1257 out1257 in 0 0 nch W=0.5u L=0.18u
Mp1257 out1257 in vdd vdd pch W=1u L=0.18u
Cl1257 out1257 0 10f
Mn1258 out1258 in 0 0 nch W=0.5u L=0.18u
Mp1258 out1258 in vdd vdd pch W=1u L=0.18u
Cl1258 out1258 0 10f
Mn1259 out1259 in 0 0 nch W=0.5u L=0.18u
Mp1259 out1259 in vdd vdd pch W=1u L=0.18u
Cl1259 out1259 0 10f
Mn1260 out1260 in 0 0 nch W=0.5u L=0.18u
Mp1260 out1260 in vdd vdd pch W=1u L=0.18u
Cl1260 out1260 0 10f
Mn1261 out1261 in 0 0 nch W=0.5u L=0.18u
Mp1261 out1261 in vdd vdd pch W=1u L=0.18u
Cl1261 out1261 0 10f
Mn1262 out1262 in 0 0 nch W=0.5u L=0.18u
Mp1262 out1262 in vdd vdd pch W=1u L=0.18u
Cl1262 out1262 0 10f
Mn1263 out1263 in 0 0 nch W=0.5u L=0.18u
Mp1263 out1263 in vdd vdd pch W=1u L=0.18u
Cl1263 out1263 0 10f
Mn1264 out1264 in 0 0 nch W=0.5u L=0.18u
Mp1264 out1264 in vdd vdd pch W=1u L=0.18u
Cl1264 out1264 0 10f
Mn1265 out1265 in 0 0 nch W=0.5u L=0.18u
Mp1265 out1265 in vdd vdd pch W=1u L=0.18u
Cl1265 out1265 0 10f
Mn1266 out1266 in 0 0 nch W=0.5u L=0.18u
Mp1266 out1266 in vdd vdd pch W=1u L=0.18u
Cl1266 out1266 0 10f
Mn1267 out1267 in 0 0 nch W=0.5u L=0.18u
Mp1267 out1267 in vdd vdd pch W=1u L=0.18u
Cl1267 out1267 0 10f
Mn1268 out1268 in 0 0 nch W=0.5u L=0.18u
Mp1268 out1268 in vdd vdd pch W=1u L=0.18u
Cl1268 out1268 0 10f
Mn1269 out1269 in 0 0 nch W=0.5u L=0.18u
Mp1269 out1269 in vdd vdd pch W=1u L=0.18u
Cl1269 out1269 0 10f
Mn1270 out1270 in 0 0 nch W=0.5u L=0.18u
Mp1270 out1270 in vdd vdd pch W=1u L=0.18u
Cl1270 out1270 0 10f
Mn1271 out1271 in 0 0 nch W=0.5u L=0.18u
Mp1271 out1271 in vdd vdd pch W=1u L=0.18u
Cl1271 out1271 0 10f
Mn1272 out1272 in 0 0 nch W=0.5u L=0.18u
Mp1272 out1272 in vdd vdd pch W=1u L=0.18u
Cl1272 out1272 0 10f
Mn1273 out1273 in 0 0 nch W=0.5u L=0.18u
Mp1273 out1273 in vdd vdd pch W=1u L=0.18u
Cl1273 out1273 0 10f
Mn1274 out1274 in 0 0 nch W=0.5u L=0.18u
Mp1274 out1274 in vdd vdd pch W=1u L=0.18u
Cl1274 out1274 0 10f
Mn1275 out1275 in 0 0 nch W=0.5u L=0.18u
Mp1275 out1275 in vdd vdd pch W=1u L=0.18u
Cl1275 out1275 0 10f
Mn1276 out1276 in 0 0 nch W=0.5u L=0.18u
Mp1276 out1276 in vdd vdd pch W=1u L=0.18u
Cl1276 out1276 0 10f
Mn1277 out1277 in 0 0 nch W=0.5u L=0.18u
Mp1277 out1277 in vdd vdd pch W=1u L=0.18u
Cl1277 out1277 0 10f
Mn1278 out1278 in 0 0 nch W=0.5u L=0.18u
Mp1278 out1278 in vdd vdd pch W=1u L=0.18u
Cl1278 out1278 0 10f
Mn1279 out1279 in 0 0 nch W=0.5u L=0.18u
Mp1279 out1279 in vdd vdd pch W=1u L=0.18u
Cl1279 out1279 0 10f
Mn1280 out1280 in 0 0 nch W=0.5u L=0.18u
Mp1280 out1280 in vdd vdd pch W=1u L=0.18u
Cl1280 out1280 0 10f
Mn1281 out1281 in 0 0 nch W=0.5u L=0.18u
Mp1281 out1281 in vdd vdd pch W=1u L=0.18u
Cl1281 out1281 0 10f
Mn1282 out1282 in 0 0 nch W=0.5u L=0.18u
Mp1282 out1282 in vdd vdd pch W=1u L=0.18u
Cl1282 out1282 0 10f
Mn1283 out1283 in 0 0 nch W=0.5u L=0.18u
Mp1283 out1283 in vdd vdd pch W=1u L=0.18u
Cl1283 out1283 0 10f
Mn1284 out1284 in 0 0 nch W=0.5u L=0.18u
Mp1284 out1284 in vdd vdd pch W=1u L=0.18u
Cl1284 out1284 0 10f
Mn1285 out1285 in 0 0 nch W=0.5u L=0.18u
Mp1285 out1285 in vdd vdd pch W=1u L=0.18u
Cl1285 out1285 0 10f
Mn1286 out1286 in 0 0 nch W=0.5u L=0.18u
Mp1286 out1286 in vdd vdd pch W=1u L=0.18u
Cl1286 out1286 0 10f
Mn1287 out1287 in 0 0 nch W=0.5u L=0.18u
Mp1287 out1287 in vdd vdd pch W=1u L=0.18u
Cl1287 out1287 0 10f
Mn1288 out1288 in 0 0 nch W=0.5u L=0.18u
Mp1288 out1288 in vdd vdd pch W=1u L=0.18u
Cl1288 out1288 0 10f
Mn1289 out1289 in 0 0 nch W=0.5u L=0.18u
Mp1289 out1289 in vdd vdd pch W=1u L=0.18u
Cl1289 out1289 0 10f
Mn1290 out1290 in 0 0 nch W=0.5u L=0.18u
Mp1290 out1290 in vdd vdd pch W=1u L=0.18u
Cl1290 out1290 0 10f
Mn1291 out1291 in 0 0 nch W=0.5u L=0.18u
Mp1291 out1291 in vdd vdd pch W=1u L=0.18u
Cl1291 out1291 0 10f
Mn1292 out1292 in 0 0 nch W=0.5u L=0.18u
Mp1292 out1292 in vdd vdd pch W=1u L=0.18u
Cl1292 out1292 0 10f
Mn1293 out1293 in 0 0 nch W=0.5u L=0.18u
Mp1293 out1293 in vdd vdd pch W=1u L=0.18u
Cl1293 out1293 0 10f
Mn1294 out1294 in 0 0 nch W=0.5u L=0.18u
Mp1294 out1294 in vdd vdd pch W=1u L=0.18u
Cl1294 out1294 0 10f
Mn1295 out1295 in 0 0 nch W=0.5u L=0.18u
Mp1295 out1295 in vdd vdd pch W=1u L=0.18u
Cl1295 out1295 0 10f
Mn1296 out1296 in 0 0 nch W=0.5u L=0.18u
Mp1296 out1296 in vdd vdd pch W=1u L=0.18u
Cl1296 out1296 0 10f
Mn1297 out1297 in 0 0 nch W=0.5u L=0.18u
Mp1297 out1297 in vdd vdd pch W=1u L=0.18u
Cl1297 out1297 0 10f
Mn1298 out1298 in 0 0 nch W=0.5u L=0.18u
Mp1298 out1298 in vdd vdd pch W=1u L=0.18u
Cl1298 out1298 0 10f
Mn1299 out1299 in 0 0 nch W=0.5u L=0.18u
Mp1299 out1299 in vdd vdd pch W=1u L=0.18u
Cl1299 out1299 0 10f
Mn1300 out1300 in 0 0 nch W=0.5u L=0.18u
Mp1300 out1300 in vdd vdd pch W=1u L=0.18u
Cl1300 out1300 0 10f
Mn1301 out1301 in 0 0 nch W=0.5u L=0.18u
Mp1301 out1301 in vdd vdd pch W=1u L=0.18u
Cl1301 out1301 0 10f
Mn1302 out1302 in 0 0 nch W=0.5u L=0.18u
Mp1302 out1302 in vdd vdd pch W=1u L=0.18u
Cl1302 out1302 0 10f
Mn1303 out1303 in 0 0 nch W=0.5u L=0.18u
Mp1303 out1303 in vdd vdd pch W=1u L=0.18u
Cl1303 out1303 0 10f
Mn1304 out1304 in 0 0 nch W=0.5u L=0.18u
Mp1304 out1304 in vdd vdd pch W=1u L=0.18u
Cl1304 out1304 0 10f
Mn1305 out1305 in 0 0 nch W=0.5u L=0.18u
Mp1305 out1305 in vdd vdd pch W=1u L=0.18u
Cl1305 out1305 0 10f
Mn1306 out1306 in 0 0 nch W=0.5u L=0.18u
Mp1306 out1306 in vdd vdd pch W=1u L=0.18u
Cl1306 out1306 0 10f
Mn1307 out1307 in 0 0 nch W=0.5u L=0.18u
Mp1307 out1307 in vdd vdd pch W=1u L=0.18u
Cl1307 out1307 0 10f
Mn1308 out1308 in 0 0 nch W=0.5u L=0.18u
Mp1308 out1308 in vdd vdd pch W=1u L=0.18u
Cl1308 out1308 0 10f
Mn1309 out1309 in 0 0 nch W=0.5u L=0.18u
Mp1309 out1309 in vdd vdd pch W=1u L=0.18u
Cl1309 out1309 0 10f
Mn1310 out1310 in 0 0 nch W=0.5u L=0.18u
Mp1310 out1310 in vdd vdd pch W=1u L=0.18u
Cl1310 out1310 0 10f
Mn1311 out1311 in 0 0 nch W=0.5u L=0.18u
Mp1311 out1311 in vdd vdd pch W=1u L=0.18u
Cl1311 out1311 0 10f
Mn1312 out1312 in 0 0 nch W=0.5u L=0.18u
Mp1312 out1312 in vdd vdd pch W=1u L=0.18u
Cl1312 out1312 0 10f
Mn1313 out1313 in 0 0 nch W=0.5u L=0.18u
Mp1313 out1313 in vdd vdd pch W=1u L=0.18u
Cl1313 out1313 0 10f
Mn1314 out1314 in 0 0 nch W=0.5u L=0.18u
Mp1314 out1314 in vdd vdd pch W=1u L=0.18u
Cl1314 out1314 0 10f
Mn1315 out1315 in 0 0 nch W=0.5u L=0.18u
Mp1315 out1315 in vdd vdd pch W=1u L=0.18u
Cl1315 out1315 0 10f
Mn1316 out1316 in 0 0 nch W=0.5u L=0.18u
Mp1316 out1316 in vdd vdd pch W=1u L=0.18u
Cl1316 out1316 0 10f
Mn1317 out1317 in 0 0 nch W=0.5u L=0.18u
Mp1317 out1317 in vdd vdd pch W=1u L=0.18u
Cl1317 out1317 0 10f
Mn1318 out1318 in 0 0 nch W=0.5u L=0.18u
Mp1318 out1318 in vdd vdd pch W=1u L=0.18u
Cl1318 out1318 0 10f
Mn1319 out1319 in 0 0 nch W=0.5u L=0.18u
Mp1319 out1319 in vdd vdd pch W=1u L=0.18u
Cl1319 out1319 0 10f
Mn1320 out1320 in 0 0 nch W=0.5u L=0.18u
Mp1320 out1320 in vdd vdd pch W=1u L=0.18u
Cl1320 out1320 0 10f
Mn1321 out1321 in 0 0 nch W=0.5u L=0.18u
Mp1321 out1321 in vdd vdd pch W=1u L=0.18u
Cl1321 out1321 0 10f
Mn1322 out1322 in 0 0 nch W=0.5u L=0.18u
Mp1322 out1322 in vdd vdd pch W=1u L=0.18u
Cl1322 out1322 0 10f
Mn1323 out1323 in 0 0 nch W=0.5u L=0.18u
Mp1323 out1323 in vdd vdd pch W=1u L=0.18u
Cl1323 out1323 0 10f
Mn1324 out1324 in 0 0 nch W=0.5u L=0.18u
Mp1324 out1324 in vdd vdd pch W=1u L=0.18u
Cl1324 out1324 0 10f
Mn1325 out1325 in 0 0 nch W=0.5u L=0.18u
Mp1325 out1325 in vdd vdd pch W=1u L=0.18u
Cl1325 out1325 0 10f
Mn1326 out1326 in 0 0 nch W=0.5u L=0.18u
Mp1326 out1326 in vdd vdd pch W=1u L=0.18u
Cl1326 out1326 0 10f
Mn1327 out1327 in 0 0 nch W=0.5u L=0.18u
Mp1327 out1327 in vdd vdd pch W=1u L=0.18u
Cl1327 out1327 0 10f
Mn1328 out1328 in 0 0 nch W=0.5u L=0.18u
Mp1328 out1328 in vdd vdd pch W=1u L=0.18u
Cl1328 out1328 0 10f
Mn1329 out1329 in 0 0 nch W=0.5u L=0.18u
Mp1329 out1329 in vdd vdd pch W=1u L=0.18u
Cl1329 out1329 0 10f
Mn1330 out1330 in 0 0 nch W=0.5u L=0.18u
Mp1330 out1330 in vdd vdd pch W=1u L=0.18u
Cl1330 out1330 0 10f
Mn1331 out1331 in 0 0 nch W=0.5u L=0.18u
Mp1331 out1331 in vdd vdd pch W=1u L=0.18u
Cl1331 out1331 0 10f
Mn1332 out1332 in 0 0 nch W=0.5u L=0.18u
Mp1332 out1332 in vdd vdd pch W=1u L=0.18u
Cl1332 out1332 0 10f
Mn1333 out1333 in 0 0 nch W=0.5u L=0.18u
Mp1333 out1333 in vdd vdd pch W=1u L=0.18u
Cl1333 out1333 0 10f
Mn1334 out1334 in 0 0 nch W=0.5u L=0.18u
Mp1334 out1334 in vdd vdd pch W=1u L=0.18u
Cl1334 out1334 0 10f
Mn1335 out1335 in 0 0 nch W=0.5u L=0.18u
Mp1335 out1335 in vdd vdd pch W=1u L=0.18u
Cl1335 out1335 0 10f
Mn1336 out1336 in 0 0 nch W=0.5u L=0.18u
Mp1336 out1336 in vdd vdd pch W=1u L=0.18u
Cl1336 out1336 0 10f
Mn1337 out1337 in 0 0 nch W=0.5u L=0.18u
Mp1337 out1337 in vdd vdd pch W=1u L=0.18u
Cl1337 out1337 0 10f
Mn1338 out1338 in 0 0 nch W=0.5u L=0.18u
Mp1338 out1338 in vdd vdd pch W=1u L=0.18u
Cl1338 out1338 0 10f
Mn1339 out1339 in 0 0 nch W=0.5u L=0.18u
Mp1339 out1339 in vdd vdd pch W=1u L=0.18u
Cl1339 out1339 0 10f
Mn1340 out1340 in 0 0 nch W=0.5u L=0.18u
Mp1340 out1340 in vdd vdd pch W=1u L=0.18u
Cl1340 out1340 0 10f
Mn1341 out1341 in 0 0 nch W=0.5u L=0.18u
Mp1341 out1341 in vdd vdd pch W=1u L=0.18u
Cl1341 out1341 0 10f
Mn1342 out1342 in 0 0 nch W=0.5u L=0.18u
Mp1342 out1342 in vdd vdd pch W=1u L=0.18u
Cl1342 out1342 0 10f
Mn1343 out1343 in 0 0 nch W=0.5u L=0.18u
Mp1343 out1343 in vdd vdd pch W=1u L=0.18u
Cl1343 out1343 0 10f
Mn1344 out1344 in 0 0 nch W=0.5u L=0.18u
Mp1344 out1344 in vdd vdd pch W=1u L=0.18u
Cl1344 out1344 0 10f
Mn1345 out1345 in 0 0 nch W=0.5u L=0.18u
Mp1345 out1345 in vdd vdd pch W=1u L=0.18u
Cl1345 out1345 0 10f
Mn1346 out1346 in 0 0 nch W=0.5u L=0.18u
Mp1346 out1346 in vdd vdd pch W=1u L=0.18u
Cl1346 out1346 0 10f
Mn1347 out1347 in 0 0 nch W=0.5u L=0.18u
Mp1347 out1347 in vdd vdd pch W=1u L=0.18u
Cl1347 out1347 0 10f
Mn1348 out1348 in 0 0 nch W=0.5u L=0.18u
Mp1348 out1348 in vdd vdd pch W=1u L=0.18u
Cl1348 out1348 0 10f
Mn1349 out1349 in 0 0 nch W=0.5u L=0.18u
Mp1349 out1349 in vdd vdd pch W=1u L=0.18u
Cl1349 out1349 0 10f
Mn1350 out1350 in 0 0 nch W=0.5u L=0.18u
Mp1350 out1350 in vdd vdd pch W=1u L=0.18u
Cl1350 out1350 0 10f
Mn1351 out1351 in 0 0 nch W=0.5u L=0.18u
Mp1351 out1351 in vdd vdd pch W=1u L=0.18u
Cl1351 out1351 0 10f
Mn1352 out1352 in 0 0 nch W=0.5u L=0.18u
Mp1352 out1352 in vdd vdd pch W=1u L=0.18u
Cl1352 out1352 0 10f
Mn1353 out1353 in 0 0 nch W=0.5u L=0.18u
Mp1353 out1353 in vdd vdd pch W=1u L=0.18u
Cl1353 out1353 0 10f
Mn1354 out1354 in 0 0 nch W=0.5u L=0.18u
Mp1354 out1354 in vdd vdd pch W=1u L=0.18u
Cl1354 out1354 0 10f
Mn1355 out1355 in 0 0 nch W=0.5u L=0.18u
Mp1355 out1355 in vdd vdd pch W=1u L=0.18u
Cl1355 out1355 0 10f
Mn1356 out1356 in 0 0 nch W=0.5u L=0.18u
Mp1356 out1356 in vdd vdd pch W=1u L=0.18u
Cl1356 out1356 0 10f
Mn1357 out1357 in 0 0 nch W=0.5u L=0.18u
Mp1357 out1357 in vdd vdd pch W=1u L=0.18u
Cl1357 out1357 0 10f
Mn1358 out1358 in 0 0 nch W=0.5u L=0.18u
Mp1358 out1358 in vdd vdd pch W=1u L=0.18u
Cl1358 out1358 0 10f
Mn1359 out1359 in 0 0 nch W=0.5u L=0.18u
Mp1359 out1359 in vdd vdd pch W=1u L=0.18u
Cl1359 out1359 0 10f
Mn1360 out1360 in 0 0 nch W=0.5u L=0.18u
Mp1360 out1360 in vdd vdd pch W=1u L=0.18u
Cl1360 out1360 0 10f
Mn1361 out1361 in 0 0 nch W=0.5u L=0.18u
Mp1361 out1361 in vdd vdd pch W=1u L=0.18u
Cl1361 out1361 0 10f
Mn1362 out1362 in 0 0 nch W=0.5u L=0.18u
Mp1362 out1362 in vdd vdd pch W=1u L=0.18u
Cl1362 out1362 0 10f
Mn1363 out1363 in 0 0 nch W=0.5u L=0.18u
Mp1363 out1363 in vdd vdd pch W=1u L=0.18u
Cl1363 out1363 0 10f
Mn1364 out1364 in 0 0 nch W=0.5u L=0.18u
Mp1364 out1364 in vdd vdd pch W=1u L=0.18u
Cl1364 out1364 0 10f
Mn1365 out1365 in 0 0 nch W=0.5u L=0.18u
Mp1365 out1365 in vdd vdd pch W=1u L=0.18u
Cl1365 out1365 0 10f
Mn1366 out1366 in 0 0 nch W=0.5u L=0.18u
Mp1366 out1366 in vdd vdd pch W=1u L=0.18u
Cl1366 out1366 0 10f
Mn1367 out1367 in 0 0 nch W=0.5u L=0.18u
Mp1367 out1367 in vdd vdd pch W=1u L=0.18u
Cl1367 out1367 0 10f
Mn1368 out1368 in 0 0 nch W=0.5u L=0.18u
Mp1368 out1368 in vdd vdd pch W=1u L=0.18u
Cl1368 out1368 0 10f
Mn1369 out1369 in 0 0 nch W=0.5u L=0.18u
Mp1369 out1369 in vdd vdd pch W=1u L=0.18u
Cl1369 out1369 0 10f
Mn1370 out1370 in 0 0 nch W=0.5u L=0.18u
Mp1370 out1370 in vdd vdd pch W=1u L=0.18u
Cl1370 out1370 0 10f
Mn1371 out1371 in 0 0 nch W=0.5u L=0.18u
Mp1371 out1371 in vdd vdd pch W=1u L=0.18u
Cl1371 out1371 0 10f
Mn1372 out1372 in 0 0 nch W=0.5u L=0.18u
Mp1372 out1372 in vdd vdd pch W=1u L=0.18u
Cl1372 out1372 0 10f
Mn1373 out1373 in 0 0 nch W=0.5u L=0.18u
Mp1373 out1373 in vdd vdd pch W=1u L=0.18u
Cl1373 out1373 0 10f
Mn1374 out1374 in 0 0 nch W=0.5u L=0.18u
Mp1374 out1374 in vdd vdd pch W=1u L=0.18u
Cl1374 out1374 0 10f
Mn1375 out1375 in 0 0 nch W=0.5u L=0.18u
Mp1375 out1375 in vdd vdd pch W=1u L=0.18u
Cl1375 out1375 0 10f
Mn1376 out1376 in 0 0 nch W=0.5u L=0.18u
Mp1376 out1376 in vdd vdd pch W=1u L=0.18u
Cl1376 out1376 0 10f
Mn1377 out1377 in 0 0 nch W=0.5u L=0.18u
Mp1377 out1377 in vdd vdd pch W=1u L=0.18u
Cl1377 out1377 0 10f
Mn1378 out1378 in 0 0 nch W=0.5u L=0.18u
Mp1378 out1378 in vdd vdd pch W=1u L=0.18u
Cl1378 out1378 0 10f
Mn1379 out1379 in 0 0 nch W=0.5u L=0.18u
Mp1379 out1379 in vdd vdd pch W=1u L=0.18u
Cl1379 out1379 0 10f
Mn1380 out1380 in 0 0 nch W=0.5u L=0.18u
Mp1380 out1380 in vdd vdd pch W=1u L=0.18u
Cl1380 out1380 0 10f
Mn1381 out1381 in 0 0 nch W=0.5u L=0.18u
Mp1381 out1381 in vdd vdd pch W=1u L=0.18u
Cl1381 out1381 0 10f
Mn1382 out1382 in 0 0 nch W=0.5u L=0.18u
Mp1382 out1382 in vdd vdd pch W=1u L=0.18u
Cl1382 out1382 0 10f
Mn1383 out1383 in 0 0 nch W=0.5u L=0.18u
Mp1383 out1383 in vdd vdd pch W=1u L=0.18u
Cl1383 out1383 0 10f
Mn1384 out1384 in 0 0 nch W=0.5u L=0.18u
Mp1384 out1384 in vdd vdd pch W=1u L=0.18u
Cl1384 out1384 0 10f
Mn1385 out1385 in 0 0 nch W=0.5u L=0.18u
Mp1385 out1385 in vdd vdd pch W=1u L=0.18u
Cl1385 out1385 0 10f
Mn1386 out1386 in 0 0 nch W=0.5u L=0.18u
Mp1386 out1386 in vdd vdd pch W=1u L=0.18u
Cl1386 out1386 0 10f
Mn1387 out1387 in 0 0 nch W=0.5u L=0.18u
Mp1387 out1387 in vdd vdd pch W=1u L=0.18u
Cl1387 out1387 0 10f
Mn1388 out1388 in 0 0 nch W=0.5u L=0.18u
Mp1388 out1388 in vdd vdd pch W=1u L=0.18u
Cl1388 out1388 0 10f
Mn1389 out1389 in 0 0 nch W=0.5u L=0.18u
Mp1389 out1389 in vdd vdd pch W=1u L=0.18u
Cl1389 out1389 0 10f
Mn1390 out1390 in 0 0 nch W=0.5u L=0.18u
Mp1390 out1390 in vdd vdd pch W=1u L=0.18u
Cl1390 out1390 0 10f
Mn1391 out1391 in 0 0 nch W=0.5u L=0.18u
Mp1391 out1391 in vdd vdd pch W=1u L=0.18u
Cl1391 out1391 0 10f
Mn1392 out1392 in 0 0 nch W=0.5u L=0.18u
Mp1392 out1392 in vdd vdd pch W=1u L=0.18u
Cl1392 out1392 0 10f
Mn1393 out1393 in 0 0 nch W=0.5u L=0.18u
Mp1393 out1393 in vdd vdd pch W=1u L=0.18u
Cl1393 out1393 0 10f
Mn1394 out1394 in 0 0 nch W=0.5u L=0.18u
Mp1394 out1394 in vdd vdd pch W=1u L=0.18u
Cl1394 out1394 0 10f
Mn1395 out1395 in 0 0 nch W=0.5u L=0.18u
Mp1395 out1395 in vdd vdd pch W=1u L=0.18u
Cl1395 out1395 0 10f
Mn1396 out1396 in 0 0 nch W=0.5u L=0.18u
Mp1396 out1396 in vdd vdd pch W=1u L=0.18u
Cl1396 out1396 0 10f
Mn1397 out1397 in 0 0 nch W=0.5u L=0.18u
Mp1397 out1397 in vdd vdd pch W=1u L=0.18u
Cl1397 out1397 0 10f
Mn1398 out1398 in 0 0 nch W=0.5u L=0.18u
Mp1398 out1398 in vdd vdd pch W=1u L=0.18u
Cl1398 out1398 0 10f
Mn1399 out1399 in 0 0 nch W=0.5u L=0.18u
Mp1399 out1399 in vdd vdd pch W=1u L=0.18u
Cl1399 out1399 0 10f
Mn1400 out1400 in 0 0 nch W=0.5u L=0.18u
Mp1400 out1400 in vdd vdd pch W=1u L=0.18u
Cl1400 out1400 0 10f
Mn1401 out1401 in 0 0 nch W=0.5u L=0.18u
Mp1401 out1401 in vdd vdd pch W=1u L=0.18u
Cl1401 out1401 0 10f
Mn1402 out1402 in 0 0 nch W=0.5u L=0.18u
Mp1402 out1402 in vdd vdd pch W=1u L=0.18u
Cl1402 out1402 0 10f
Mn1403 out1403 in 0 0 nch W=0.5u L=0.18u
Mp1403 out1403 in vdd vdd pch W=1u L=0.18u
Cl1403 out1403 0 10f
Mn1404 out1404 in 0 0 nch W=0.5u L=0.18u
Mp1404 out1404 in vdd vdd pch W=1u L=0.18u
Cl1404 out1404 0 10f
Mn1405 out1405 in 0 0 nch W=0.5u L=0.18u
Mp1405 out1405 in vdd vdd pch W=1u L=0.18u
Cl1405 out1405 0 10f
Mn1406 out1406 in 0 0 nch W=0.5u L=0.18u
Mp1406 out1406 in vdd vdd pch W=1u L=0.18u
Cl1406 out1406 0 10f
Mn1407 out1407 in 0 0 nch W=0.5u L=0.18u
Mp1407 out1407 in vdd vdd pch W=1u L=0.18u
Cl1407 out1407 0 10f
Mn1408 out1408 in 0 0 nch W=0.5u L=0.18u
Mp1408 out1408 in vdd vdd pch W=1u L=0.18u
Cl1408 out1408 0 10f
Mn1409 out1409 in 0 0 nch W=0.5u L=0.18u
Mp1409 out1409 in vdd vdd pch W=1u L=0.18u
Cl1409 out1409 0 10f
Mn1410 out1410 in 0 0 nch W=0.5u L=0.18u
Mp1410 out1410 in vdd vdd pch W=1u L=0.18u
Cl1410 out1410 0 10f
Mn1411 out1411 in 0 0 nch W=0.5u L=0.18u
Mp1411 out1411 in vdd vdd pch W=1u L=0.18u
Cl1411 out1411 0 10f
Mn1412 out1412 in 0 0 nch W=0.5u L=0.18u
Mp1412 out1412 in vdd vdd pch W=1u L=0.18u
Cl1412 out1412 0 10f
Mn1413 out1413 in 0 0 nch W=0.5u L=0.18u
Mp1413 out1413 in vdd vdd pch W=1u L=0.18u
Cl1413 out1413 0 10f
Mn1414 out1414 in 0 0 nch W=0.5u L=0.18u
Mp1414 out1414 in vdd vdd pch W=1u L=0.18u
Cl1414 out1414 0 10f
Mn1415 out1415 in 0 0 nch W=0.5u L=0.18u
Mp1415 out1415 in vdd vdd pch W=1u L=0.18u
Cl1415 out1415 0 10f
Mn1416 out1416 in 0 0 nch W=0.5u L=0.18u
Mp1416 out1416 in vdd vdd pch W=1u L=0.18u
Cl1416 out1416 0 10f
Mn1417 out1417 in 0 0 nch W=0.5u L=0.18u
Mp1417 out1417 in vdd vdd pch W=1u L=0.18u
Cl1417 out1417 0 10f
Mn1418 out1418 in 0 0 nch W=0.5u L=0.18u
Mp1418 out1418 in vdd vdd pch W=1u L=0.18u
Cl1418 out1418 0 10f
Mn1419 out1419 in 0 0 nch W=0.5u L=0.18u
Mp1419 out1419 in vdd vdd pch W=1u L=0.18u
Cl1419 out1419 0 10f
Mn1420 out1420 in 0 0 nch W=0.5u L=0.18u
Mp1420 out1420 in vdd vdd pch W=1u L=0.18u
Cl1420 out1420 0 10f
Mn1421 out1421 in 0 0 nch W=0.5u L=0.18u
Mp1421 out1421 in vdd vdd pch W=1u L=0.18u
Cl1421 out1421 0 10f
Mn1422 out1422 in 0 0 nch W=0.5u L=0.18u
Mp1422 out1422 in vdd vdd pch W=1u L=0.18u
Cl1422 out1422 0 10f
Mn1423 out1423 in 0 0 nch W=0.5u L=0.18u
Mp1423 out1423 in vdd vdd pch W=1u L=0.18u
Cl1423 out1423 0 10f
Mn1424 out1424 in 0 0 nch W=0.5u L=0.18u
Mp1424 out1424 in vdd vdd pch W=1u L=0.18u
Cl1424 out1424 0 10f
Mn1425 out1425 in 0 0 nch W=0.5u L=0.18u
Mp1425 out1425 in vdd vdd pch W=1u L=0.18u
Cl1425 out1425 0 10f
Mn1426 out1426 in 0 0 nch W=0.5u L=0.18u
Mp1426 out1426 in vdd vdd pch W=1u L=0.18u
Cl1426 out1426 0 10f
Mn1427 out1427 in 0 0 nch W=0.5u L=0.18u
Mp1427 out1427 in vdd vdd pch W=1u L=0.18u
Cl1427 out1427 0 10f
Mn1428 out1428 in 0 0 nch W=0.5u L=0.18u
Mp1428 out1428 in vdd vdd pch W=1u L=0.18u
Cl1428 out1428 0 10f
Mn1429 out1429 in 0 0 nch W=0.5u L=0.18u
Mp1429 out1429 in vdd vdd pch W=1u L=0.18u
Cl1429 out1429 0 10f
Mn1430 out1430 in 0 0 nch W=0.5u L=0.18u
Mp1430 out1430 in vdd vdd pch W=1u L=0.18u
Cl1430 out1430 0 10f
Mn1431 out1431 in 0 0 nch W=0.5u L=0.18u
Mp1431 out1431 in vdd vdd pch W=1u L=0.18u
Cl1431 out1431 0 10f
Mn1432 out1432 in 0 0 nch W=0.5u L=0.18u
Mp1432 out1432 in vdd vdd pch W=1u L=0.18u
Cl1432 out1432 0 10f
Mn1433 out1433 in 0 0 nch W=0.5u L=0.18u
Mp1433 out1433 in vdd vdd pch W=1u L=0.18u
Cl1433 out1433 0 10f
Mn1434 out1434 in 0 0 nch W=0.5u L=0.18u
Mp1434 out1434 in vdd vdd pch W=1u L=0.18u
Cl1434 out1434 0 10f
Mn1435 out1435 in 0 0 nch W=0.5u L=0.18u
Mp1435 out1435 in vdd vdd pch W=1u L=0.18u
Cl1435 out1435 0 10f
Mn1436 out1436 in 0 0 nch W=0.5u L=0.18u
Mp1436 out1436 in vdd vdd pch W=1u L=0.18u
Cl1436 out1436 0 10f
Mn1437 out1437 in 0 0 nch W=0.5u L=0.18u
Mp1437 out1437 in vdd vdd pch W=1u L=0.18u
Cl1437 out1437 0 10f
Mn1438 out1438 in 0 0 nch W=0.5u L=0.18u
Mp1438 out1438 in vdd vdd pch W=1u L=0.18u
Cl1438 out1438 0 10f
Mn1439 out1439 in 0 0 nch W=0.5u L=0.18u
Mp1439 out1439 in vdd vdd pch W=1u L=0.18u
Cl1439 out1439 0 10f
Mn1440 out1440 in 0 0 nch W=0.5u L=0.18u
Mp1440 out1440 in vdd vdd pch W=1u L=0.18u
Cl1440 out1440 0 10f
Mn1441 out1441 in 0 0 nch W=0.5u L=0.18u
Mp1441 out1441 in vdd vdd pch W=1u L=0.18u
Cl1441 out1441 0 10f
Mn1442 out1442 in 0 0 nch W=0.5u L=0.18u
Mp1442 out1442 in vdd vdd pch W=1u L=0.18u
Cl1442 out1442 0 10f
Mn1443 out1443 in 0 0 nch W=0.5u L=0.18u
Mp1443 out1443 in vdd vdd pch W=1u L=0.18u
Cl1443 out1443 0 10f
Mn1444 out1444 in 0 0 nch W=0.5u L=0.18u
Mp1444 out1444 in vdd vdd pch W=1u L=0.18u
Cl1444 out1444 0 10f
Mn1445 out1445 in 0 0 nch W=0.5u L=0.18u
Mp1445 out1445 in vdd vdd pch W=1u L=0.18u
Cl1445 out1445 0 10f
Mn1446 out1446 in 0 0 nch W=0.5u L=0.18u
Mp1446 out1446 in vdd vdd pch W=1u L=0.18u
Cl1446 out1446 0 10f
Mn1447 out1447 in 0 0 nch W=0.5u L=0.18u
Mp1447 out1447 in vdd vdd pch W=1u L=0.18u
Cl1447 out1447 0 10f
Mn1448 out1448 in 0 0 nch W=0.5u L=0.18u
Mp1448 out1448 in vdd vdd pch W=1u L=0.18u
Cl1448 out1448 0 10f
Mn1449 out1449 in 0 0 nch W=0.5u L=0.18u
Mp1449 out1449 in vdd vdd pch W=1u L=0.18u
Cl1449 out1449 0 10f
Mn1450 out1450 in 0 0 nch W=0.5u L=0.18u
Mp1450 out1450 in vdd vdd pch W=1u L=0.18u
Cl1450 out1450 0 10f
Mn1451 out1451 in 0 0 nch W=0.5u L=0.18u
Mp1451 out1451 in vdd vdd pch W=1u L=0.18u
Cl1451 out1451 0 10f
Mn1452 out1452 in 0 0 nch W=0.5u L=0.18u
Mp1452 out1452 in vdd vdd pch W=1u L=0.18u
Cl1452 out1452 0 10f
Mn1453 out1453 in 0 0 nch W=0.5u L=0.18u
Mp1453 out1453 in vdd vdd pch W=1u L=0.18u
Cl1453 out1453 0 10f
Mn1454 out1454 in 0 0 nch W=0.5u L=0.18u
Mp1454 out1454 in vdd vdd pch W=1u L=0.18u
Cl1454 out1454 0 10f
Mn1455 out1455 in 0 0 nch W=0.5u L=0.18u
Mp1455 out1455 in vdd vdd pch W=1u L=0.18u
Cl1455 out1455 0 10f
Mn1456 out1456 in 0 0 nch W=0.5u L=0.18u
Mp1456 out1456 in vdd vdd pch W=1u L=0.18u
Cl1456 out1456 0 10f
Mn1457 out1457 in 0 0 nch W=0.5u L=0.18u
Mp1457 out1457 in vdd vdd pch W=1u L=0.18u
Cl1457 out1457 0 10f
Mn1458 out1458 in 0 0 nch W=0.5u L=0.18u
Mp1458 out1458 in vdd vdd pch W=1u L=0.18u
Cl1458 out1458 0 10f
Mn1459 out1459 in 0 0 nch W=0.5u L=0.18u
Mp1459 out1459 in vdd vdd pch W=1u L=0.18u
Cl1459 out1459 0 10f
Mn1460 out1460 in 0 0 nch W=0.5u L=0.18u
Mp1460 out1460 in vdd vdd pch W=1u L=0.18u
Cl1460 out1460 0 10f
Mn1461 out1461 in 0 0 nch W=0.5u L=0.18u
Mp1461 out1461 in vdd vdd pch W=1u L=0.18u
Cl1461 out1461 0 10f
Mn1462 out1462 in 0 0 nch W=0.5u L=0.18u
Mp1462 out1462 in vdd vdd pch W=1u L=0.18u
Cl1462 out1462 0 10f
Mn1463 out1463 in 0 0 nch W=0.5u L=0.18u
Mp1463 out1463 in vdd vdd pch W=1u L=0.18u
Cl1463 out1463 0 10f
Mn1464 out1464 in 0 0 nch W=0.5u L=0.18u
Mp1464 out1464 in vdd vdd pch W=1u L=0.18u
Cl1464 out1464 0 10f
Mn1465 out1465 in 0 0 nch W=0.5u L=0.18u
Mp1465 out1465 in vdd vdd pch W=1u L=0.18u
Cl1465 out1465 0 10f
Mn1466 out1466 in 0 0 nch W=0.5u L=0.18u
Mp1466 out1466 in vdd vdd pch W=1u L=0.18u
Cl1466 out1466 0 10f
Mn1467 out1467 in 0 0 nch W=0.5u L=0.18u
Mp1467 out1467 in vdd vdd pch W=1u L=0.18u
Cl1467 out1467 0 10f
Mn1468 out1468 in 0 0 nch W=0.5u L=0.18u
Mp1468 out1468 in vdd vdd pch W=1u L=0.18u
Cl1468 out1468 0 10f
Mn1469 out1469 in 0 0 nch W=0.5u L=0.18u
Mp1469 out1469 in vdd vdd pch W=1u L=0.18u
Cl1469 out1469 0 10f
Mn1470 out1470 in 0 0 nch W=0.5u L=0.18u
Mp1470 out1470 in vdd vdd pch W=1u L=0.18u
Cl1470 out1470 0 10f
Mn1471 out1471 in 0 0 nch W=0.5u L=0.18u
Mp1471 out1471 in vdd vdd pch W=1u L=0.18u
Cl1471 out1471 0 10f
Mn1472 out1472 in 0 0 nch W=0.5u L=0.18u
Mp1472 out1472 in vdd vdd pch W=1u L=0.18u
Cl1472 out1472 0 10f
Mn1473 out1473 in 0 0 nch W=0.5u L=0.18u
Mp1473 out1473 in vdd vdd pch W=1u L=0.18u
Cl1473 out1473 0 10f
Mn1474 out1474 in 0 0 nch W=0.5u L=0.18u
Mp1474 out1474 in vdd vdd pch W=1u L=0.18u
Cl1474 out1474 0 10f
Mn1475 out1475 in 0 0 nch W=0.5u L=0.18u
Mp1475 out1475 in vdd vdd pch W=1u L=0.18u
Cl1475 out1475 0 10f
Mn1476 out1476 in 0 0 nch W=0.5u L=0.18u
Mp1476 out1476 in vdd vdd pch W=1u L=0.18u
Cl1476 out1476 0 10f
Mn1477 out1477 in 0 0 nch W=0.5u L=0.18u
Mp1477 out1477 in vdd vdd pch W=1u L=0.18u
Cl1477 out1477 0 10f
Mn1478 out1478 in 0 0 nch W=0.5u L=0.18u
Mp1478 out1478 in vdd vdd pch W=1u L=0.18u
Cl1478 out1478 0 10f
Mn1479 out1479 in 0 0 nch W=0.5u L=0.18u
Mp1479 out1479 in vdd vdd pch W=1u L=0.18u
Cl1479 out1479 0 10f
Mn1480 out1480 in 0 0 nch W=0.5u L=0.18u
Mp1480 out1480 in vdd vdd pch W=1u L=0.18u
Cl1480 out1480 0 10f
Mn1481 out1481 in 0 0 nch W=0.5u L=0.18u
Mp1481 out1481 in vdd vdd pch W=1u L=0.18u
Cl1481 out1481 0 10f
Mn1482 out1482 in 0 0 nch W=0.5u L=0.18u
Mp1482 out1482 in vdd vdd pch W=1u L=0.18u
Cl1482 out1482 0 10f
Mn1483 out1483 in 0 0 nch W=0.5u L=0.18u
Mp1483 out1483 in vdd vdd pch W=1u L=0.18u
Cl1483 out1483 0 10f
Mn1484 out1484 in 0 0 nch W=0.5u L=0.18u
Mp1484 out1484 in vdd vdd pch W=1u L=0.18u
Cl1484 out1484 0 10f
Mn1485 out1485 in 0 0 nch W=0.5u L=0.18u
Mp1485 out1485 in vdd vdd pch W=1u L=0.18u
Cl1485 out1485 0 10f
Mn1486 out1486 in 0 0 nch W=0.5u L=0.18u
Mp1486 out1486 in vdd vdd pch W=1u L=0.18u
Cl1486 out1486 0 10f
Mn1487 out1487 in 0 0 nch W=0.5u L=0.18u
Mp1487 out1487 in vdd vdd pch W=1u L=0.18u
Cl1487 out1487 0 10f
Mn1488 out1488 in 0 0 nch W=0.5u L=0.18u
Mp1488 out1488 in vdd vdd pch W=1u L=0.18u
Cl1488 out1488 0 10f
Mn1489 out1489 in 0 0 nch W=0.5u L=0.18u
Mp1489 out1489 in vdd vdd pch W=1u L=0.18u
Cl1489 out1489 0 10f
Mn1490 out1490 in 0 0 nch W=0.5u L=0.18u
Mp1490 out1490 in vdd vdd pch W=1u L=0.18u
Cl1490 out1490 0 10f
Mn1491 out1491 in 0 0 nch W=0.5u L=0.18u
Mp1491 out1491 in vdd vdd pch W=1u L=0.18u
Cl1491 out1491 0 10f
Mn1492 out1492 in 0 0 nch W=0.5u L=0.18u
Mp1492 out1492 in vdd vdd pch W=1u L=0.18u
Cl1492 out1492 0 10f
Mn1493 out1493 in 0 0 nch W=0.5u L=0.18u
Mp1493 out1493 in vdd vdd pch W=1u L=0.18u
Cl1493 out1493 0 10f
Mn1494 out1494 in 0 0 nch W=0.5u L=0.18u
Mp1494 out1494 in vdd vdd pch W=1u L=0.18u
Cl1494 out1494 0 10f
Mn1495 out1495 in 0 0 nch W=0.5u L=0.18u
Mp1495 out1495 in vdd vdd pch W=1u L=0.18u
Cl1495 out1495 0 10f
Mn1496 out1496 in 0 0 nch W=0.5u L=0.18u
Mp1496 out1496 in vdd vdd pch W=1u L=0.18u
Cl1496 out1496 0 10f
Mn1497 out1497 in 0 0 nch W=0.5u L=0.18u
Mp1497 out1497 in vdd vdd pch W=1u L=0.18u
Cl1497 out1497 0 10f
Mn1498 out1498 in 0 0 nch W=0.5u L=0.18u
Mp1498 out1498 in vdd vdd pch W=1u L=0.18u
Cl1498 out1498 0 10f
Mn1499 out1499 in 0 0 nch W=0.5u L=0.18u
Mp1499 out1499 in vdd vdd pch W=1u L=0.18u
Cl1499 out1499 0 10f
Mn1500 out1500 in 0 0 nch W=0.5u L=0.18u
Mp1500 out1500 in vdd vdd pch W=1u L=0.18u
Cl1500 out1500 0 10f
Mn1501 out1501 in 0 0 nch W=0.5u L=0.18u
Mp1501 out1501 in vdd vdd pch W=1u L=0.18u
Cl1501 out1501 0 10f
Mn1502 out1502 in 0 0 nch W=0.5u L=0.18u
Mp1502 out1502 in vdd vdd pch W=1u L=0.18u
Cl1502 out1502 0 10f
Mn1503 out1503 in 0 0 nch W=0.5u L=0.18u
Mp1503 out1503 in vdd vdd pch W=1u L=0.18u
Cl1503 out1503 0 10f
Mn1504 out1504 in 0 0 nch W=0.5u L=0.18u
Mp1504 out1504 in vdd vdd pch W=1u L=0.18u
Cl1504 out1504 0 10f
Mn1505 out1505 in 0 0 nch W=0.5u L=0.18u
Mp1505 out1505 in vdd vdd pch W=1u L=0.18u
Cl1505 out1505 0 10f
Mn1506 out1506 in 0 0 nch W=0.5u L=0.18u
Mp1506 out1506 in vdd vdd pch W=1u L=0.18u
Cl1506 out1506 0 10f
Mn1507 out1507 in 0 0 nch W=0.5u L=0.18u
Mp1507 out1507 in vdd vdd pch W=1u L=0.18u
Cl1507 out1507 0 10f
Mn1508 out1508 in 0 0 nch W=0.5u L=0.18u
Mp1508 out1508 in vdd vdd pch W=1u L=0.18u
Cl1508 out1508 0 10f
Mn1509 out1509 in 0 0 nch W=0.5u L=0.18u
Mp1509 out1509 in vdd vdd pch W=1u L=0.18u
Cl1509 out1509 0 10f
Mn1510 out1510 in 0 0 nch W=0.5u L=0.18u
Mp1510 out1510 in vdd vdd pch W=1u L=0.18u
Cl1510 out1510 0 10f
Mn1511 out1511 in 0 0 nch W=0.5u L=0.18u
Mp1511 out1511 in vdd vdd pch W=1u L=0.18u
Cl1511 out1511 0 10f
Mn1512 out1512 in 0 0 nch W=0.5u L=0.18u
Mp1512 out1512 in vdd vdd pch W=1u L=0.18u
Cl1512 out1512 0 10f
Mn1513 out1513 in 0 0 nch W=0.5u L=0.18u
Mp1513 out1513 in vdd vdd pch W=1u L=0.18u
Cl1513 out1513 0 10f
Mn1514 out1514 in 0 0 nch W=0.5u L=0.18u
Mp1514 out1514 in vdd vdd pch W=1u L=0.18u
Cl1514 out1514 0 10f
Mn1515 out1515 in 0 0 nch W=0.5u L=0.18u
Mp1515 out1515 in vdd vdd pch W=1u L=0.18u
Cl1515 out1515 0 10f
Mn1516 out1516 in 0 0 nch W=0.5u L=0.18u
Mp1516 out1516 in vdd vdd pch W=1u L=0.18u
Cl1516 out1516 0 10f
Mn1517 out1517 in 0 0 nch W=0.5u L=0.18u
Mp1517 out1517 in vdd vdd pch W=1u L=0.18u
Cl1517 out1517 0 10f
Mn1518 out1518 in 0 0 nch W=0.5u L=0.18u
Mp1518 out1518 in vdd vdd pch W=1u L=0.18u
Cl1518 out1518 0 10f
Mn1519 out1519 in 0 0 nch W=0.5u L=0.18u
Mp1519 out1519 in vdd vdd pch W=1u L=0.18u
Cl1519 out1519 0 10f
Mn1520 out1520 in 0 0 nch W=0.5u L=0.18u
Mp1520 out1520 in vdd vdd pch W=1u L=0.18u
Cl1520 out1520 0 10f
Mn1521 out1521 in 0 0 nch W=0.5u L=0.18u
Mp1521 out1521 in vdd vdd pch W=1u L=0.18u
Cl1521 out1521 0 10f
Mn1522 out1522 in 0 0 nch W=0.5u L=0.18u
Mp1522 out1522 in vdd vdd pch W=1u L=0.18u
Cl1522 out1522 0 10f
Mn1523 out1523 in 0 0 nch W=0.5u L=0.18u
Mp1523 out1523 in vdd vdd pch W=1u L=0.18u
Cl1523 out1523 0 10f
Mn1524 out1524 in 0 0 nch W=0.5u L=0.18u
Mp1524 out1524 in vdd vdd pch W=1u L=0.18u
Cl1524 out1524 0 10f
Mn1525 out1525 in 0 0 nch W=0.5u L=0.18u
Mp1525 out1525 in vdd vdd pch W=1u L=0.18u
Cl1525 out1525 0 10f
Mn1526 out1526 in 0 0 nch W=0.5u L=0.18u
Mp1526 out1526 in vdd vdd pch W=1u L=0.18u
Cl1526 out1526 0 10f
Mn1527 out1527 in 0 0 nch W=0.5u L=0.18u
Mp1527 out1527 in vdd vdd pch W=1u L=0.18u
Cl1527 out1527 0 10f
Mn1528 out1528 in 0 0 nch W=0.5u L=0.18u
Mp1528 out1528 in vdd vdd pch W=1u L=0.18u
Cl1528 out1528 0 10f
Mn1529 out1529 in 0 0 nch W=0.5u L=0.18u
Mp1529 out1529 in vdd vdd pch W=1u L=0.18u
Cl1529 out1529 0 10f
Mn1530 out1530 in 0 0 nch W=0.5u L=0.18u
Mp1530 out1530 in vdd vdd pch W=1u L=0.18u
Cl1530 out1530 0 10f
Mn1531 out1531 in 0 0 nch W=0.5u L=0.18u
Mp1531 out1531 in vdd vdd pch W=1u L=0.18u
Cl1531 out1531 0 10f
Mn1532 out1532 in 0 0 nch W=0.5u L=0.18u
Mp1532 out1532 in vdd vdd pch W=1u L=0.18u
Cl1532 out1532 0 10f
Mn1533 out1533 in 0 0 nch W=0.5u L=0.18u
Mp1533 out1533 in vdd vdd pch W=1u L=0.18u
Cl1533 out1533 0 10f
Mn1534 out1534 in 0 0 nch W=0.5u L=0.18u
Mp1534 out1534 in vdd vdd pch W=1u L=0.18u
Cl1534 out1534 0 10f
Mn1535 out1535 in 0 0 nch W=0.5u L=0.18u
Mp1535 out1535 in vdd vdd pch W=1u L=0.18u
Cl1535 out1535 0 10f
Mn1536 out1536 in 0 0 nch W=0.5u L=0.18u
Mp1536 out1536 in vdd vdd pch W=1u L=0.18u
Cl1536 out1536 0 10f
Mn1537 out1537 in 0 0 nch W=0.5u L=0.18u
Mp1537 out1537 in vdd vdd pch W=1u L=0.18u
Cl1537 out1537 0 10f
Mn1538 out1538 in 0 0 nch W=0.5u L=0.18u
Mp1538 out1538 in vdd vdd pch W=1u L=0.18u
Cl1538 out1538 0 10f
Mn1539 out1539 in 0 0 nch W=0.5u L=0.18u
Mp1539 out1539 in vdd vdd pch W=1u L=0.18u
Cl1539 out1539 0 10f
Mn1540 out1540 in 0 0 nch W=0.5u L=0.18u
Mp1540 out1540 in vdd vdd pch W=1u L=0.18u
Cl1540 out1540 0 10f
Mn1541 out1541 in 0 0 nch W=0.5u L=0.18u
Mp1541 out1541 in vdd vdd pch W=1u L=0.18u
Cl1541 out1541 0 10f
Mn1542 out1542 in 0 0 nch W=0.5u L=0.18u
Mp1542 out1542 in vdd vdd pch W=1u L=0.18u
Cl1542 out1542 0 10f
Mn1543 out1543 in 0 0 nch W=0.5u L=0.18u
Mp1543 out1543 in vdd vdd pch W=1u L=0.18u
Cl1543 out1543 0 10f
Mn1544 out1544 in 0 0 nch W=0.5u L=0.18u
Mp1544 out1544 in vdd vdd pch W=1u L=0.18u
Cl1544 out1544 0 10f
Mn1545 out1545 in 0 0 nch W=0.5u L=0.18u
Mp1545 out1545 in vdd vdd pch W=1u L=0.18u
Cl1545 out1545 0 10f
Mn1546 out1546 in 0 0 nch W=0.5u L=0.18u
Mp1546 out1546 in vdd vdd pch W=1u L=0.18u
Cl1546 out1546 0 10f
Mn1547 out1547 in 0 0 nch W=0.5u L=0.18u
Mp1547 out1547 in vdd vdd pch W=1u L=0.18u
Cl1547 out1547 0 10f
Mn1548 out1548 in 0 0 nch W=0.5u L=0.18u
Mp1548 out1548 in vdd vdd pch W=1u L=0.18u
Cl1548 out1548 0 10f
Mn1549 out1549 in 0 0 nch W=0.5u L=0.18u
Mp1549 out1549 in vdd vdd pch W=1u L=0.18u
Cl1549 out1549 0 10f
Mn1550 out1550 in 0 0 nch W=0.5u L=0.18u
Mp1550 out1550 in vdd vdd pch W=1u L=0.18u
Cl1550 out1550 0 10f
Mn1551 out1551 in 0 0 nch W=0.5u L=0.18u
Mp1551 out1551 in vdd vdd pch W=1u L=0.18u
Cl1551 out1551 0 10f
Mn1552 out1552 in 0 0 nch W=0.5u L=0.18u
Mp1552 out1552 in vdd vdd pch W=1u L=0.18u
Cl1552 out1552 0 10f
Mn1553 out1553 in 0 0 nch W=0.5u L=0.18u
Mp1553 out1553 in vdd vdd pch W=1u L=0.18u
Cl1553 out1553 0 10f
Mn1554 out1554 in 0 0 nch W=0.5u L=0.18u
Mp1554 out1554 in vdd vdd pch W=1u L=0.18u
Cl1554 out1554 0 10f
Mn1555 out1555 in 0 0 nch W=0.5u L=0.18u
Mp1555 out1555 in vdd vdd pch W=1u L=0.18u
Cl1555 out1555 0 10f
Mn1556 out1556 in 0 0 nch W=0.5u L=0.18u
Mp1556 out1556 in vdd vdd pch W=1u L=0.18u
Cl1556 out1556 0 10f
Mn1557 out1557 in 0 0 nch W=0.5u L=0.18u
Mp1557 out1557 in vdd vdd pch W=1u L=0.18u
Cl1557 out1557 0 10f
Mn1558 out1558 in 0 0 nch W=0.5u L=0.18u
Mp1558 out1558 in vdd vdd pch W=1u L=0.18u
Cl1558 out1558 0 10f
Mn1559 out1559 in 0 0 nch W=0.5u L=0.18u
Mp1559 out1559 in vdd vdd pch W=1u L=0.18u
Cl1559 out1559 0 10f
Mn1560 out1560 in 0 0 nch W=0.5u L=0.18u
Mp1560 out1560 in vdd vdd pch W=1u L=0.18u
Cl1560 out1560 0 10f
Mn1561 out1561 in 0 0 nch W=0.5u L=0.18u
Mp1561 out1561 in vdd vdd pch W=1u L=0.18u
Cl1561 out1561 0 10f
Mn1562 out1562 in 0 0 nch W=0.5u L=0.18u
Mp1562 out1562 in vdd vdd pch W=1u L=0.18u
Cl1562 out1562 0 10f
Mn1563 out1563 in 0 0 nch W=0.5u L=0.18u
Mp1563 out1563 in vdd vdd pch W=1u L=0.18u
Cl1563 out1563 0 10f
Mn1564 out1564 in 0 0 nch W=0.5u L=0.18u
Mp1564 out1564 in vdd vdd pch W=1u L=0.18u
Cl1564 out1564 0 10f
Mn1565 out1565 in 0 0 nch W=0.5u L=0.18u
Mp1565 out1565 in vdd vdd pch W=1u L=0.18u
Cl1565 out1565 0 10f
Mn1566 out1566 in 0 0 nch W=0.5u L=0.18u
Mp1566 out1566 in vdd vdd pch W=1u L=0.18u
Cl1566 out1566 0 10f
Mn1567 out1567 in 0 0 nch W=0.5u L=0.18u
Mp1567 out1567 in vdd vdd pch W=1u L=0.18u
Cl1567 out1567 0 10f
Mn1568 out1568 in 0 0 nch W=0.5u L=0.18u
Mp1568 out1568 in vdd vdd pch W=1u L=0.18u
Cl1568 out1568 0 10f
Mn1569 out1569 in 0 0 nch W=0.5u L=0.18u
Mp1569 out1569 in vdd vdd pch W=1u L=0.18u
Cl1569 out1569 0 10f
Mn1570 out1570 in 0 0 nch W=0.5u L=0.18u
Mp1570 out1570 in vdd vdd pch W=1u L=0.18u
Cl1570 out1570 0 10f
Mn1571 out1571 in 0 0 nch W=0.5u L=0.18u
Mp1571 out1571 in vdd vdd pch W=1u L=0.18u
Cl1571 out1571 0 10f
Mn1572 out1572 in 0 0 nch W=0.5u L=0.18u
Mp1572 out1572 in vdd vdd pch W=1u L=0.18u
Cl1572 out1572 0 10f
Mn1573 out1573 in 0 0 nch W=0.5u L=0.18u
Mp1573 out1573 in vdd vdd pch W=1u L=0.18u
Cl1573 out1573 0 10f
Mn1574 out1574 in 0 0 nch W=0.5u L=0.18u
Mp1574 out1574 in vdd vdd pch W=1u L=0.18u
Cl1574 out1574 0 10f
Mn1575 out1575 in 0 0 nch W=0.5u L=0.18u
Mp1575 out1575 in vdd vdd pch W=1u L=0.18u
Cl1575 out1575 0 10f
Mn1576 out1576 in 0 0 nch W=0.5u L=0.18u
Mp1576 out1576 in vdd vdd pch W=1u L=0.18u
Cl1576 out1576 0 10f
Mn1577 out1577 in 0 0 nch W=0.5u L=0.18u
Mp1577 out1577 in vdd vdd pch W=1u L=0.18u
Cl1577 out1577 0 10f
Mn1578 out1578 in 0 0 nch W=0.5u L=0.18u
Mp1578 out1578 in vdd vdd pch W=1u L=0.18u
Cl1578 out1578 0 10f
Mn1579 out1579 in 0 0 nch W=0.5u L=0.18u
Mp1579 out1579 in vdd vdd pch W=1u L=0.18u
Cl1579 out1579 0 10f
Mn1580 out1580 in 0 0 nch W=0.5u L=0.18u
Mp1580 out1580 in vdd vdd pch W=1u L=0.18u
Cl1580 out1580 0 10f
Mn1581 out1581 in 0 0 nch W=0.5u L=0.18u
Mp1581 out1581 in vdd vdd pch W=1u L=0.18u
Cl1581 out1581 0 10f
Mn1582 out1582 in 0 0 nch W=0.5u L=0.18u
Mp1582 out1582 in vdd vdd pch W=1u L=0.18u
Cl1582 out1582 0 10f
Mn1583 out1583 in 0 0 nch W=0.5u L=0.18u
Mp1583 out1583 in vdd vdd pch W=1u L=0.18u
Cl1583 out1583 0 10f
Mn1584 out1584 in 0 0 nch W=0.5u L=0.18u
Mp1584 out1584 in vdd vdd pch W=1u L=0.18u
Cl1584 out1584 0 10f
Mn1585 out1585 in 0 0 nch W=0.5u L=0.18u
Mp1585 out1585 in vdd vdd pch W=1u L=0.18u
Cl1585 out1585 0 10f
Mn1586 out1586 in 0 0 nch W=0.5u L=0.18u
Mp1586 out1586 in vdd vdd pch W=1u L=0.18u
Cl1586 out1586 0 10f
Mn1587 out1587 in 0 0 nch W=0.5u L=0.18u
Mp1587 out1587 in vdd vdd pch W=1u L=0.18u
Cl1587 out1587 0 10f
Mn1588 out1588 in 0 0 nch W=0.5u L=0.18u
Mp1588 out1588 in vdd vdd pch W=1u L=0.18u
Cl1588 out1588 0 10f
Mn1589 out1589 in 0 0 nch W=0.5u L=0.18u
Mp1589 out1589 in vdd vdd pch W=1u L=0.18u
Cl1589 out1589 0 10f
Mn1590 out1590 in 0 0 nch W=0.5u L=0.18u
Mp1590 out1590 in vdd vdd pch W=1u L=0.18u
Cl1590 out1590 0 10f
Mn1591 out1591 in 0 0 nch W=0.5u L=0.18u
Mp1591 out1591 in vdd vdd pch W=1u L=0.18u
Cl1591 out1591 0 10f
Mn1592 out1592 in 0 0 nch W=0.5u L=0.18u
Mp1592 out1592 in vdd vdd pch W=1u L=0.18u
Cl1592 out1592 0 10f
Mn1593 out1593 in 0 0 nch W=0.5u L=0.18u
Mp1593 out1593 in vdd vdd pch W=1u L=0.18u
Cl1593 out1593 0 10f
Mn1594 out1594 in 0 0 nch W=0.5u L=0.18u
Mp1594 out1594 in vdd vdd pch W=1u L=0.18u
Cl1594 out1594 0 10f
Mn1595 out1595 in 0 0 nch W=0.5u L=0.18u
Mp1595 out1595 in vdd vdd pch W=1u L=0.18u
Cl1595 out1595 0 10f
Mn1596 out1596 in 0 0 nch W=0.5u L=0.18u
Mp1596 out1596 in vdd vdd pch W=1u L=0.18u
Cl1596 out1596 0 10f
Mn1597 out1597 in 0 0 nch W=0.5u L=0.18u
Mp1597 out1597 in vdd vdd pch W=1u L=0.18u
Cl1597 out1597 0 10f
Mn1598 out1598 in 0 0 nch W=0.5u L=0.18u
Mp1598 out1598 in vdd vdd pch W=1u L=0.18u
Cl1598 out1598 0 10f
Mn1599 out1599 in 0 0 nch W=0.5u L=0.18u
Mp1599 out1599 in vdd vdd pch W=1u L=0.18u
Cl1599 out1599 0 10f
Mn1600 out1600 in 0 0 nch W=0.5u L=0.18u
Mp1600 out1600 in vdd vdd pch W=1u L=0.18u
Cl1600 out1600 0 10f
Mn1601 out1601 in 0 0 nch W=0.5u L=0.18u
Mp1601 out1601 in vdd vdd pch W=1u L=0.18u
Cl1601 out1601 0 10f
Mn1602 out1602 in 0 0 nch W=0.5u L=0.18u
Mp1602 out1602 in vdd vdd pch W=1u L=0.18u
Cl1602 out1602 0 10f
Mn1603 out1603 in 0 0 nch W=0.5u L=0.18u
Mp1603 out1603 in vdd vdd pch W=1u L=0.18u
Cl1603 out1603 0 10f
Mn1604 out1604 in 0 0 nch W=0.5u L=0.18u
Mp1604 out1604 in vdd vdd pch W=1u L=0.18u
Cl1604 out1604 0 10f
Mn1605 out1605 in 0 0 nch W=0.5u L=0.18u
Mp1605 out1605 in vdd vdd pch W=1u L=0.18u
Cl1605 out1605 0 10f
Mn1606 out1606 in 0 0 nch W=0.5u L=0.18u
Mp1606 out1606 in vdd vdd pch W=1u L=0.18u
Cl1606 out1606 0 10f
Mn1607 out1607 in 0 0 nch W=0.5u L=0.18u
Mp1607 out1607 in vdd vdd pch W=1u L=0.18u
Cl1607 out1607 0 10f
Mn1608 out1608 in 0 0 nch W=0.5u L=0.18u
Mp1608 out1608 in vdd vdd pch W=1u L=0.18u
Cl1608 out1608 0 10f
Mn1609 out1609 in 0 0 nch W=0.5u L=0.18u
Mp1609 out1609 in vdd vdd pch W=1u L=0.18u
Cl1609 out1609 0 10f
Mn1610 out1610 in 0 0 nch W=0.5u L=0.18u
Mp1610 out1610 in vdd vdd pch W=1u L=0.18u
Cl1610 out1610 0 10f
Mn1611 out1611 in 0 0 nch W=0.5u L=0.18u
Mp1611 out1611 in vdd vdd pch W=1u L=0.18u
Cl1611 out1611 0 10f
Mn1612 out1612 in 0 0 nch W=0.5u L=0.18u
Mp1612 out1612 in vdd vdd pch W=1u L=0.18u
Cl1612 out1612 0 10f
Mn1613 out1613 in 0 0 nch W=0.5u L=0.18u
Mp1613 out1613 in vdd vdd pch W=1u L=0.18u
Cl1613 out1613 0 10f
Mn1614 out1614 in 0 0 nch W=0.5u L=0.18u
Mp1614 out1614 in vdd vdd pch W=1u L=0.18u
Cl1614 out1614 0 10f
Mn1615 out1615 in 0 0 nch W=0.5u L=0.18u
Mp1615 out1615 in vdd vdd pch W=1u L=0.18u
Cl1615 out1615 0 10f
Mn1616 out1616 in 0 0 nch W=0.5u L=0.18u
Mp1616 out1616 in vdd vdd pch W=1u L=0.18u
Cl1616 out1616 0 10f
Mn1617 out1617 in 0 0 nch W=0.5u L=0.18u
Mp1617 out1617 in vdd vdd pch W=1u L=0.18u
Cl1617 out1617 0 10f
Mn1618 out1618 in 0 0 nch W=0.5u L=0.18u
Mp1618 out1618 in vdd vdd pch W=1u L=0.18u
Cl1618 out1618 0 10f
Mn1619 out1619 in 0 0 nch W=0.5u L=0.18u
Mp1619 out1619 in vdd vdd pch W=1u L=0.18u
Cl1619 out1619 0 10f
Mn1620 out1620 in 0 0 nch W=0.5u L=0.18u
Mp1620 out1620 in vdd vdd pch W=1u L=0.18u
Cl1620 out1620 0 10f
Mn1621 out1621 in 0 0 nch W=0.5u L=0.18u
Mp1621 out1621 in vdd vdd pch W=1u L=0.18u
Cl1621 out1621 0 10f
Mn1622 out1622 in 0 0 nch W=0.5u L=0.18u
Mp1622 out1622 in vdd vdd pch W=1u L=0.18u
Cl1622 out1622 0 10f
Mn1623 out1623 in 0 0 nch W=0.5u L=0.18u
Mp1623 out1623 in vdd vdd pch W=1u L=0.18u
Cl1623 out1623 0 10f
Mn1624 out1624 in 0 0 nch W=0.5u L=0.18u
Mp1624 out1624 in vdd vdd pch W=1u L=0.18u
Cl1624 out1624 0 10f
Mn1625 out1625 in 0 0 nch W=0.5u L=0.18u
Mp1625 out1625 in vdd vdd pch W=1u L=0.18u
Cl1625 out1625 0 10f
Mn1626 out1626 in 0 0 nch W=0.5u L=0.18u
Mp1626 out1626 in vdd vdd pch W=1u L=0.18u
Cl1626 out1626 0 10f
Mn1627 out1627 in 0 0 nch W=0.5u L=0.18u
Mp1627 out1627 in vdd vdd pch W=1u L=0.18u
Cl1627 out1627 0 10f
Mn1628 out1628 in 0 0 nch W=0.5u L=0.18u
Mp1628 out1628 in vdd vdd pch W=1u L=0.18u
Cl1628 out1628 0 10f
Mn1629 out1629 in 0 0 nch W=0.5u L=0.18u
Mp1629 out1629 in vdd vdd pch W=1u L=0.18u
Cl1629 out1629 0 10f
Mn1630 out1630 in 0 0 nch W=0.5u L=0.18u
Mp1630 out1630 in vdd vdd pch W=1u L=0.18u
Cl1630 out1630 0 10f
Mn1631 out1631 in 0 0 nch W=0.5u L=0.18u
Mp1631 out1631 in vdd vdd pch W=1u L=0.18u
Cl1631 out1631 0 10f
Mn1632 out1632 in 0 0 nch W=0.5u L=0.18u
Mp1632 out1632 in vdd vdd pch W=1u L=0.18u
Cl1632 out1632 0 10f
Mn1633 out1633 in 0 0 nch W=0.5u L=0.18u
Mp1633 out1633 in vdd vdd pch W=1u L=0.18u
Cl1633 out1633 0 10f
Mn1634 out1634 in 0 0 nch W=0.5u L=0.18u
Mp1634 out1634 in vdd vdd pch W=1u L=0.18u
Cl1634 out1634 0 10f
Mn1635 out1635 in 0 0 nch W=0.5u L=0.18u
Mp1635 out1635 in vdd vdd pch W=1u L=0.18u
Cl1635 out1635 0 10f
Mn1636 out1636 in 0 0 nch W=0.5u L=0.18u
Mp1636 out1636 in vdd vdd pch W=1u L=0.18u
Cl1636 out1636 0 10f
Mn1637 out1637 in 0 0 nch W=0.5u L=0.18u
Mp1637 out1637 in vdd vdd pch W=1u L=0.18u
Cl1637 out1637 0 10f
Mn1638 out1638 in 0 0 nch W=0.5u L=0.18u
Mp1638 out1638 in vdd vdd pch W=1u L=0.18u
Cl1638 out1638 0 10f
Mn1639 out1639 in 0 0 nch W=0.5u L=0.18u
Mp1639 out1639 in vdd vdd pch W=1u L=0.18u
Cl1639 out1639 0 10f
Mn1640 out1640 in 0 0 nch W=0.5u L=0.18u
Mp1640 out1640 in vdd vdd pch W=1u L=0.18u
Cl1640 out1640 0 10f
Mn1641 out1641 in 0 0 nch W=0.5u L=0.18u
Mp1641 out1641 in vdd vdd pch W=1u L=0.18u
Cl1641 out1641 0 10f
Mn1642 out1642 in 0 0 nch W=0.5u L=0.18u
Mp1642 out1642 in vdd vdd pch W=1u L=0.18u
Cl1642 out1642 0 10f
Mn1643 out1643 in 0 0 nch W=0.5u L=0.18u
Mp1643 out1643 in vdd vdd pch W=1u L=0.18u
Cl1643 out1643 0 10f
Mn1644 out1644 in 0 0 nch W=0.5u L=0.18u
Mp1644 out1644 in vdd vdd pch W=1u L=0.18u
Cl1644 out1644 0 10f
Mn1645 out1645 in 0 0 nch W=0.5u L=0.18u
Mp1645 out1645 in vdd vdd pch W=1u L=0.18u
Cl1645 out1645 0 10f
Mn1646 out1646 in 0 0 nch W=0.5u L=0.18u
Mp1646 out1646 in vdd vdd pch W=1u L=0.18u
Cl1646 out1646 0 10f
Mn1647 out1647 in 0 0 nch W=0.5u L=0.18u
Mp1647 out1647 in vdd vdd pch W=1u L=0.18u
Cl1647 out1647 0 10f
Mn1648 out1648 in 0 0 nch W=0.5u L=0.18u
Mp1648 out1648 in vdd vdd pch W=1u L=0.18u
Cl1648 out1648 0 10f
Mn1649 out1649 in 0 0 nch W=0.5u L=0.18u
Mp1649 out1649 in vdd vdd pch W=1u L=0.18u
Cl1649 out1649 0 10f
Mn1650 out1650 in 0 0 nch W=0.5u L=0.18u
Mp1650 out1650 in vdd vdd pch W=1u L=0.18u
Cl1650 out1650 0 10f
Mn1651 out1651 in 0 0 nch W=0.5u L=0.18u
Mp1651 out1651 in vdd vdd pch W=1u L=0.18u
Cl1651 out1651 0 10f
Mn1652 out1652 in 0 0 nch W=0.5u L=0.18u
Mp1652 out1652 in vdd vdd pch W=1u L=0.18u
Cl1652 out1652 0 10f
Mn1653 out1653 in 0 0 nch W=0.5u L=0.18u
Mp1653 out1653 in vdd vdd pch W=1u L=0.18u
Cl1653 out1653 0 10f
Mn1654 out1654 in 0 0 nch W=0.5u L=0.18u
Mp1654 out1654 in vdd vdd pch W=1u L=0.18u
Cl1654 out1654 0 10f
Mn1655 out1655 in 0 0 nch W=0.5u L=0.18u
Mp1655 out1655 in vdd vdd pch W=1u L=0.18u
Cl1655 out1655 0 10f
Mn1656 out1656 in 0 0 nch W=0.5u L=0.18u
Mp1656 out1656 in vdd vdd pch W=1u L=0.18u
Cl1656 out1656 0 10f
Mn1657 out1657 in 0 0 nch W=0.5u L=0.18u
Mp1657 out1657 in vdd vdd pch W=1u L=0.18u
Cl1657 out1657 0 10f
Mn1658 out1658 in 0 0 nch W=0.5u L=0.18u
Mp1658 out1658 in vdd vdd pch W=1u L=0.18u
Cl1658 out1658 0 10f
Mn1659 out1659 in 0 0 nch W=0.5u L=0.18u
Mp1659 out1659 in vdd vdd pch W=1u L=0.18u
Cl1659 out1659 0 10f
Mn1660 out1660 in 0 0 nch W=0.5u L=0.18u
Mp1660 out1660 in vdd vdd pch W=1u L=0.18u
Cl1660 out1660 0 10f
Mn1661 out1661 in 0 0 nch W=0.5u L=0.18u
Mp1661 out1661 in vdd vdd pch W=1u L=0.18u
Cl1661 out1661 0 10f
Mn1662 out1662 in 0 0 nch W=0.5u L=0.18u
Mp1662 out1662 in vdd vdd pch W=1u L=0.18u
Cl1662 out1662 0 10f
Mn1663 out1663 in 0 0 nch W=0.5u L=0.18u
Mp1663 out1663 in vdd vdd pch W=1u L=0.18u
Cl1663 out1663 0 10f
Mn1664 out1664 in 0 0 nch W=0.5u L=0.18u
Mp1664 out1664 in vdd vdd pch W=1u L=0.18u
Cl1664 out1664 0 10f
Mn1665 out1665 in 0 0 nch W=0.5u L=0.18u
Mp1665 out1665 in vdd vdd pch W=1u L=0.18u
Cl1665 out1665 0 10f
Mn1666 out1666 in 0 0 nch W=0.5u L=0.18u
Mp1666 out1666 in vdd vdd pch W=1u L=0.18u
Cl1666 out1666 0 10f
Mn1667 out1667 in 0 0 nch W=0.5u L=0.18u
Mp1667 out1667 in vdd vdd pch W=1u L=0.18u
Cl1667 out1667 0 10f
Mn1668 out1668 in 0 0 nch W=0.5u L=0.18u
Mp1668 out1668 in vdd vdd pch W=1u L=0.18u
Cl1668 out1668 0 10f
Mn1669 out1669 in 0 0 nch W=0.5u L=0.18u
Mp1669 out1669 in vdd vdd pch W=1u L=0.18u
Cl1669 out1669 0 10f
Mn1670 out1670 in 0 0 nch W=0.5u L=0.18u
Mp1670 out1670 in vdd vdd pch W=1u L=0.18u
Cl1670 out1670 0 10f
Mn1671 out1671 in 0 0 nch W=0.5u L=0.18u
Mp1671 out1671 in vdd vdd pch W=1u L=0.18u
Cl1671 out1671 0 10f
Mn1672 out1672 in 0 0 nch W=0.5u L=0.18u
Mp1672 out1672 in vdd vdd pch W=1u L=0.18u
Cl1672 out1672 0 10f
Mn1673 out1673 in 0 0 nch W=0.5u L=0.18u
Mp1673 out1673 in vdd vdd pch W=1u L=0.18u
Cl1673 out1673 0 10f
Mn1674 out1674 in 0 0 nch W=0.5u L=0.18u
Mp1674 out1674 in vdd vdd pch W=1u L=0.18u
Cl1674 out1674 0 10f
Mn1675 out1675 in 0 0 nch W=0.5u L=0.18u
Mp1675 out1675 in vdd vdd pch W=1u L=0.18u
Cl1675 out1675 0 10f
Mn1676 out1676 in 0 0 nch W=0.5u L=0.18u
Mp1676 out1676 in vdd vdd pch W=1u L=0.18u
Cl1676 out1676 0 10f
Mn1677 out1677 in 0 0 nch W=0.5u L=0.18u
Mp1677 out1677 in vdd vdd pch W=1u L=0.18u
Cl1677 out1677 0 10f
Mn1678 out1678 in 0 0 nch W=0.5u L=0.18u
Mp1678 out1678 in vdd vdd pch W=1u L=0.18u
Cl1678 out1678 0 10f
Mn1679 out1679 in 0 0 nch W=0.5u L=0.18u
Mp1679 out1679 in vdd vdd pch W=1u L=0.18u
Cl1679 out1679 0 10f
Mn1680 out1680 in 0 0 nch W=0.5u L=0.18u
Mp1680 out1680 in vdd vdd pch W=1u L=0.18u
Cl1680 out1680 0 10f
Mn1681 out1681 in 0 0 nch W=0.5u L=0.18u
Mp1681 out1681 in vdd vdd pch W=1u L=0.18u
Cl1681 out1681 0 10f
Mn1682 out1682 in 0 0 nch W=0.5u L=0.18u
Mp1682 out1682 in vdd vdd pch W=1u L=0.18u
Cl1682 out1682 0 10f
Mn1683 out1683 in 0 0 nch W=0.5u L=0.18u
Mp1683 out1683 in vdd vdd pch W=1u L=0.18u
Cl1683 out1683 0 10f
Mn1684 out1684 in 0 0 nch W=0.5u L=0.18u
Mp1684 out1684 in vdd vdd pch W=1u L=0.18u
Cl1684 out1684 0 10f
Mn1685 out1685 in 0 0 nch W=0.5u L=0.18u
Mp1685 out1685 in vdd vdd pch W=1u L=0.18u
Cl1685 out1685 0 10f
Mn1686 out1686 in 0 0 nch W=0.5u L=0.18u
Mp1686 out1686 in vdd vdd pch W=1u L=0.18u
Cl1686 out1686 0 10f
Mn1687 out1687 in 0 0 nch W=0.5u L=0.18u
Mp1687 out1687 in vdd vdd pch W=1u L=0.18u
Cl1687 out1687 0 10f
Mn1688 out1688 in 0 0 nch W=0.5u L=0.18u
Mp1688 out1688 in vdd vdd pch W=1u L=0.18u
Cl1688 out1688 0 10f
Mn1689 out1689 in 0 0 nch W=0.5u L=0.18u
Mp1689 out1689 in vdd vdd pch W=1u L=0.18u
Cl1689 out1689 0 10f
Mn1690 out1690 in 0 0 nch W=0.5u L=0.18u
Mp1690 out1690 in vdd vdd pch W=1u L=0.18u
Cl1690 out1690 0 10f
Mn1691 out1691 in 0 0 nch W=0.5u L=0.18u
Mp1691 out1691 in vdd vdd pch W=1u L=0.18u
Cl1691 out1691 0 10f
Mn1692 out1692 in 0 0 nch W=0.5u L=0.18u
Mp1692 out1692 in vdd vdd pch W=1u L=0.18u
Cl1692 out1692 0 10f
Mn1693 out1693 in 0 0 nch W=0.5u L=0.18u
Mp1693 out1693 in vdd vdd pch W=1u L=0.18u
Cl1693 out1693 0 10f
Mn1694 out1694 in 0 0 nch W=0.5u L=0.18u
Mp1694 out1694 in vdd vdd pch W=1u L=0.18u
Cl1694 out1694 0 10f
Mn1695 out1695 in 0 0 nch W=0.5u L=0.18u
Mp1695 out1695 in vdd vdd pch W=1u L=0.18u
Cl1695 out1695 0 10f
Mn1696 out1696 in 0 0 nch W=0.5u L=0.18u
Mp1696 out1696 in vdd vdd pch W=1u L=0.18u
Cl1696 out1696 0 10f
Mn1697 out1697 in 0 0 nch W=0.5u L=0.18u
Mp1697 out1697 in vdd vdd pch W=1u L=0.18u
Cl1697 out1697 0 10f
Mn1698 out1698 in 0 0 nch W=0.5u L=0.18u
Mp1698 out1698 in vdd vdd pch W=1u L=0.18u
Cl1698 out1698 0 10f
Mn1699 out1699 in 0 0 nch W=0.5u L=0.18u
Mp1699 out1699 in vdd vdd pch W=1u L=0.18u
Cl1699 out1699 0 10f
Mn1700 out1700 in 0 0 nch W=0.5u L=0.18u
Mp1700 out1700 in vdd vdd pch W=1u L=0.18u
Cl1700 out1700 0 10f
Mn1701 out1701 in 0 0 nch W=0.5u L=0.18u
Mp1701 out1701 in vdd vdd pch W=1u L=0.18u
Cl1701 out1701 0 10f
Mn1702 out1702 in 0 0 nch W=0.5u L=0.18u
Mp1702 out1702 in vdd vdd pch W=1u L=0.18u
Cl1702 out1702 0 10f
Mn1703 out1703 in 0 0 nch W=0.5u L=0.18u
Mp1703 out1703 in vdd vdd pch W=1u L=0.18u
Cl1703 out1703 0 10f
Mn1704 out1704 in 0 0 nch W=0.5u L=0.18u
Mp1704 out1704 in vdd vdd pch W=1u L=0.18u
Cl1704 out1704 0 10f
Mn1705 out1705 in 0 0 nch W=0.5u L=0.18u
Mp1705 out1705 in vdd vdd pch W=1u L=0.18u
Cl1705 out1705 0 10f
Mn1706 out1706 in 0 0 nch W=0.5u L=0.18u
Mp1706 out1706 in vdd vdd pch W=1u L=0.18u
Cl1706 out1706 0 10f
Mn1707 out1707 in 0 0 nch W=0.5u L=0.18u
Mp1707 out1707 in vdd vdd pch W=1u L=0.18u
Cl1707 out1707 0 10f
Mn1708 out1708 in 0 0 nch W=0.5u L=0.18u
Mp1708 out1708 in vdd vdd pch W=1u L=0.18u
Cl1708 out1708 0 10f
Mn1709 out1709 in 0 0 nch W=0.5u L=0.18u
Mp1709 out1709 in vdd vdd pch W=1u L=0.18u
Cl1709 out1709 0 10f
Mn1710 out1710 in 0 0 nch W=0.5u L=0.18u
Mp1710 out1710 in vdd vdd pch W=1u L=0.18u
Cl1710 out1710 0 10f
Mn1711 out1711 in 0 0 nch W=0.5u L=0.18u
Mp1711 out1711 in vdd vdd pch W=1u L=0.18u
Cl1711 out1711 0 10f
Mn1712 out1712 in 0 0 nch W=0.5u L=0.18u
Mp1712 out1712 in vdd vdd pch W=1u L=0.18u
Cl1712 out1712 0 10f
Mn1713 out1713 in 0 0 nch W=0.5u L=0.18u
Mp1713 out1713 in vdd vdd pch W=1u L=0.18u
Cl1713 out1713 0 10f
Mn1714 out1714 in 0 0 nch W=0.5u L=0.18u
Mp1714 out1714 in vdd vdd pch W=1u L=0.18u
Cl1714 out1714 0 10f
Mn1715 out1715 in 0 0 nch W=0.5u L=0.18u
Mp1715 out1715 in vdd vdd pch W=1u L=0.18u
Cl1715 out1715 0 10f
Mn1716 out1716 in 0 0 nch W=0.5u L=0.18u
Mp1716 out1716 in vdd vdd pch W=1u L=0.18u
Cl1716 out1716 0 10f
Mn1717 out1717 in 0 0 nch W=0.5u L=0.18u
Mp1717 out1717 in vdd vdd pch W=1u L=0.18u
Cl1717 out1717 0 10f
Mn1718 out1718 in 0 0 nch W=0.5u L=0.18u
Mp1718 out1718 in vdd vdd pch W=1u L=0.18u
Cl1718 out1718 0 10f
Mn1719 out1719 in 0 0 nch W=0.5u L=0.18u
Mp1719 out1719 in vdd vdd pch W=1u L=0.18u
Cl1719 out1719 0 10f
Mn1720 out1720 in 0 0 nch W=0.5u L=0.18u
Mp1720 out1720 in vdd vdd pch W=1u L=0.18u
Cl1720 out1720 0 10f
Mn1721 out1721 in 0 0 nch W=0.5u L=0.18u
Mp1721 out1721 in vdd vdd pch W=1u L=0.18u
Cl1721 out1721 0 10f
Mn1722 out1722 in 0 0 nch W=0.5u L=0.18u
Mp1722 out1722 in vdd vdd pch W=1u L=0.18u
Cl1722 out1722 0 10f
Mn1723 out1723 in 0 0 nch W=0.5u L=0.18u
Mp1723 out1723 in vdd vdd pch W=1u L=0.18u
Cl1723 out1723 0 10f
Mn1724 out1724 in 0 0 nch W=0.5u L=0.18u
Mp1724 out1724 in vdd vdd pch W=1u L=0.18u
Cl1724 out1724 0 10f
Mn1725 out1725 in 0 0 nch W=0.5u L=0.18u
Mp1725 out1725 in vdd vdd pch W=1u L=0.18u
Cl1725 out1725 0 10f
Mn1726 out1726 in 0 0 nch W=0.5u L=0.18u
Mp1726 out1726 in vdd vdd pch W=1u L=0.18u
Cl1726 out1726 0 10f
Mn1727 out1727 in 0 0 nch W=0.5u L=0.18u
Mp1727 out1727 in vdd vdd pch W=1u L=0.18u
Cl1727 out1727 0 10f
Mn1728 out1728 in 0 0 nch W=0.5u L=0.18u
Mp1728 out1728 in vdd vdd pch W=1u L=0.18u
Cl1728 out1728 0 10f
Mn1729 out1729 in 0 0 nch W=0.5u L=0.18u
Mp1729 out1729 in vdd vdd pch W=1u L=0.18u
Cl1729 out1729 0 10f
Mn1730 out1730 in 0 0 nch W=0.5u L=0.18u
Mp1730 out1730 in vdd vdd pch W=1u L=0.18u
Cl1730 out1730 0 10f
Mn1731 out1731 in 0 0 nch W=0.5u L=0.18u
Mp1731 out1731 in vdd vdd pch W=1u L=0.18u
Cl1731 out1731 0 10f
Mn1732 out1732 in 0 0 nch W=0.5u L=0.18u
Mp1732 out1732 in vdd vdd pch W=1u L=0.18u
Cl1732 out1732 0 10f
Mn1733 out1733 in 0 0 nch W=0.5u L=0.18u
Mp1733 out1733 in vdd vdd pch W=1u L=0.18u
Cl1733 out1733 0 10f
Mn1734 out1734 in 0 0 nch W=0.5u L=0.18u
Mp1734 out1734 in vdd vdd pch W=1u L=0.18u
Cl1734 out1734 0 10f
Mn1735 out1735 in 0 0 nch W=0.5u L=0.18u
Mp1735 out1735 in vdd vdd pch W=1u L=0.18u
Cl1735 out1735 0 10f
Mn1736 out1736 in 0 0 nch W=0.5u L=0.18u
Mp1736 out1736 in vdd vdd pch W=1u L=0.18u
Cl1736 out1736 0 10f
Mn1737 out1737 in 0 0 nch W=0.5u L=0.18u
Mp1737 out1737 in vdd vdd pch W=1u L=0.18u
Cl1737 out1737 0 10f
Mn1738 out1738 in 0 0 nch W=0.5u L=0.18u
Mp1738 out1738 in vdd vdd pch W=1u L=0.18u
Cl1738 out1738 0 10f
Mn1739 out1739 in 0 0 nch W=0.5u L=0.18u
Mp1739 out1739 in vdd vdd pch W=1u L=0.18u
Cl1739 out1739 0 10f
Mn1740 out1740 in 0 0 nch W=0.5u L=0.18u
Mp1740 out1740 in vdd vdd pch W=1u L=0.18u
Cl1740 out1740 0 10f
Mn1741 out1741 in 0 0 nch W=0.5u L=0.18u
Mp1741 out1741 in vdd vdd pch W=1u L=0.18u
Cl1741 out1741 0 10f
Mn1742 out1742 in 0 0 nch W=0.5u L=0.18u
Mp1742 out1742 in vdd vdd pch W=1u L=0.18u
Cl1742 out1742 0 10f
Mn1743 out1743 in 0 0 nch W=0.5u L=0.18u
Mp1743 out1743 in vdd vdd pch W=1u L=0.18u
Cl1743 out1743 0 10f
Mn1744 out1744 in 0 0 nch W=0.5u L=0.18u
Mp1744 out1744 in vdd vdd pch W=1u L=0.18u
Cl1744 out1744 0 10f
Mn1745 out1745 in 0 0 nch W=0.5u L=0.18u
Mp1745 out1745 in vdd vdd pch W=1u L=0.18u
Cl1745 out1745 0 10f
Mn1746 out1746 in 0 0 nch W=0.5u L=0.18u
Mp1746 out1746 in vdd vdd pch W=1u L=0.18u
Cl1746 out1746 0 10f
Mn1747 out1747 in 0 0 nch W=0.5u L=0.18u
Mp1747 out1747 in vdd vdd pch W=1u L=0.18u
Cl1747 out1747 0 10f
Mn1748 out1748 in 0 0 nch W=0.5u L=0.18u
Mp1748 out1748 in vdd vdd pch W=1u L=0.18u
Cl1748 out1748 0 10f
Mn1749 out1749 in 0 0 nch W=0.5u L=0.18u
Mp1749 out1749 in vdd vdd pch W=1u L=0.18u
Cl1749 out1749 0 10f
Mn1750 out1750 in 0 0 nch W=0.5u L=0.18u
Mp1750 out1750 in vdd vdd pch W=1u L=0.18u
Cl1750 out1750 0 10f
Mn1751 out1751 in 0 0 nch W=0.5u L=0.18u
Mp1751 out1751 in vdd vdd pch W=1u L=0.18u
Cl1751 out1751 0 10f
Mn1752 out1752 in 0 0 nch W=0.5u L=0.18u
Mp1752 out1752 in vdd vdd pch W=1u L=0.18u
Cl1752 out1752 0 10f
Mn1753 out1753 in 0 0 nch W=0.5u L=0.18u
Mp1753 out1753 in vdd vdd pch W=1u L=0.18u
Cl1753 out1753 0 10f
Mn1754 out1754 in 0 0 nch W=0.5u L=0.18u
Mp1754 out1754 in vdd vdd pch W=1u L=0.18u
Cl1754 out1754 0 10f
Mn1755 out1755 in 0 0 nch W=0.5u L=0.18u
Mp1755 out1755 in vdd vdd pch W=1u L=0.18u
Cl1755 out1755 0 10f
Mn1756 out1756 in 0 0 nch W=0.5u L=0.18u
Mp1756 out1756 in vdd vdd pch W=1u L=0.18u
Cl1756 out1756 0 10f
Mn1757 out1757 in 0 0 nch W=0.5u L=0.18u
Mp1757 out1757 in vdd vdd pch W=1u L=0.18u
Cl1757 out1757 0 10f
Mn1758 out1758 in 0 0 nch W=0.5u L=0.18u
Mp1758 out1758 in vdd vdd pch W=1u L=0.18u
Cl1758 out1758 0 10f
Mn1759 out1759 in 0 0 nch W=0.5u L=0.18u
Mp1759 out1759 in vdd vdd pch W=1u L=0.18u
Cl1759 out1759 0 10f
Mn1760 out1760 in 0 0 nch W=0.5u L=0.18u
Mp1760 out1760 in vdd vdd pch W=1u L=0.18u
Cl1760 out1760 0 10f
Mn1761 out1761 in 0 0 nch W=0.5u L=0.18u
Mp1761 out1761 in vdd vdd pch W=1u L=0.18u
Cl1761 out1761 0 10f
Mn1762 out1762 in 0 0 nch W=0.5u L=0.18u
Mp1762 out1762 in vdd vdd pch W=1u L=0.18u
Cl1762 out1762 0 10f
Mn1763 out1763 in 0 0 nch W=0.5u L=0.18u
Mp1763 out1763 in vdd vdd pch W=1u L=0.18u
Cl1763 out1763 0 10f
Mn1764 out1764 in 0 0 nch W=0.5u L=0.18u
Mp1764 out1764 in vdd vdd pch W=1u L=0.18u
Cl1764 out1764 0 10f
Mn1765 out1765 in 0 0 nch W=0.5u L=0.18u
Mp1765 out1765 in vdd vdd pch W=1u L=0.18u
Cl1765 out1765 0 10f
Mn1766 out1766 in 0 0 nch W=0.5u L=0.18u
Mp1766 out1766 in vdd vdd pch W=1u L=0.18u
Cl1766 out1766 0 10f
Mn1767 out1767 in 0 0 nch W=0.5u L=0.18u
Mp1767 out1767 in vdd vdd pch W=1u L=0.18u
Cl1767 out1767 0 10f
Mn1768 out1768 in 0 0 nch W=0.5u L=0.18u
Mp1768 out1768 in vdd vdd pch W=1u L=0.18u
Cl1768 out1768 0 10f
Mn1769 out1769 in 0 0 nch W=0.5u L=0.18u
Mp1769 out1769 in vdd vdd pch W=1u L=0.18u
Cl1769 out1769 0 10f
Mn1770 out1770 in 0 0 nch W=0.5u L=0.18u
Mp1770 out1770 in vdd vdd pch W=1u L=0.18u
Cl1770 out1770 0 10f
Mn1771 out1771 in 0 0 nch W=0.5u L=0.18u
Mp1771 out1771 in vdd vdd pch W=1u L=0.18u
Cl1771 out1771 0 10f
Mn1772 out1772 in 0 0 nch W=0.5u L=0.18u
Mp1772 out1772 in vdd vdd pch W=1u L=0.18u
Cl1772 out1772 0 10f
Mn1773 out1773 in 0 0 nch W=0.5u L=0.18u
Mp1773 out1773 in vdd vdd pch W=1u L=0.18u
Cl1773 out1773 0 10f
Mn1774 out1774 in 0 0 nch W=0.5u L=0.18u
Mp1774 out1774 in vdd vdd pch W=1u L=0.18u
Cl1774 out1774 0 10f
Mn1775 out1775 in 0 0 nch W=0.5u L=0.18u
Mp1775 out1775 in vdd vdd pch W=1u L=0.18u
Cl1775 out1775 0 10f
Mn1776 out1776 in 0 0 nch W=0.5u L=0.18u
Mp1776 out1776 in vdd vdd pch W=1u L=0.18u
Cl1776 out1776 0 10f
Mn1777 out1777 in 0 0 nch W=0.5u L=0.18u
Mp1777 out1777 in vdd vdd pch W=1u L=0.18u
Cl1777 out1777 0 10f
Mn1778 out1778 in 0 0 nch W=0.5u L=0.18u
Mp1778 out1778 in vdd vdd pch W=1u L=0.18u
Cl1778 out1778 0 10f
Mn1779 out1779 in 0 0 nch W=0.5u L=0.18u
Mp1779 out1779 in vdd vdd pch W=1u L=0.18u
Cl1779 out1779 0 10f
Mn1780 out1780 in 0 0 nch W=0.5u L=0.18u
Mp1780 out1780 in vdd vdd pch W=1u L=0.18u
Cl1780 out1780 0 10f
Mn1781 out1781 in 0 0 nch W=0.5u L=0.18u
Mp1781 out1781 in vdd vdd pch W=1u L=0.18u
Cl1781 out1781 0 10f
Mn1782 out1782 in 0 0 nch W=0.5u L=0.18u
Mp1782 out1782 in vdd vdd pch W=1u L=0.18u
Cl1782 out1782 0 10f
Mn1783 out1783 in 0 0 nch W=0.5u L=0.18u
Mp1783 out1783 in vdd vdd pch W=1u L=0.18u
Cl1783 out1783 0 10f
Mn1784 out1784 in 0 0 nch W=0.5u L=0.18u
Mp1784 out1784 in vdd vdd pch W=1u L=0.18u
Cl1784 out1784 0 10f
Mn1785 out1785 in 0 0 nch W=0.5u L=0.18u
Mp1785 out1785 in vdd vdd pch W=1u L=0.18u
Cl1785 out1785 0 10f
Mn1786 out1786 in 0 0 nch W=0.5u L=0.18u
Mp1786 out1786 in vdd vdd pch W=1u L=0.18u
Cl1786 out1786 0 10f
Mn1787 out1787 in 0 0 nch W=0.5u L=0.18u
Mp1787 out1787 in vdd vdd pch W=1u L=0.18u
Cl1787 out1787 0 10f
Mn1788 out1788 in 0 0 nch W=0.5u L=0.18u
Mp1788 out1788 in vdd vdd pch W=1u L=0.18u
Cl1788 out1788 0 10f
Mn1789 out1789 in 0 0 nch W=0.5u L=0.18u
Mp1789 out1789 in vdd vdd pch W=1u L=0.18u
Cl1789 out1789 0 10f
Mn1790 out1790 in 0 0 nch W=0.5u L=0.18u
Mp1790 out1790 in vdd vdd pch W=1u L=0.18u
Cl1790 out1790 0 10f
Mn1791 out1791 in 0 0 nch W=0.5u L=0.18u
Mp1791 out1791 in vdd vdd pch W=1u L=0.18u
Cl1791 out1791 0 10f
Mn1792 out1792 in 0 0 nch W=0.5u L=0.18u
Mp1792 out1792 in vdd vdd pch W=1u L=0.18u
Cl1792 out1792 0 10f
Mn1793 out1793 in 0 0 nch W=0.5u L=0.18u
Mp1793 out1793 in vdd vdd pch W=1u L=0.18u
Cl1793 out1793 0 10f
Mn1794 out1794 in 0 0 nch W=0.5u L=0.18u
Mp1794 out1794 in vdd vdd pch W=1u L=0.18u
Cl1794 out1794 0 10f
Mn1795 out1795 in 0 0 nch W=0.5u L=0.18u
Mp1795 out1795 in vdd vdd pch W=1u L=0.18u
Cl1795 out1795 0 10f
Mn1796 out1796 in 0 0 nch W=0.5u L=0.18u
Mp1796 out1796 in vdd vdd pch W=1u L=0.18u
Cl1796 out1796 0 10f
Mn1797 out1797 in 0 0 nch W=0.5u L=0.18u
Mp1797 out1797 in vdd vdd pch W=1u L=0.18u
Cl1797 out1797 0 10f
Mn1798 out1798 in 0 0 nch W=0.5u L=0.18u
Mp1798 out1798 in vdd vdd pch W=1u L=0.18u
Cl1798 out1798 0 10f
Mn1799 out1799 in 0 0 nch W=0.5u L=0.18u
Mp1799 out1799 in vdd vdd pch W=1u L=0.18u
Cl1799 out1799 0 10f
Mn1800 out1800 in 0 0 nch W=0.5u L=0.18u
Mp1800 out1800 in vdd vdd pch W=1u L=0.18u
Cl1800 out1800 0 10f
Mn1801 out1801 in 0 0 nch W=0.5u L=0.18u
Mp1801 out1801 in vdd vdd pch W=1u L=0.18u
Cl1801 out1801 0 10f
Mn1802 out1802 in 0 0 nch W=0.5u L=0.18u
Mp1802 out1802 in vdd vdd pch W=1u L=0.18u
Cl1802 out1802 0 10f
Mn1803 out1803 in 0 0 nch W=0.5u L=0.18u
Mp1803 out1803 in vdd vdd pch W=1u L=0.18u
Cl1803 out1803 0 10f
Mn1804 out1804 in 0 0 nch W=0.5u L=0.18u
Mp1804 out1804 in vdd vdd pch W=1u L=0.18u
Cl1804 out1804 0 10f
Mn1805 out1805 in 0 0 nch W=0.5u L=0.18u
Mp1805 out1805 in vdd vdd pch W=1u L=0.18u
Cl1805 out1805 0 10f
Mn1806 out1806 in 0 0 nch W=0.5u L=0.18u
Mp1806 out1806 in vdd vdd pch W=1u L=0.18u
Cl1806 out1806 0 10f
Mn1807 out1807 in 0 0 nch W=0.5u L=0.18u
Mp1807 out1807 in vdd vdd pch W=1u L=0.18u
Cl1807 out1807 0 10f
Mn1808 out1808 in 0 0 nch W=0.5u L=0.18u
Mp1808 out1808 in vdd vdd pch W=1u L=0.18u
Cl1808 out1808 0 10f
Mn1809 out1809 in 0 0 nch W=0.5u L=0.18u
Mp1809 out1809 in vdd vdd pch W=1u L=0.18u
Cl1809 out1809 0 10f
Mn1810 out1810 in 0 0 nch W=0.5u L=0.18u
Mp1810 out1810 in vdd vdd pch W=1u L=0.18u
Cl1810 out1810 0 10f
Mn1811 out1811 in 0 0 nch W=0.5u L=0.18u
Mp1811 out1811 in vdd vdd pch W=1u L=0.18u
Cl1811 out1811 0 10f
Mn1812 out1812 in 0 0 nch W=0.5u L=0.18u
Mp1812 out1812 in vdd vdd pch W=1u L=0.18u
Cl1812 out1812 0 10f
Mn1813 out1813 in 0 0 nch W=0.5u L=0.18u
Mp1813 out1813 in vdd vdd pch W=1u L=0.18u
Cl1813 out1813 0 10f
Mn1814 out1814 in 0 0 nch W=0.5u L=0.18u
Mp1814 out1814 in vdd vdd pch W=1u L=0.18u
Cl1814 out1814 0 10f
Mn1815 out1815 in 0 0 nch W=0.5u L=0.18u
Mp1815 out1815 in vdd vdd pch W=1u L=0.18u
Cl1815 out1815 0 10f
Mn1816 out1816 in 0 0 nch W=0.5u L=0.18u
Mp1816 out1816 in vdd vdd pch W=1u L=0.18u
Cl1816 out1816 0 10f
Mn1817 out1817 in 0 0 nch W=0.5u L=0.18u
Mp1817 out1817 in vdd vdd pch W=1u L=0.18u
Cl1817 out1817 0 10f
Mn1818 out1818 in 0 0 nch W=0.5u L=0.18u
Mp1818 out1818 in vdd vdd pch W=1u L=0.18u
Cl1818 out1818 0 10f
Mn1819 out1819 in 0 0 nch W=0.5u L=0.18u
Mp1819 out1819 in vdd vdd pch W=1u L=0.18u
Cl1819 out1819 0 10f
Mn1820 out1820 in 0 0 nch W=0.5u L=0.18u
Mp1820 out1820 in vdd vdd pch W=1u L=0.18u
Cl1820 out1820 0 10f
Mn1821 out1821 in 0 0 nch W=0.5u L=0.18u
Mp1821 out1821 in vdd vdd pch W=1u L=0.18u
Cl1821 out1821 0 10f
Mn1822 out1822 in 0 0 nch W=0.5u L=0.18u
Mp1822 out1822 in vdd vdd pch W=1u L=0.18u
Cl1822 out1822 0 10f
Mn1823 out1823 in 0 0 nch W=0.5u L=0.18u
Mp1823 out1823 in vdd vdd pch W=1u L=0.18u
Cl1823 out1823 0 10f
Mn1824 out1824 in 0 0 nch W=0.5u L=0.18u
Mp1824 out1824 in vdd vdd pch W=1u L=0.18u
Cl1824 out1824 0 10f
Mn1825 out1825 in 0 0 nch W=0.5u L=0.18u
Mp1825 out1825 in vdd vdd pch W=1u L=0.18u
Cl1825 out1825 0 10f
Mn1826 out1826 in 0 0 nch W=0.5u L=0.18u
Mp1826 out1826 in vdd vdd pch W=1u L=0.18u
Cl1826 out1826 0 10f
Mn1827 out1827 in 0 0 nch W=0.5u L=0.18u
Mp1827 out1827 in vdd vdd pch W=1u L=0.18u
Cl1827 out1827 0 10f
Mn1828 out1828 in 0 0 nch W=0.5u L=0.18u
Mp1828 out1828 in vdd vdd pch W=1u L=0.18u
Cl1828 out1828 0 10f
Mn1829 out1829 in 0 0 nch W=0.5u L=0.18u
Mp1829 out1829 in vdd vdd pch W=1u L=0.18u
Cl1829 out1829 0 10f
Mn1830 out1830 in 0 0 nch W=0.5u L=0.18u
Mp1830 out1830 in vdd vdd pch W=1u L=0.18u
Cl1830 out1830 0 10f
Mn1831 out1831 in 0 0 nch W=0.5u L=0.18u
Mp1831 out1831 in vdd vdd pch W=1u L=0.18u
Cl1831 out1831 0 10f
Mn1832 out1832 in 0 0 nch W=0.5u L=0.18u
Mp1832 out1832 in vdd vdd pch W=1u L=0.18u
Cl1832 out1832 0 10f
Mn1833 out1833 in 0 0 nch W=0.5u L=0.18u
Mp1833 out1833 in vdd vdd pch W=1u L=0.18u
Cl1833 out1833 0 10f
Mn1834 out1834 in 0 0 nch W=0.5u L=0.18u
Mp1834 out1834 in vdd vdd pch W=1u L=0.18u
Cl1834 out1834 0 10f
Mn1835 out1835 in 0 0 nch W=0.5u L=0.18u
Mp1835 out1835 in vdd vdd pch W=1u L=0.18u
Cl1835 out1835 0 10f
Mn1836 out1836 in 0 0 nch W=0.5u L=0.18u
Mp1836 out1836 in vdd vdd pch W=1u L=0.18u
Cl1836 out1836 0 10f
Mn1837 out1837 in 0 0 nch W=0.5u L=0.18u
Mp1837 out1837 in vdd vdd pch W=1u L=0.18u
Cl1837 out1837 0 10f
Mn1838 out1838 in 0 0 nch W=0.5u L=0.18u
Mp1838 out1838 in vdd vdd pch W=1u L=0.18u
Cl1838 out1838 0 10f
Mn1839 out1839 in 0 0 nch W=0.5u L=0.18u
Mp1839 out1839 in vdd vdd pch W=1u L=0.18u
Cl1839 out1839 0 10f
Mn1840 out1840 in 0 0 nch W=0.5u L=0.18u
Mp1840 out1840 in vdd vdd pch W=1u L=0.18u
Cl1840 out1840 0 10f
Mn1841 out1841 in 0 0 nch W=0.5u L=0.18u
Mp1841 out1841 in vdd vdd pch W=1u L=0.18u
Cl1841 out1841 0 10f
Mn1842 out1842 in 0 0 nch W=0.5u L=0.18u
Mp1842 out1842 in vdd vdd pch W=1u L=0.18u
Cl1842 out1842 0 10f
Mn1843 out1843 in 0 0 nch W=0.5u L=0.18u
Mp1843 out1843 in vdd vdd pch W=1u L=0.18u
Cl1843 out1843 0 10f
Mn1844 out1844 in 0 0 nch W=0.5u L=0.18u
Mp1844 out1844 in vdd vdd pch W=1u L=0.18u
Cl1844 out1844 0 10f
Mn1845 out1845 in 0 0 nch W=0.5u L=0.18u
Mp1845 out1845 in vdd vdd pch W=1u L=0.18u
Cl1845 out1845 0 10f
Mn1846 out1846 in 0 0 nch W=0.5u L=0.18u
Mp1846 out1846 in vdd vdd pch W=1u L=0.18u
Cl1846 out1846 0 10f
Mn1847 out1847 in 0 0 nch W=0.5u L=0.18u
Mp1847 out1847 in vdd vdd pch W=1u L=0.18u
Cl1847 out1847 0 10f
Mn1848 out1848 in 0 0 nch W=0.5u L=0.18u
Mp1848 out1848 in vdd vdd pch W=1u L=0.18u
Cl1848 out1848 0 10f
Mn1849 out1849 in 0 0 nch W=0.5u L=0.18u
Mp1849 out1849 in vdd vdd pch W=1u L=0.18u
Cl1849 out1849 0 10f
Mn1850 out1850 in 0 0 nch W=0.5u L=0.18u
Mp1850 out1850 in vdd vdd pch W=1u L=0.18u
Cl1850 out1850 0 10f
Mn1851 out1851 in 0 0 nch W=0.5u L=0.18u
Mp1851 out1851 in vdd vdd pch W=1u L=0.18u
Cl1851 out1851 0 10f
Mn1852 out1852 in 0 0 nch W=0.5u L=0.18u
Mp1852 out1852 in vdd vdd pch W=1u L=0.18u
Cl1852 out1852 0 10f
Mn1853 out1853 in 0 0 nch W=0.5u L=0.18u
Mp1853 out1853 in vdd vdd pch W=1u L=0.18u
Cl1853 out1853 0 10f
Mn1854 out1854 in 0 0 nch W=0.5u L=0.18u
Mp1854 out1854 in vdd vdd pch W=1u L=0.18u
Cl1854 out1854 0 10f
Mn1855 out1855 in 0 0 nch W=0.5u L=0.18u
Mp1855 out1855 in vdd vdd pch W=1u L=0.18u
Cl1855 out1855 0 10f
Mn1856 out1856 in 0 0 nch W=0.5u L=0.18u
Mp1856 out1856 in vdd vdd pch W=1u L=0.18u
Cl1856 out1856 0 10f
Mn1857 out1857 in 0 0 nch W=0.5u L=0.18u
Mp1857 out1857 in vdd vdd pch W=1u L=0.18u
Cl1857 out1857 0 10f
Mn1858 out1858 in 0 0 nch W=0.5u L=0.18u
Mp1858 out1858 in vdd vdd pch W=1u L=0.18u
Cl1858 out1858 0 10f
Mn1859 out1859 in 0 0 nch W=0.5u L=0.18u
Mp1859 out1859 in vdd vdd pch W=1u L=0.18u
Cl1859 out1859 0 10f
Mn1860 out1860 in 0 0 nch W=0.5u L=0.18u
Mp1860 out1860 in vdd vdd pch W=1u L=0.18u
Cl1860 out1860 0 10f
Mn1861 out1861 in 0 0 nch W=0.5u L=0.18u
Mp1861 out1861 in vdd vdd pch W=1u L=0.18u
Cl1861 out1861 0 10f
Mn1862 out1862 in 0 0 nch W=0.5u L=0.18u
Mp1862 out1862 in vdd vdd pch W=1u L=0.18u
Cl1862 out1862 0 10f
Mn1863 out1863 in 0 0 nch W=0.5u L=0.18u
Mp1863 out1863 in vdd vdd pch W=1u L=0.18u
Cl1863 out1863 0 10f
Mn1864 out1864 in 0 0 nch W=0.5u L=0.18u
Mp1864 out1864 in vdd vdd pch W=1u L=0.18u
Cl1864 out1864 0 10f
Mn1865 out1865 in 0 0 nch W=0.5u L=0.18u
Mp1865 out1865 in vdd vdd pch W=1u L=0.18u
Cl1865 out1865 0 10f
Mn1866 out1866 in 0 0 nch W=0.5u L=0.18u
Mp1866 out1866 in vdd vdd pch W=1u L=0.18u
Cl1866 out1866 0 10f
Mn1867 out1867 in 0 0 nch W=0.5u L=0.18u
Mp1867 out1867 in vdd vdd pch W=1u L=0.18u
Cl1867 out1867 0 10f
Mn1868 out1868 in 0 0 nch W=0.5u L=0.18u
Mp1868 out1868 in vdd vdd pch W=1u L=0.18u
Cl1868 out1868 0 10f
Mn1869 out1869 in 0 0 nch W=0.5u L=0.18u
Mp1869 out1869 in vdd vdd pch W=1u L=0.18u
Cl1869 out1869 0 10f
Mn1870 out1870 in 0 0 nch W=0.5u L=0.18u
Mp1870 out1870 in vdd vdd pch W=1u L=0.18u
Cl1870 out1870 0 10f
Mn1871 out1871 in 0 0 nch W=0.5u L=0.18u
Mp1871 out1871 in vdd vdd pch W=1u L=0.18u
Cl1871 out1871 0 10f
Mn1872 out1872 in 0 0 nch W=0.5u L=0.18u
Mp1872 out1872 in vdd vdd pch W=1u L=0.18u
Cl1872 out1872 0 10f
Mn1873 out1873 in 0 0 nch W=0.5u L=0.18u
Mp1873 out1873 in vdd vdd pch W=1u L=0.18u
Cl1873 out1873 0 10f
Mn1874 out1874 in 0 0 nch W=0.5u L=0.18u
Mp1874 out1874 in vdd vdd pch W=1u L=0.18u
Cl1874 out1874 0 10f
Mn1875 out1875 in 0 0 nch W=0.5u L=0.18u
Mp1875 out1875 in vdd vdd pch W=1u L=0.18u
Cl1875 out1875 0 10f
Mn1876 out1876 in 0 0 nch W=0.5u L=0.18u
Mp1876 out1876 in vdd vdd pch W=1u L=0.18u
Cl1876 out1876 0 10f
Mn1877 out1877 in 0 0 nch W=0.5u L=0.18u
Mp1877 out1877 in vdd vdd pch W=1u L=0.18u
Cl1877 out1877 0 10f
Mn1878 out1878 in 0 0 nch W=0.5u L=0.18u
Mp1878 out1878 in vdd vdd pch W=1u L=0.18u
Cl1878 out1878 0 10f
Mn1879 out1879 in 0 0 nch W=0.5u L=0.18u
Mp1879 out1879 in vdd vdd pch W=1u L=0.18u
Cl1879 out1879 0 10f
Mn1880 out1880 in 0 0 nch W=0.5u L=0.18u
Mp1880 out1880 in vdd vdd pch W=1u L=0.18u
Cl1880 out1880 0 10f
Mn1881 out1881 in 0 0 nch W=0.5u L=0.18u
Mp1881 out1881 in vdd vdd pch W=1u L=0.18u
Cl1881 out1881 0 10f
Mn1882 out1882 in 0 0 nch W=0.5u L=0.18u
Mp1882 out1882 in vdd vdd pch W=1u L=0.18u
Cl1882 out1882 0 10f
Mn1883 out1883 in 0 0 nch W=0.5u L=0.18u
Mp1883 out1883 in vdd vdd pch W=1u L=0.18u
Cl1883 out1883 0 10f
Mn1884 out1884 in 0 0 nch W=0.5u L=0.18u
Mp1884 out1884 in vdd vdd pch W=1u L=0.18u
Cl1884 out1884 0 10f
Mn1885 out1885 in 0 0 nch W=0.5u L=0.18u
Mp1885 out1885 in vdd vdd pch W=1u L=0.18u
Cl1885 out1885 0 10f
Mn1886 out1886 in 0 0 nch W=0.5u L=0.18u
Mp1886 out1886 in vdd vdd pch W=1u L=0.18u
Cl1886 out1886 0 10f
Mn1887 out1887 in 0 0 nch W=0.5u L=0.18u
Mp1887 out1887 in vdd vdd pch W=1u L=0.18u
Cl1887 out1887 0 10f
Mn1888 out1888 in 0 0 nch W=0.5u L=0.18u
Mp1888 out1888 in vdd vdd pch W=1u L=0.18u
Cl1888 out1888 0 10f
Mn1889 out1889 in 0 0 nch W=0.5u L=0.18u
Mp1889 out1889 in vdd vdd pch W=1u L=0.18u
Cl1889 out1889 0 10f
Mn1890 out1890 in 0 0 nch W=0.5u L=0.18u
Mp1890 out1890 in vdd vdd pch W=1u L=0.18u
Cl1890 out1890 0 10f
Mn1891 out1891 in 0 0 nch W=0.5u L=0.18u
Mp1891 out1891 in vdd vdd pch W=1u L=0.18u
Cl1891 out1891 0 10f
Mn1892 out1892 in 0 0 nch W=0.5u L=0.18u
Mp1892 out1892 in vdd vdd pch W=1u L=0.18u
Cl1892 out1892 0 10f
Mn1893 out1893 in 0 0 nch W=0.5u L=0.18u
Mp1893 out1893 in vdd vdd pch W=1u L=0.18u
Cl1893 out1893 0 10f
Mn1894 out1894 in 0 0 nch W=0.5u L=0.18u
Mp1894 out1894 in vdd vdd pch W=1u L=0.18u
Cl1894 out1894 0 10f
Mn1895 out1895 in 0 0 nch W=0.5u L=0.18u
Mp1895 out1895 in vdd vdd pch W=1u L=0.18u
Cl1895 out1895 0 10f
Mn1896 out1896 in 0 0 nch W=0.5u L=0.18u
Mp1896 out1896 in vdd vdd pch W=1u L=0.18u
Cl1896 out1896 0 10f
Mn1897 out1897 in 0 0 nch W=0.5u L=0.18u
Mp1897 out1897 in vdd vdd pch W=1u L=0.18u
Cl1897 out1897 0 10f
Mn1898 out1898 in 0 0 nch W=0.5u L=0.18u
Mp1898 out1898 in vdd vdd pch W=1u L=0.18u
Cl1898 out1898 0 10f
Mn1899 out1899 in 0 0 nch W=0.5u L=0.18u
Mp1899 out1899 in vdd vdd pch W=1u L=0.18u
Cl1899 out1899 0 10f
Mn1900 out1900 in 0 0 nch W=0.5u L=0.18u
Mp1900 out1900 in vdd vdd pch W=1u L=0.18u
Cl1900 out1900 0 10f
Mn1901 out1901 in 0 0 nch W=0.5u L=0.18u
Mp1901 out1901 in vdd vdd pch W=1u L=0.18u
Cl1901 out1901 0 10f
Mn1902 out1902 in 0 0 nch W=0.5u L=0.18u
Mp1902 out1902 in vdd vdd pch W=1u L=0.18u
Cl1902 out1902 0 10f
Mn1903 out1903 in 0 0 nch W=0.5u L=0.18u
Mp1903 out1903 in vdd vdd pch W=1u L=0.18u
Cl1903 out1903 0 10f
Mn1904 out1904 in 0 0 nch W=0.5u L=0.18u
Mp1904 out1904 in vdd vdd pch W=1u L=0.18u
Cl1904 out1904 0 10f
Mn1905 out1905 in 0 0 nch W=0.5u L=0.18u
Mp1905 out1905 in vdd vdd pch W=1u L=0.18u
Cl1905 out1905 0 10f
Mn1906 out1906 in 0 0 nch W=0.5u L=0.18u
Mp1906 out1906 in vdd vdd pch W=1u L=0.18u
Cl1906 out1906 0 10f
Mn1907 out1907 in 0 0 nch W=0.5u L=0.18u
Mp1907 out1907 in vdd vdd pch W=1u L=0.18u
Cl1907 out1907 0 10f
Mn1908 out1908 in 0 0 nch W=0.5u L=0.18u
Mp1908 out1908 in vdd vdd pch W=1u L=0.18u
Cl1908 out1908 0 10f
Mn1909 out1909 in 0 0 nch W=0.5u L=0.18u
Mp1909 out1909 in vdd vdd pch W=1u L=0.18u
Cl1909 out1909 0 10f
Mn1910 out1910 in 0 0 nch W=0.5u L=0.18u
Mp1910 out1910 in vdd vdd pch W=1u L=0.18u
Cl1910 out1910 0 10f
Mn1911 out1911 in 0 0 nch W=0.5u L=0.18u
Mp1911 out1911 in vdd vdd pch W=1u L=0.18u
Cl1911 out1911 0 10f
Mn1912 out1912 in 0 0 nch W=0.5u L=0.18u
Mp1912 out1912 in vdd vdd pch W=1u L=0.18u
Cl1912 out1912 0 10f
Mn1913 out1913 in 0 0 nch W=0.5u L=0.18u
Mp1913 out1913 in vdd vdd pch W=1u L=0.18u
Cl1913 out1913 0 10f
Mn1914 out1914 in 0 0 nch W=0.5u L=0.18u
Mp1914 out1914 in vdd vdd pch W=1u L=0.18u
Cl1914 out1914 0 10f
Mn1915 out1915 in 0 0 nch W=0.5u L=0.18u
Mp1915 out1915 in vdd vdd pch W=1u L=0.18u
Cl1915 out1915 0 10f
Mn1916 out1916 in 0 0 nch W=0.5u L=0.18u
Mp1916 out1916 in vdd vdd pch W=1u L=0.18u
Cl1916 out1916 0 10f
Mn1917 out1917 in 0 0 nch W=0.5u L=0.18u
Mp1917 out1917 in vdd vdd pch W=1u L=0.18u
Cl1917 out1917 0 10f
Mn1918 out1918 in 0 0 nch W=0.5u L=0.18u
Mp1918 out1918 in vdd vdd pch W=1u L=0.18u
Cl1918 out1918 0 10f
Mn1919 out1919 in 0 0 nch W=0.5u L=0.18u
Mp1919 out1919 in vdd vdd pch W=1u L=0.18u
Cl1919 out1919 0 10f
Mn1920 out1920 in 0 0 nch W=0.5u L=0.18u
Mp1920 out1920 in vdd vdd pch W=1u L=0.18u
Cl1920 out1920 0 10f
Mn1921 out1921 in 0 0 nch W=0.5u L=0.18u
Mp1921 out1921 in vdd vdd pch W=1u L=0.18u
Cl1921 out1921 0 10f
Mn1922 out1922 in 0 0 nch W=0.5u L=0.18u
Mp1922 out1922 in vdd vdd pch W=1u L=0.18u
Cl1922 out1922 0 10f
Mn1923 out1923 in 0 0 nch W=0.5u L=0.18u
Mp1923 out1923 in vdd vdd pch W=1u L=0.18u
Cl1923 out1923 0 10f
Mn1924 out1924 in 0 0 nch W=0.5u L=0.18u
Mp1924 out1924 in vdd vdd pch W=1u L=0.18u
Cl1924 out1924 0 10f
Mn1925 out1925 in 0 0 nch W=0.5u L=0.18u
Mp1925 out1925 in vdd vdd pch W=1u L=0.18u
Cl1925 out1925 0 10f
Mn1926 out1926 in 0 0 nch W=0.5u L=0.18u
Mp1926 out1926 in vdd vdd pch W=1u L=0.18u
Cl1926 out1926 0 10f
Mn1927 out1927 in 0 0 nch W=0.5u L=0.18u
Mp1927 out1927 in vdd vdd pch W=1u L=0.18u
Cl1927 out1927 0 10f
Mn1928 out1928 in 0 0 nch W=0.5u L=0.18u
Mp1928 out1928 in vdd vdd pch W=1u L=0.18u
Cl1928 out1928 0 10f
Mn1929 out1929 in 0 0 nch W=0.5u L=0.18u
Mp1929 out1929 in vdd vdd pch W=1u L=0.18u
Cl1929 out1929 0 10f
Mn1930 out1930 in 0 0 nch W=0.5u L=0.18u
Mp1930 out1930 in vdd vdd pch W=1u L=0.18u
Cl1930 out1930 0 10f
Mn1931 out1931 in 0 0 nch W=0.5u L=0.18u
Mp1931 out1931 in vdd vdd pch W=1u L=0.18u
Cl1931 out1931 0 10f
Mn1932 out1932 in 0 0 nch W=0.5u L=0.18u
Mp1932 out1932 in vdd vdd pch W=1u L=0.18u
Cl1932 out1932 0 10f
Mn1933 out1933 in 0 0 nch W=0.5u L=0.18u
Mp1933 out1933 in vdd vdd pch W=1u L=0.18u
Cl1933 out1933 0 10f
Mn1934 out1934 in 0 0 nch W=0.5u L=0.18u
Mp1934 out1934 in vdd vdd pch W=1u L=0.18u
Cl1934 out1934 0 10f
Mn1935 out1935 in 0 0 nch W=0.5u L=0.18u
Mp1935 out1935 in vdd vdd pch W=1u L=0.18u
Cl1935 out1935 0 10f
Mn1936 out1936 in 0 0 nch W=0.5u L=0.18u
Mp1936 out1936 in vdd vdd pch W=1u L=0.18u
Cl1936 out1936 0 10f
Mn1937 out1937 in 0 0 nch W=0.5u L=0.18u
Mp1937 out1937 in vdd vdd pch W=1u L=0.18u
Cl1937 out1937 0 10f
Mn1938 out1938 in 0 0 nch W=0.5u L=0.18u
Mp1938 out1938 in vdd vdd pch W=1u L=0.18u
Cl1938 out1938 0 10f
Mn1939 out1939 in 0 0 nch W=0.5u L=0.18u
Mp1939 out1939 in vdd vdd pch W=1u L=0.18u
Cl1939 out1939 0 10f
Mn1940 out1940 in 0 0 nch W=0.5u L=0.18u
Mp1940 out1940 in vdd vdd pch W=1u L=0.18u
Cl1940 out1940 0 10f
Mn1941 out1941 in 0 0 nch W=0.5u L=0.18u
Mp1941 out1941 in vdd vdd pch W=1u L=0.18u
Cl1941 out1941 0 10f
Mn1942 out1942 in 0 0 nch W=0.5u L=0.18u
Mp1942 out1942 in vdd vdd pch W=1u L=0.18u
Cl1942 out1942 0 10f
Mn1943 out1943 in 0 0 nch W=0.5u L=0.18u
Mp1943 out1943 in vdd vdd pch W=1u L=0.18u
Cl1943 out1943 0 10f
Mn1944 out1944 in 0 0 nch W=0.5u L=0.18u
Mp1944 out1944 in vdd vdd pch W=1u L=0.18u
Cl1944 out1944 0 10f
Mn1945 out1945 in 0 0 nch W=0.5u L=0.18u
Mp1945 out1945 in vdd vdd pch W=1u L=0.18u
Cl1945 out1945 0 10f
Mn1946 out1946 in 0 0 nch W=0.5u L=0.18u
Mp1946 out1946 in vdd vdd pch W=1u L=0.18u
Cl1946 out1946 0 10f
Mn1947 out1947 in 0 0 nch W=0.5u L=0.18u
Mp1947 out1947 in vdd vdd pch W=1u L=0.18u
Cl1947 out1947 0 10f
Mn1948 out1948 in 0 0 nch W=0.5u L=0.18u
Mp1948 out1948 in vdd vdd pch W=1u L=0.18u
Cl1948 out1948 0 10f
Mn1949 out1949 in 0 0 nch W=0.5u L=0.18u
Mp1949 out1949 in vdd vdd pch W=1u L=0.18u
Cl1949 out1949 0 10f
Mn1950 out1950 in 0 0 nch W=0.5u L=0.18u
Mp1950 out1950 in vdd vdd pch W=1u L=0.18u
Cl1950 out1950 0 10f
Mn1951 out1951 in 0 0 nch W=0.5u L=0.18u
Mp1951 out1951 in vdd vdd pch W=1u L=0.18u
Cl1951 out1951 0 10f
Mn1952 out1952 in 0 0 nch W=0.5u L=0.18u
Mp1952 out1952 in vdd vdd pch W=1u L=0.18u
Cl1952 out1952 0 10f
Mn1953 out1953 in 0 0 nch W=0.5u L=0.18u
Mp1953 out1953 in vdd vdd pch W=1u L=0.18u
Cl1953 out1953 0 10f
Mn1954 out1954 in 0 0 nch W=0.5u L=0.18u
Mp1954 out1954 in vdd vdd pch W=1u L=0.18u
Cl1954 out1954 0 10f
Mn1955 out1955 in 0 0 nch W=0.5u L=0.18u
Mp1955 out1955 in vdd vdd pch W=1u L=0.18u
Cl1955 out1955 0 10f
Mn1956 out1956 in 0 0 nch W=0.5u L=0.18u
Mp1956 out1956 in vdd vdd pch W=1u L=0.18u
Cl1956 out1956 0 10f
Mn1957 out1957 in 0 0 nch W=0.5u L=0.18u
Mp1957 out1957 in vdd vdd pch W=1u L=0.18u
Cl1957 out1957 0 10f
Mn1958 out1958 in 0 0 nch W=0.5u L=0.18u
Mp1958 out1958 in vdd vdd pch W=1u L=0.18u
Cl1958 out1958 0 10f
Mn1959 out1959 in 0 0 nch W=0.5u L=0.18u
Mp1959 out1959 in vdd vdd pch W=1u L=0.18u
Cl1959 out1959 0 10f
Mn1960 out1960 in 0 0 nch W=0.5u L=0.18u
Mp1960 out1960 in vdd vdd pch W=1u L=0.18u
Cl1960 out1960 0 10f
Mn1961 out1961 in 0 0 nch W=0.5u L=0.18u
Mp1961 out1961 in vdd vdd pch W=1u L=0.18u
Cl1961 out1961 0 10f
Mn1962 out1962 in 0 0 nch W=0.5u L=0.18u
Mp1962 out1962 in vdd vdd pch W=1u L=0.18u
Cl1962 out1962 0 10f
Mn1963 out1963 in 0 0 nch W=0.5u L=0.18u
Mp1963 out1963 in vdd vdd pch W=1u L=0.18u
Cl1963 out1963 0 10f
Mn1964 out1964 in 0 0 nch W=0.5u L=0.18u
Mp1964 out1964 in vdd vdd pch W=1u L=0.18u
Cl1964 out1964 0 10f
Mn1965 out1965 in 0 0 nch W=0.5u L=0.18u
Mp1965 out1965 in vdd vdd pch W=1u L=0.18u
Cl1965 out1965 0 10f
Mn1966 out1966 in 0 0 nch W=0.5u L=0.18u
Mp1966 out1966 in vdd vdd pch W=1u L=0.18u
Cl1966 out1966 0 10f
Mn1967 out1967 in 0 0 nch W=0.5u L=0.18u
Mp1967 out1967 in vdd vdd pch W=1u L=0.18u
Cl1967 out1967 0 10f
Mn1968 out1968 in 0 0 nch W=0.5u L=0.18u
Mp1968 out1968 in vdd vdd pch W=1u L=0.18u
Cl1968 out1968 0 10f
Mn1969 out1969 in 0 0 nch W=0.5u L=0.18u
Mp1969 out1969 in vdd vdd pch W=1u L=0.18u
Cl1969 out1969 0 10f
Mn1970 out1970 in 0 0 nch W=0.5u L=0.18u
Mp1970 out1970 in vdd vdd pch W=1u L=0.18u
Cl1970 out1970 0 10f
Mn1971 out1971 in 0 0 nch W=0.5u L=0.18u
Mp1971 out1971 in vdd vdd pch W=1u L=0.18u
Cl1971 out1971 0 10f
Mn1972 out1972 in 0 0 nch W=0.5u L=0.18u
Mp1972 out1972 in vdd vdd pch W=1u L=0.18u
Cl1972 out1972 0 10f
Mn1973 out1973 in 0 0 nch W=0.5u L=0.18u
Mp1973 out1973 in vdd vdd pch W=1u L=0.18u
Cl1973 out1973 0 10f
Mn1974 out1974 in 0 0 nch W=0.5u L=0.18u
Mp1974 out1974 in vdd vdd pch W=1u L=0.18u
Cl1974 out1974 0 10f
Mn1975 out1975 in 0 0 nch W=0.5u L=0.18u
Mp1975 out1975 in vdd vdd pch W=1u L=0.18u
Cl1975 out1975 0 10f
Mn1976 out1976 in 0 0 nch W=0.5u L=0.18u
Mp1976 out1976 in vdd vdd pch W=1u L=0.18u
Cl1976 out1976 0 10f
Mn1977 out1977 in 0 0 nch W=0.5u L=0.18u
Mp1977 out1977 in vdd vdd pch W=1u L=0.18u
Cl1977 out1977 0 10f
Mn1978 out1978 in 0 0 nch W=0.5u L=0.18u
Mp1978 out1978 in vdd vdd pch W=1u L=0.18u
Cl1978 out1978 0 10f
Mn1979 out1979 in 0 0 nch W=0.5u L=0.18u
Mp1979 out1979 in vdd vdd pch W=1u L=0.18u
Cl1979 out1979 0 10f
Mn1980 out1980 in 0 0 nch W=0.5u L=0.18u
Mp1980 out1980 in vdd vdd pch W=1u L=0.18u
Cl1980 out1980 0 10f
Mn1981 out1981 in 0 0 nch W=0.5u L=0.18u
Mp1981 out1981 in vdd vdd pch W=1u L=0.18u
Cl1981 out1981 0 10f
Mn1982 out1982 in 0 0 nch W=0.5u L=0.18u
Mp1982 out1982 in vdd vdd pch W=1u L=0.18u
Cl1982 out1982 0 10f
Mn1983 out1983 in 0 0 nch W=0.5u L=0.18u
Mp1983 out1983 in vdd vdd pch W=1u L=0.18u
Cl1983 out1983 0 10f
Mn1984 out1984 in 0 0 nch W=0.5u L=0.18u
Mp1984 out1984 in vdd vdd pch W=1u L=0.18u
Cl1984 out1984 0 10f
Mn1985 out1985 in 0 0 nch W=0.5u L=0.18u
Mp1985 out1985 in vdd vdd pch W=1u L=0.18u
Cl1985 out1985 0 10f
Mn1986 out1986 in 0 0 nch W=0.5u L=0.18u
Mp1986 out1986 in vdd vdd pch W=1u L=0.18u
Cl1986 out1986 0 10f
Mn1987 out1987 in 0 0 nch W=0.5u L=0.18u
Mp1987 out1987 in vdd vdd pch W=1u L=0.18u
Cl1987 out1987 0 10f
Mn1988 out1988 in 0 0 nch W=0.5u L=0.18u
Mp1988 out1988 in vdd vdd pch W=1u L=0.18u
Cl1988 out1988 0 10f
Mn1989 out1989 in 0 0 nch W=0.5u L=0.18u
Mp1989 out1989 in vdd vdd pch W=1u L=0.18u
Cl1989 out1989 0 10f
Mn1990 out1990 in 0 0 nch W=0.5u L=0.18u
Mp1990 out1990 in vdd vdd pch W=1u L=0.18u
Cl1990 out1990 0 10f
Mn1991 out1991 in 0 0 nch W=0.5u L=0.18u
Mp1991 out1991 in vdd vdd pch W=1u L=0.18u
Cl1991 out1991 0 10f
Mn1992 out1992 in 0 0 nch W=0.5u L=0.18u
Mp1992 out1992 in vdd vdd pch W=1u L=0.18u
Cl1992 out1992 0 10f
Mn1993 out1993 in 0 0 nch W=0.5u L=0.18u
Mp1993 out1993 in vdd vdd pch W=1u L=0.18u
Cl1993 out1993 0 10f
Mn1994 out1994 in 0 0 nch W=0.5u L=0.18u
Mp1994 out1994 in vdd vdd pch W=1u L=0.18u
Cl1994 out1994 0 10f
Mn1995 out1995 in 0 0 nch W=0.5u L=0.18u
Mp1995 out1995 in vdd vdd pch W=1u L=0.18u
Cl1995 out1995 0 10f
Mn1996 out1996 in 0 0 nch W=0.5u L=0.18u
Mp1996 out1996 in vdd vdd pch W=1u L=0.18u
Cl1996 out1996 0 10f
Mn1997 out1997 in 0 0 nch W=0.5u L=0.18u
Mp1997 out1997 in vdd vdd pch W=1u L=0.18u
Cl1997 out1997 0 10f
Mn1998 out1998 in 0 0 nch W=0.5u L=0.18u
Mp1998 out1998 in vdd vdd pch W=1u L=0.18u
Cl1998 out1998 0 10f
Mn1999 out1999 in 0 0 nch W=0.5u L=0.18u
Mp1999 out1999 in vdd vdd pch W=1u L=0.18u
Cl1999 out1999 0 10f
Mn2000 out2000 in 0 0 nch W=0.5u L=0.18u
Mp2000 out2000 in vdd vdd pch W=1u L=0.18u
Cl2000 out2000 0 10f
.tran 0.1n 50n
.end
