* CMOS Inverter Chain — 50 stages
VDD vdd 0 DC 3.3
VIN in 0 PULSE(0 3.3 1n 0.5n 0.5n 10n 20n)

.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)

Mn1 n1 in 0 0 NMOD W=10u L=1u
Mp1 n1 in vdd vdd PMOD W=20u L=1u
CL1 n1 0 0.01p
Mn2 n2 n1 0 0 NMOD W=10u L=1u
Mp2 n2 n1 vdd vdd PMOD W=20u L=1u
CL2 n2 0 0.01p
Mn3 n3 n2 0 0 NMOD W=10u L=1u
Mp3 n3 n2 vdd vdd PMOD W=20u L=1u
CL3 n3 0 0.01p
Mn4 n4 n3 0 0 NMOD W=10u L=1u
Mp4 n4 n3 vdd vdd PMOD W=20u L=1u
CL4 n4 0 0.01p
Mn5 n5 n4 0 0 NMOD W=10u L=1u
Mp5 n5 n4 vdd vdd PMOD W=20u L=1u
CL5 n5 0 0.01p
Mn6 n6 n5 0 0 NMOD W=10u L=1u
Mp6 n6 n5 vdd vdd PMOD W=20u L=1u
CL6 n6 0 0.01p
Mn7 n7 n6 0 0 NMOD W=10u L=1u
Mp7 n7 n6 vdd vdd PMOD W=20u L=1u
CL7 n7 0 0.01p
Mn8 n8 n7 0 0 NMOD W=10u L=1u
Mp8 n8 n7 vdd vdd PMOD W=20u L=1u
CL8 n8 0 0.01p
Mn9 n9 n8 0 0 NMOD W=10u L=1u
Mp9 n9 n8 vdd vdd PMOD W=20u L=1u
CL9 n9 0 0.01p
Mn10 n10 n9 0 0 NMOD W=10u L=1u
Mp10 n10 n9 vdd vdd PMOD W=20u L=1u
CL10 n10 0 0.01p
Mn11 n11 n10 0 0 NMOD W=10u L=1u
Mp11 n11 n10 vdd vdd PMOD W=20u L=1u
CL11 n11 0 0.01p
Mn12 n12 n11 0 0 NMOD W=10u L=1u
Mp12 n12 n11 vdd vdd PMOD W=20u L=1u
CL12 n12 0 0.01p
Mn13 n13 n12 0 0 NMOD W=10u L=1u
Mp13 n13 n12 vdd vdd PMOD W=20u L=1u
CL13 n13 0 0.01p
Mn14 n14 n13 0 0 NMOD W=10u L=1u
Mp14 n14 n13 vdd vdd PMOD W=20u L=1u
CL14 n14 0 0.01p
Mn15 n15 n14 0 0 NMOD W=10u L=1u
Mp15 n15 n14 vdd vdd PMOD W=20u L=1u
CL15 n15 0 0.01p
Mn16 n16 n15 0 0 NMOD W=10u L=1u
Mp16 n16 n15 vdd vdd PMOD W=20u L=1u
CL16 n16 0 0.01p
Mn17 n17 n16 0 0 NMOD W=10u L=1u
Mp17 n17 n16 vdd vdd PMOD W=20u L=1u
CL17 n17 0 0.01p
Mn18 n18 n17 0 0 NMOD W=10u L=1u
Mp18 n18 n17 vdd vdd PMOD W=20u L=1u
CL18 n18 0 0.01p
Mn19 n19 n18 0 0 NMOD W=10u L=1u
Mp19 n19 n18 vdd vdd PMOD W=20u L=1u
CL19 n19 0 0.01p
Mn20 n20 n19 0 0 NMOD W=10u L=1u
Mp20 n20 n19 vdd vdd PMOD W=20u L=1u
CL20 n20 0 0.01p
Mn21 n21 n20 0 0 NMOD W=10u L=1u
Mp21 n21 n20 vdd vdd PMOD W=20u L=1u
CL21 n21 0 0.01p
Mn22 n22 n21 0 0 NMOD W=10u L=1u
Mp22 n22 n21 vdd vdd PMOD W=20u L=1u
CL22 n22 0 0.01p
Mn23 n23 n22 0 0 NMOD W=10u L=1u
Mp23 n23 n22 vdd vdd PMOD W=20u L=1u
CL23 n23 0 0.01p
Mn24 n24 n23 0 0 NMOD W=10u L=1u
Mp24 n24 n23 vdd vdd PMOD W=20u L=1u
CL24 n24 0 0.01p
Mn25 n25 n24 0 0 NMOD W=10u L=1u
Mp25 n25 n24 vdd vdd PMOD W=20u L=1u
CL25 n25 0 0.01p
Mn26 n26 n25 0 0 NMOD W=10u L=1u
Mp26 n26 n25 vdd vdd PMOD W=20u L=1u
CL26 n26 0 0.01p
Mn27 n27 n26 0 0 NMOD W=10u L=1u
Mp27 n27 n26 vdd vdd PMOD W=20u L=1u
CL27 n27 0 0.01p
Mn28 n28 n27 0 0 NMOD W=10u L=1u
Mp28 n28 n27 vdd vdd PMOD W=20u L=1u
CL28 n28 0 0.01p
Mn29 n29 n28 0 0 NMOD W=10u L=1u
Mp29 n29 n28 vdd vdd PMOD W=20u L=1u
CL29 n29 0 0.01p
Mn30 n30 n29 0 0 NMOD W=10u L=1u
Mp30 n30 n29 vdd vdd PMOD W=20u L=1u
CL30 n30 0 0.01p
Mn31 n31 n30 0 0 NMOD W=10u L=1u
Mp31 n31 n30 vdd vdd PMOD W=20u L=1u
CL31 n31 0 0.01p
Mn32 n32 n31 0 0 NMOD W=10u L=1u
Mp32 n32 n31 vdd vdd PMOD W=20u L=1u
CL32 n32 0 0.01p
Mn33 n33 n32 0 0 NMOD W=10u L=1u
Mp33 n33 n32 vdd vdd PMOD W=20u L=1u
CL33 n33 0 0.01p
Mn34 n34 n33 0 0 NMOD W=10u L=1u
Mp34 n34 n33 vdd vdd PMOD W=20u L=1u
CL34 n34 0 0.01p
Mn35 n35 n34 0 0 NMOD W=10u L=1u
Mp35 n35 n34 vdd vdd PMOD W=20u L=1u
CL35 n35 0 0.01p
Mn36 n36 n35 0 0 NMOD W=10u L=1u
Mp36 n36 n35 vdd vdd PMOD W=20u L=1u
CL36 n36 0 0.01p
Mn37 n37 n36 0 0 NMOD W=10u L=1u
Mp37 n37 n36 vdd vdd PMOD W=20u L=1u
CL37 n37 0 0.01p
Mn38 n38 n37 0 0 NMOD W=10u L=1u
Mp38 n38 n37 vdd vdd PMOD W=20u L=1u
CL38 n38 0 0.01p
Mn39 n39 n38 0 0 NMOD W=10u L=1u
Mp39 n39 n38 vdd vdd PMOD W=20u L=1u
CL39 n39 0 0.01p
Mn40 n40 n39 0 0 NMOD W=10u L=1u
Mp40 n40 n39 vdd vdd PMOD W=20u L=1u
CL40 n40 0 0.01p
Mn41 n41 n40 0 0 NMOD W=10u L=1u
Mp41 n41 n40 vdd vdd PMOD W=20u L=1u
CL41 n41 0 0.01p
Mn42 n42 n41 0 0 NMOD W=10u L=1u
Mp42 n42 n41 vdd vdd PMOD W=20u L=1u
CL42 n42 0 0.01p
Mn43 n43 n42 0 0 NMOD W=10u L=1u
Mp43 n43 n42 vdd vdd PMOD W=20u L=1u
CL43 n43 0 0.01p
Mn44 n44 n43 0 0 NMOD W=10u L=1u
Mp44 n44 n43 vdd vdd PMOD W=20u L=1u
CL44 n44 0 0.01p
Mn45 n45 n44 0 0 NMOD W=10u L=1u
Mp45 n45 n44 vdd vdd PMOD W=20u L=1u
CL45 n45 0 0.01p
Mn46 n46 n45 0 0 NMOD W=10u L=1u
Mp46 n46 n45 vdd vdd PMOD W=20u L=1u
CL46 n46 0 0.01p
Mn47 n47 n46 0 0 NMOD W=10u L=1u
Mp47 n47 n46 vdd vdd PMOD W=20u L=1u
CL47 n47 0 0.01p
Mn48 n48 n47 0 0 NMOD W=10u L=1u
Mp48 n48 n47 vdd vdd PMOD W=20u L=1u
CL48 n48 0 0.01p
Mn49 n49 n48 0 0 NMOD W=10u L=1u
Mp49 n49 n48 vdd vdd PMOD W=20u L=1u
CL49 n49 0 0.01p
Mn50 n50 n49 0 0 NMOD W=10u L=1u
Mp50 n50 n49 vdd vdd PMOD W=20u L=1u
CL50 n50 0 0.01p

.TRAN 0.1n 50n
.END
