* HSPICE .option search [CR .OPTION SEARCH]: .include and .lib files not
* beside the deck are looked up in the search directory (search_dir/).
* Oracle: analytic, 1 V across r1 = 1k over the tt corner's r2 = 3k:
* v(b) = 0.75 V. Neither file resolving fails the deck.
* Expected results: search_lib.expected.json
.option search='search_dir'
.include 'divider.inc'
.lib 'corners.lib' tt
v1 a 0 1
.op
.end
