* HSPICE .DC over a .param [CR .DC] (#94): W of a level-1 NMOS swept as a
* parameter, no source on the card. Saturation, LAMBDA = 0:
*   Id = KP/2 * W/L * (Vgs - VTO)^2 = 1e-4/2 * W/1u * 0.8^2 = 32 A/m * W
*   W = 1u 2u 3u 4u  ->  i(vd) = -32u -64u -96u -128u
.param wn=1u
VD d 0 2
VG g 0 1.5
M1 d g 0 0 nm W=wn L=1u
.model nm NMOS LEVEL=1 VTO=0.7 KP=1e-4
.dc wn 1u 4u 1u
.end
