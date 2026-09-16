* Concurrent distinct and duplicate HDL compilations share the loader cache root.
* Expected results: veriloga_parallel.expected.json
.hdl "veriloga_parallel.assets/va_parallel_left.va"
.hdl "veriloga_parallel.assets/va_parallel_right.va"
.hdl "veriloga_parallel.assets/va_parallel_left.va"
Vleft in_left 0 1
Vright in_right 0 3
Rleft in_left left 1000
Rright in_right right 1000
Nleft left 0 va_parallel_left
Nright right 0 va_parallel_right
.op
.end
