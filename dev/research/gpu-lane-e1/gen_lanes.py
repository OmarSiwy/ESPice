# E1 deck: N copies (sweep points) of the 24-stage asap7 chain of
# lane-batched-simulation/gen_chain.py in ONE circuit, so one bsimcmg batch
# holds 48 x N instances. Each point has its own vdd and vin, so the
# circuit is N disjoint blocks, as N lanes are, and the GPU eval kernel runs one thread per instance.
# Usage: gen_lanes.py PM N ORDER SIZING TSTOP > deck.sp
#   ORDER  lane:    instance-major, point-innermost (a warp = 32 points of one
#                   transistor, the lane backend's thread order, design §4)
#          point:   point-major (a warp = 16 inverters of one chain, today's order)
#          shuffle: random instance order (every warp mixes n/p, stages, points)
#   SIZING coherent: every point nfn=nfp=3 rw=200 cw=0.5f (identical biases)
#          mixed:    lockstep.py's distribution (nfin 2-4, rw/cw 0.5-2x)
#          distinct: mixed, plus l = 20n..21n per point, so every point binds
#                    its own Model rows (22.6 KB each) and no two lanes share one
import random, sys
P, N, ORDER, SIZING, TSTOP = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
S = 24
rng = random.Random(7)
pts = [(3, 3, 200.0, 0.5) if SIZING == "coherent" else
       (rng.choice([2, 3, 4]), rng.choice([2, 3, 4]), 200 * rng.uniform(0.5, 2), 0.5 * rng.uniform(0.5, 2))
       for _ in range(N)]
node = lambda i, p: f"in_{p}" if i < 0 else f"w{i}_{p}"
mos, rc = [], []
for i in range(S):
    for k in (0, 1):
        for p, (nfn, nfp, rw, cw) in enumerate(pts):
            o, a = f"o{i}_{p}", node(i - 1, p)
            l = f"{20 + p / N:.6f}n" if SIZING == "distinct" else "20n"
            mos.append((i, p, k, f"mp{i}_{p} {o} {a} vdd_{p} vdd_{p} pmos_rvt l={l} nfin={nfp}" if k == 0 else
                        f"mn{i}_{p} {o} {a} 0 0 nmos_rvt l={l} nfin={nfn}"))
            if k: rc += [f"r{i}_{p} {o} {node(i, p)} {rw:.3f}", f"c{i}_{p} {node(i, p)} 0 {cw:.4f}f"]
if ORDER == "point":
    mos.sort(key=lambda m: (m[1], m[0], m[2]))
elif ORDER == "shuffle":
    rng.shuffle(mos)
print("\n".join([f"* E1: {N} points x 24-stage asap7 chain, order={ORDER} sizing={SIZING}",
                 f".include '{P}'"]
                + [f"vdd{p} vdd_{p} 0 0.7\nvin{p} in_{p} 0 pulse(0 0.7 50p 10p 10p 400p 1n)" for p in range(N)]
                + [m[3] for m in mos] + rc + [f".tran 1p {TSTOP}", ".end"]))
