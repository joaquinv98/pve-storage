#!/usr/bin/env bash
set -euo pipefail

volume="${1:-nvmetcp-lab:vm-902-disk-0}"
target="${TARGET_HOST:-192.168.34.241}"
target_key="${TARGET_KEY:-/etc/pve/priv/zfs/192.168.34.241_id_rsa}"
result_dir="${RESULT_DIR:-/root/zfsnvme-results/ana-transition}"
target_state=/sys/kernel/config/nvmet/ports/1/ana_groups/1/ana_state

mkdir -p "$result_dir"
device="$(pvesm path "$volume")"
namespace="$(basename "$(readlink -f "$device")")"
nsid="${namespace##*n}"

set_ana_state() {
    local state="$1"
    printf '%s\n' "$state" |
        ssh -o BatchMode=yes -i "$target_key" "root@$target" \
            "read state; printf '%s\\n' \"\$state\" > '$target_state'"
    printf '%s event=%s\n' "$(date --iso-8601=ns)" "$state" >>"$result_dir/timeline.log"
}

cleanup() {
    set_ana_state optimized || true
    if [[ -n "${sampler_pid:-}" ]]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

: >"$result_dir/timeline.log"
(
    while true; do
        printf '%s' "$(date --iso-8601=ns)"
        for state_file in \
            /sys/devices/virtual/nvme-fabrics/ctl/nvme*/nvme*c*n"$nsid"/ana_state; do
            [[ -e "$state_file" ]] || continue
            printf ' %s=%s' "$(basename "$(dirname "$state_file")")" "$(<"$state_file")"
        done
        printf '\n'
        sleep 1
    done
) >>"$result_dir/timeline.log" &
sampler_pid=$!

fio \
    --name=ana-transition \
    --filename="$device" \
    --rw=randwrite \
    --bs=4k \
    --ioengine=libaio \
    --iodepth=32 \
    --direct=1 \
    --time_based=1 \
    --runtime=40 \
    --group_reporting=1 \
    --output-format=json \
    --output="$result_dir/fio.json" &
fio_pid=$!

sleep 10
set_ana_state non-optimized
sleep 15
set_ana_state optimized

wait "$fio_pid"
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=

jq '{error: .jobs[0].error, write: .jobs[0].write}' "$result_dir/fio.json" \
    >"$result_dir/summary.json"
cat "$result_dir/summary.json"
