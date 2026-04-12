* M06: Hierarchical BJT 4-Bit Ripple-Carry Adder
* Uses DTL (Diode-Transistor Logic) style gates built from NPN BJTs
* Hierarchy: NAND2 -> HALFADDER -> FULLADDER -> 4-bit chain
* Total: ~48 BJTs + resistor loads

VCC vcc 0 DC 5

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10)
.MODEL DMOD D (IS=1e-14 N=1 RS=10)

*** NAND2 gate: out = ~(a & b) using DTL-style logic ***
.SUBCKT NAND2 a b out vcc
R1 vcc n1 4.7k
D1 a n1 DMOD
D2 b n1 DMOD
Q1 out n1 0 0 NPN1
R2 vcc out 1k
.ENDS NAND2

*** NOT gate: out = ~a ***
.SUBCKT NOT a out vcc
R1 vcc n1 4.7k
Q1 out n1 0 0 NPN1
R2 vcc out 1k
D1 a n1 DMOD
.ENDS NOT

*** XOR2 gate: out = a ^ b = (a NAND (a NAND b)) NAND (b NAND (a NAND b)) ***
.SUBCKT XOR2 a b out vcc
X1 a b nab vcc NAND2
X2 a nab n1 vcc NAND2
X3 b nab n2 vcc NAND2
X4 n1 n2 out vcc NAND2
.ENDS XOR2

*** AND2 gate: out = a & b = ~(a NAND b) ***
.SUBCKT AND2 a b out vcc
X1 a b nab vcc NAND2
X2 nab nab out vcc NAND2
.ENDS AND2

*** OR2 gate: out = a | b = ~(~a & ~b) = (a NAND a) NAND (b NAND b) ***
.SUBCKT OR2 a b out vcc
X1 a a na vcc NAND2
X2 b b nb vcc NAND2
X3 na nb out vcc NAND2
.ENDS OR2

*** HALFADDER: sum = a ^ b, cout = a & b ***
.SUBCKT HALFADDER a b sum cout vcc
X1 a b sum vcc XOR2
X2 a b cout vcc AND2
.ENDS HALFADDER

*** FULLADDER: sum = a ^ b ^ cin, cout = (a & b) | (cin & (a ^ b)) ***
.SUBCKT FULLADDER a b cin sum cout vcc
X1 a b s1 c1 vcc HALFADDER
X2 s1 cin sum c2 vcc HALFADDER
X3 c1 c2 cout vcc OR2
.ENDS FULLADDER

*** 4-bit inputs: A=0101 (5), B=0011 (3), expected sum=1000 (8), cout=0 ***

* Input A bits (active high: 5 = 0b0101 -> A0=1, A1=0, A2=1, A3=0)
VA0 a0 0 PULSE(0 5 1n 0.1n 0.1n 50n 100n)
VA1 a1 0 DC 0
VA2 a2 0 PULSE(0 5 1n 0.1n 0.1n 50n 100n)
VA3 a3 0 DC 0

* Input B bits (active high: 3 = 0b0011 -> B0=1, B1=1, B2=0, B3=0)
VB0 b0 0 PULSE(0 5 1n 0.1n 0.1n 50n 100n)
VB1 b1 0 PULSE(0 5 1n 0.1n 0.1n 50n 100n)
VB2 b2 0 DC 0
VB3 b3 0 DC 0

* Carry-in tied to ground
VCIN cin 0 DC 0

* 4-bit ripple-carry adder chain
XFA0 a0 b0 cin  s0 c0 vcc FULLADDER
XFA1 a1 b1 c0   s1 c1 vcc FULLADDER
XFA2 a2 b2 c1   s2 c2 vcc FULLADDER
XFA3 a3 b3 c2   s3 cout vcc FULLADDER

* Small load capacitors on outputs for realistic settling
CLS0 s0 0 0.01p
CLS1 s1 0 0.01p
CLS2 s2 0 0.01p
CLS3 s3 0 0.01p
CLCO cout 0 0.01p

.TRAN 1n 200n
.END
