"""vnio-summary.py <dir>: medians over rounds of the vnio-bench TSVs
(<arm>-<load>-r<N>.tsv), req/s and p50/p99, VegaNIO against NIOPosix."""
import glob, os, re, statistics, sys
from collections import defaultdict

rps, p50, p99, errs = defaultdict(list), defaultdict(list), defaultdict(list), defaultdict(int)
for f in glob.glob(os.path.join(sys.argv[1], "*-r*.tsv")):
    arm, load = re.match(r"(.+)-(ramp|closed)-r\d+\.tsv", os.path.basename(f)).groups()
    for line in open(f, encoding="utf-8", errors="replace"):
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 5 or not cols[3].isdigit():
            continue
        conns = int(cols[3])
        fields = cols[4].split()
        key = (arm, load, conns)
        rps[key].append(float(fields[0]))
        p50[key].append(float(fields[1]))
        p99[key].append(float(fields[4]))
        errs[key] += int(fields[5])

med = statistics.median
for load in ("ramp", "closed"):
    print(f"\n{load}: median req/s over rounds (n), VegaNIO / NIOPosix, p50 / p99 ms")
    for fw, name in (("hb", "Hummingbird"), ("vapor", "Vapor")):
        for conns in (64, 256, 512):
            a, b = (fw + "-nio", load, conns), (fw + "-vega", load, conns)
            if not rps[a] or not rps[b]:
                continue
            ra, rb = med(rps[a]), med(rps[b])
            print("%-11s %3d  NIO %7.0f  Vega %7.0f  %.2fx  (n=%d/%d, range NIO %.0f-%.0f Vega %.0f-%.0f)  p50 %.2f / %.2f  p99 %.2f / %.2f  errors %d / %d"
                  % (name, conns, ra, rb, rb / ra, len(rps[a]), len(rps[b]), min(rps[a]), max(rps[a]),
                     min(rps[b]), max(rps[b]), med(p50[a]), med(p50[b]), med(p99[a]), med(p99[b]), errs[a], errs[b]))
