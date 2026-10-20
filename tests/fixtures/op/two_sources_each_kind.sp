* two voltage and two current sources: every source instance after the first stamps its own value
* Expected results: two_sources_each_kind.expected.json
* (a Debug -Dgpu=true build once read the second source's Model row at the GPU kernels' stride, so v(b) = v(d) = 0 under --backend cuda)
va a 0 1
vb b 0 2
ra a 0 1k
rb b 0 1k
ia 0 c 1m
ib 0 d 2m
rc c 0 1k
rd d 0 1k
.op
.end
