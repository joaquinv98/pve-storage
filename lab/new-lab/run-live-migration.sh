#!/usr/bin/env bash
set -euo pipefail

vmid="${1:?VMID is required}"
target="${2:?target node is required}"
label="${3:?result label is required}"
result_dir="${RESULT_DIR:-/root/zfsnvme-results}"

mkdir -p "$result_dir"
rm -f "/tmp/$label.pass" "/tmp/$label.fail"

start_ns="$(date +%s%N)"
set +e
qm migrate "$vmid" "$target" --online 2>&1 | tee "$result_dir/$label.log"
rc="${PIPESTATUS[0]}"
set -e
end_ns="$(date +%s%N)"
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'migration_rc=%s elapsed_ms=%s\n' "$rc" "$elapsed_ms" |
    tee -a "$result_dir/$label.log"

if ((rc == 0)); then
    touch "/tmp/$label.pass"
else
    touch "/tmp/$label.fail"
fi
exit "$rc"
