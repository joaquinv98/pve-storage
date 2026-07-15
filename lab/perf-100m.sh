#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <volume-id> [output-directory]" >&2
    exit 2
fi

volid=$1
outdir=${2:-"/tmp/zfsnvme-perf.$(date +%s)"}
iface_a=${IFACE_A:-ens20}
iface_b=${IFACE_B:-ens21}
address_a=${ADDRESS_A:-10.90.1.11}
address_b=${ADDRESS_B:-10.90.2.11}
rate=${RATE:-100mbit}
runtime=${RUNTIME:-20}
ramp_time=${RAMP_TIME:-3}

device=$(pvesm path "$volid")
[[ -b "$device" ]] || {
    echo "volume path is not a block device: $device" >&2
    exit 1
}

mkdir -p "$outdir"

cleanup() {
    ip link set "$iface_a" up 2>/dev/null || true
    ip link set "$iface_b" up 2>/dev/null || true
    tc qdisc del dev "$iface_a" root 2>/dev/null || true
    tc qdisc del dev "$iface_b" root 2>/dev/null || true
}
trap cleanup EXIT

wait_for_path() {
    local address=$1
    local attempt

    for ((attempt = 0; attempt < 60; attempt++)); do
        if nvme list-subsys 2>/dev/null |
            grep -F "traddr=$address" |
            grep -q ' live$'; then
            return 0
        fi
        sleep 1
    done
    echo "NVMe path $address did not become live" >&2
    return 1
}

run_fio() {
    local name=$1

    fio \
        --name="$name" \
        --filename="$device" \
        --ioengine=io_uring \
        --direct=1 \
        --rw=write \
        --bs=128k \
        --iodepth=32 \
        --numjobs=4 \
        --size=1G \
        --offset_increment=1G \
        --time_based=1 \
        --runtime="$runtime" \
        --ramp_time="$ramp_time" \
        --group_reporting=1 \
        --output-format=json \
        --output="$outdir/$name.json"
}

cleanup
wait_for_path "$address_a"
wait_for_path "$address_b"

run_fio multipath_unshaped

tc qdisc replace dev "$iface_a" root tbf rate "$rate" burst 256kb latency 100ms
tc qdisc replace dev "$iface_b" root tbf rate "$rate" burst 256kb latency 100ms

ip link set "$iface_b" down
sleep 8
run_fio single_path_a_100m

ip link set "$iface_b" up
wait_for_path "$address_b"
ip link set "$iface_a" down
sleep 8
run_fio single_path_b_100m

ip link set "$iface_a" up
wait_for_path "$address_a"
run_fio multipath_2x100m

python3 - "$outdir" <<'PY'
import json
import pathlib
import sys

outdir = pathlib.Path(sys.argv[1])
for path in sorted(outdir.glob("*.json")):
    data = json.loads(path.read_text())
    job = data["jobs"][0]
    bw_bytes = job["write"]["bw_bytes"]
    iops = job["write"]["iops"]
    print(f"{path.stem}\t{bw_bytes / 1_000_000:.2f} MB/s\t{iops:.1f} IOPS")
PY

echo "results: $outdir"
