* Parallel CMOS inverters: 100 instances — GPU batch stress test
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
.tran 0.1n 50n
.end
