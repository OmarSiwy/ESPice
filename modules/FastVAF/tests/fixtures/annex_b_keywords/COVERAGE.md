# Annex B coverage

Source: `docs/annex-b-keywords.html`, including both halves of Table B.1.

The normative rules are directly covered: keywords are lowercase, predefined, nonescaped identifiers (`03_reserved_module_rejected.va`, `04_reserved_if_rejected.va`); an escaped spelling is an identifier (`01_escaped_keyword.va`); and differently-cased spellings are ordinary identifiers (`02_keyword_case.va`).

Keyword inventory by executable family:

| Inventory group | Keywords and fixture disposition |
|---|---|
| Analog declarations | `analog branch discipline enddiscipline nature endnature electrical ground potential flow domain continuous abstol access idt_nature ddt_nature units` — Chapters 1/3 and Annex A fixtures |
| Data/parameters | `integer real realtime string genvar parameter localparam aliasparam from exclude inf paramset endparamset` — Chapter 3 fixtures, with paramset rejection explicit |
| Analog control | `begin end if else for while repeat case default endcase disable initial_step final_step generate endgenerate` — Annex A and Chapters 5/8 fixtures |
| Math | `abs acos acosh asin asinh atan atan2 atanh ceil cos cosh exp expm1 floor hypot ln ln1p log max min pow sin sinh sqrt tan tanh` — Chapter 4 math fixtures; `ln1p`/`expm1` are known dedicated-op gaps |
| Analog operators | `absdelay absdelta ddt ddx idt idtmod laplace_nd laplace_np laplace_zd laplace_zp last_crossing limexp slew transition zi_nd zi_np zi_zd zi_zp` — Chapter 4 operator fixtures; obsolete `absdelta` is inventoried but not valid current syntax |
| Events/noise/analysis | `above analysis cross flicker_noise noise_table noise_table_log timer white_noise ac_stim` — Chapters 4/5/8; `ac_stim` runtime support is a documented gap |
| Module interface/function | `module endmodule input output inout function endfunction return defparam` — Annex A/Chapter 4; `return` parser support is a documented gap and `defparam` has an explicit Annex A rejection fixture |
| Compiler directive token | `include` — Chapter 10 owns executable directive fixtures |
| Verilog/mixed-only | `always and assign automatic break buf bufif0 bufif1 casex casez cell cmos config connect connectmodule connectrules continue deassign design discrete driver_update edge endconfig endconnectrules endprimitive endspecify endtable endtask event force forever fork highz0 highz1 ifnone incdir initial instance join large liblist library macromodule medium merged nand negedge nmos nor noshowcancelled not notif0 notif1 or pmos posedge primitive pull0 pull1 pulldown pullup pulsestyle_ondetect pulsestyle_onevent rcmos reg release resolveto rnmos rpmos rtran rtranif0 rtranif1 scalared showcancelled signed small specify specparam split strong0 strong1 supply0 supply1 table task time tran tranif0 tranif1 tri tri0 tri1 triand trior trireg unsigned use uwire vectored wait wand weak0 weak1 wire wor wreal xnor xor` — direct family sources are `05_config_library_keywords.va` through `11_macromodule_keyword.va` plus Annex C/Chapters 5–8; current rejection classes pin FastVAF's reservedness/grammar boundary |

## Reserved keyword family probes

- `05_config_library_keywords.va`: `cell`, `config`, `design`, `endconfig`, `incdir`, `liblist`, `library`, and `use` in library/configuration grammar.
- `06_udp_keywords.va`: `primitive`, `table`, `endtable`, and `endprimitive` in a UDP declaration.
- `07_gate_primitive_keywords.va`, `07b_switch_primitive_keywords.va`, and `07c_pass_logic_primitive_keywords.va`: `buf`, `bufif0`, `bufif1`, `cmos`, `nand`, `nmos`, `nor`, `notif0`, `notif1`, `pmos`, `pulldown`, `pullup`, `rcmos`, `rnmos`, `rpmos`, `rtran`, `rtranif0`, `rtranif1`, `tranif0`, `tranif1`, `xnor`, and `xor` as primitive tokens.
- `08_net_strength_keywords.va`: `highz0`, `highz1`, `large`, `medium`, `pull0`, `pull1`, `scalared`, `signed`, `small`, `strong0`, `strong1`, `supply0`, `supply1`, `tri`, `tri0`, `tri1`, `triand`, `trior`, `trireg`, `unsigned`, `uwire`, `vectored`, `wand`, `weak0`, `weak1`, and `wor` in net/strength declarations.
- `09_specify_keywords.va`: `edge`, `ifnone`, `noshowcancelled`, `pulsestyle_ondetect`, `pulsestyle_onevent`, `showcancelled`, `specify`, `specparam`, and `endspecify` in a specify block.
- `10_task_control_keywords.va`: `automatic`, `deassign`, `disable`, `endtask`, `fork`, `join`, `negedge`, `realtime`, `release`, `task`, `time`, and `wait` in task/process grammar.
- `11_macromodule_keyword.va`: `macromodule` as a compilation-unit declaration keyword.

Together with the four earlier reservedness fixtures and the chapter corpus, these family probes make every Annex B keyword occur as source syntax rather than only as prose inventory.
