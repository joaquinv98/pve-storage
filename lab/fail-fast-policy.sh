#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <volume-id> [output-directory]" >&2
    exit 2
fi

volid=$1
outdir=${2:-"/tmp/zfsnvme-fail-fast.$(date +%s)"}
address_a=${ADDRESS_A:-10.90.1.11}
address_b=${ADDRESS_B:-10.90.2.11}
port=${PORT:-4421}
ramp_time=${RAMP_TIME:-5}
runtime=${RUNTIME:-120}
tag=${TAG:-pve-nvme-fail-fast}
device=$(pvesm path "$volid")

[[ -b "$device" ]] || {
    echo "volume path is not a block device: $device" >&2
    exit 1
}

mkdir -p "$outdir"

rules=(
    "OUTPUT -p tcp -d $address_a --dport $port -m comment --comment $tag -j DROP"
    "INPUT -p tcp -s $address_a --sport $port -m comment --comment $tag -j DROP"
    "OUTPUT -p tcp -d $address_b --dport $port -m comment --comment $tag -j DROP"
    "INPUT -p tcp -s $address_b --sport $port -m comment --comment $tag -j DROP"
)

remove_loss() {
    local rule
    for rule in "${rules[@]}"; do
        # shellcheck disable=SC2086
        while iptables -C $rule 2>/dev/null; do
            # shellcheck disable=SC2086
            iptables -D $rule
        done
    done
}

apply_loss() {
    local rule
    for rule in "${rules[@]}"; do
        # shellcheck disable=SC2086
        iptables -C $rule 2>/dev/null || iptables -I $rule
    done
}

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
    echo "NVMe path $address did not return live" >&2
    return 1
}

cleanup() {
    remove_loss
}
trap cleanup EXIT

mapfile -t controllers < <(
    find /sys/class/nvme -maxdepth 1 -type l -name 'nvme[0-9]*' -print | sort
)
[[ ${#controllers[@]} -gt 0 ]] || {
    echo "no NVMe controllers found" >&2
    exit 1
}

{
    for controller in "${controllers[@]}"; do
        printf '%s\tstate=' "${controller##*/}"
        cat "$controller/state"
        printf '%s\tctrl_loss_tmo=' "${controller##*/}"
        cat "$controller/ctrl_loss_tmo"
        printf '%s\tfast_io_fail_tmo=' "${controller##*/}"
        cat "$controller/fast_io_fail_tmo"
    done
} | tee "$outdir/controller-policy.before"

if grep -q $'fast_io_fail_tmo=off' "$outdir/controller-policy.before"; then
    echo "fast_io_fail_tmo is disabled on at least one controller" >&2
    exit 1
fi

remove_loss

fio \
    --name=all_paths_fail_fast \
    --filename="$device" \
    --ioengine=io_uring \
    --direct=1 \
    --rw=randwrite \
    --bs=16k \
    --iodepth=32 \
    --numjobs=1 \
    --time_based=1 \
    --runtime="$runtime" \
    --exitall_on_error=1 \
    --group_reporting=1 \
    --output-format=json \
    --output="$outdir/fio.json" &
fio_pid=$!

sleep "$ramp_time"
loss_epoch_ns=$(date +%s%N)
printf '%s\n' "$loss_epoch_ns" >"$outdir/loss-epoch-ns"
apply_loss

set +e
wait "$fio_pid"
fio_rc=$?
set -e
exit_epoch_ns=$(date +%s%N)
printf '%s\n' "$exit_epoch_ns" >"$outdir/fio-exit-epoch-ns"

remove_loss
wait_for_path "$address_a"
wait_for_path "$address_b"

python3 - \
    "$outdir/fio.json" \
    "$outdir/summary.json" \
    "$fio_rc" \
    "$loss_epoch_ns" \
    "$exit_epoch_ns" <<'PY'
import json
import pathlib
import sys

fio_path, summary_path, fio_rc, loss_ns, exit_ns = sys.argv[1:]
raw = pathlib.Path(fio_path).read_text()
json_start = raw.find("{")
if json_start < 0:
    raise SystemExit("fio output did not contain a JSON document")
data = json.loads(raw[json_start:])
job = data["jobs"][0]
error = int(job.get("error", 0))
elapsed = (int(exit_ns) - int(loss_ns)) / 1_000_000_000
summary = {
    "test": "all-data-paths fail-fast policy",
    "fio_return_code": int(fio_rc),
    "fio_error": error,
    "cut_to_fio_exit_seconds": round(elapsed, 3),
    "write_bytes": int(job["write"].get("io_bytes", 0)),
    "expected_block_error_observed": int(fio_rc) != 0 and error != 0,
    "paths_recovered_live": True,
}
pathlib.Path(summary_path).write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
if not summary["expected_block_error_observed"]:
    raise SystemExit(1)
PY

trap - EXIT
cleanup
echo "results: $outdir"
