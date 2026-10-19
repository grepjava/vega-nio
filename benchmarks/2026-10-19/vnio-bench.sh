#!/usr/bin/env bash
# vnio-bench.sh [rounds]: runs ON the box. Hummingbird 2 and Vapor 4, each on
# SwiftNIO's NIOPosix and on VegaNIO -- one binary per framework, VEGANIO=1
# picking VegaNIO -- under the-benchmarker/web-frameworks' load through
# Garuda's benchmarks/frameworks.sh: the ramp (zrk -R1000:500000, 15 s) and
# closed-loop oha (15 s), at 64, 256 and 512 connections. Server and load
# unpinned on the 8 CPUs, as the suite runs them. Clock capped at 2.4 GHz
# throughout; the four arms rotate so each goes first in turn. Logs in
# ~/v27/vnio-bench/.
R=${1:-4}
OUT=~/v27/vnio-bench; rm -rf $OUT; mkdir -p $OUT
BIN=~/v27/vnio-bin
restore() { for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do sudo cp $c/cpuinfo_max_freq $c/scaling_max_freq; done; echo "clock restored $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"; }
trap restore EXIT
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do echo 2400000 | sudo tee $c >/dev/null; done
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date -Is)"
export LD_LIBRARY_PATH=$BIN/lib OHA=$HOME/.cargo/bin/oha HUMMINGBIRD=$BIN/hummingbird VAPOR=$BIN/vapor
cd ~/g2bench
arms=(hb-nio hb-vega vapor-nio vapor-vega)
for r in $(seq 1 $R); do
  for i in 0 1 2 3; do
    arm=${arms[$(( (i + r - 1) % 4 ))]}
    case $arm in hb-*) srv=hummingbird ;; *) srv=vapor ;; esac
    case $arm in *-vega) export VEGANIO=1 ;; *) unset VEGANIO ;; esac
    for load in ramp closed; do
      echo "== round $r $arm $load"
      LOAD=$load RUNS=1 FRAMEWORKS=swift SERVERS=$srv bash benchmarks/frameworks.sh 2>&1 | tee $OUT/$arm-$load-r$r.tsv
    done
  done
done
unset VEGANIO
echo "done $(date -Is)"
