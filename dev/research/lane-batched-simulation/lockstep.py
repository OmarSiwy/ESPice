import random, subprocess, re, sys, os, json
# Usage: lockstep.py ESPICE (a ReleaseFast espice with LEVEL 72), beside chain24.sp.
# 16 random points, one scalar run each; per-step Newton counts, then the
# eval cost of running them in lockstep groups of W.
E=sys.argv[1]
base=open("chain24.sp").read()
random.seed(7)
pts=[]
for k in range(16):
    nfn=random.choice([2,3,4]); nfp=random.choice([2,3,4])
    rw=200*random.uniform(0.5,2); cw=0.5*random.uniform(0.5,2)
    pts.append((nfn,nfp,rw,cw))
runs=[]
for k,(nfn,nfp,rw,cw) in enumerate(pts):
    d=base.replace(".param nfn=3 nfp=3 rw=200 cw=0.5f",f".param nfn={nfn} nfp={nfp} rw={rw:.3f} cw={cw:.4f}f")
    open(f"p{k}.sp","w").write(d)
    env=dict(os.environ,ZP_NEWTON_DEBUG="1",ZP_TRAN_STATS="1")
    out=subprocess.run(["nice","-n","10",E,"--timing-in-depth","-r","/dev/null",f"p{k}.sp"],capture_output=True,text=True,env=env)
    txt=out.stderr+out.stdout
    # iterations between transient attempt lines
    steps=[];cnt=0;started=False
    for line in txt.splitlines():
        if line.startswith("timing: query 1 tran setup"): started=True; cnt=0; continue
        if not started: continue
        if line.startswith("  it="): cnt+=1
        m=re.match(r"timing: query 1 transient attempt=\d+ accepted=\d+ t=(\S+)s dt=(\S+)s",line)
        if m: steps.append((float(m.group(1)),float(m.group(2)),cnt)); cnt=0
    meas={m.group(1):float(m.group(2)) for m in re.finditer(r"^(tpd|trise|tfall)\s*=\s*(\S+)",txt,re.M)}
    st=re.search(r"tran-stats:.*",txt).group(0)
    runs.append(dict(p=pts[k],steps=steps,meas=meas,stats=st))
    print(k,pts[k],len(steps),sum(s[2] for s in steps),meas,file=sys.stderr)
json.dump(runs,open("runs.json","w"))
g0=[(s[0],s[1]) for s in runs[0]["steps"]]
print("identical (t,dt) grids:",all([(s[0],s[1]) for s in r["steps"]]==g0 for r in runs))
it=[[s[2] for s in r["steps"]] for r in runs]
for W in (2,4,8,16):
    lock=own=0
    for g in range(0,16,W):
        grp=it[g:g+W]
        for k in range(len(g0)):
            lock+=W*max(x[k] for x in grp); own+=sum(x[k] for x in grp)
    print(f"W={W:2d} lockstep evals / own evals = {lock/own:.3f}")
