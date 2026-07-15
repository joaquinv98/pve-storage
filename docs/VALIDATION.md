# Validation record

Lab topology: two nested Proxmox VE 9.2 nodes, one Linux/OpenZFS storage server,
two isolated NVMe/TCP networks, one portal per network, DH-HMAC-CHAP, and Linux
native NVMe multipath. The older iSCSI storage remained online as a regression
control.

## Functional and safety coverage

- Full `pve-storage` build and upstream tests: API verification, 203 plugin
  tests, 91 bandwidth-limit tests, 35 OVF tests, 183 access tests, and 74 Ceph
  parser tests passed.
- Thin allocation, discard reclamation, snapshot, rollback with exact checksum
  restoration, template conversion, linked clone, clone deletion, online
  snapshot, and offline resize passed.
- A zvol owned by the older iSCSI target was rejected and left unchanged.
- Target configfs loss was reconciled from durable ZFS identity properties.
- Controllers connected without the configured data interface were replaced
  one at a time without taking the storage offline.
- Simultaneous allocations issued by both PVE nodes received distinct NSIDs
  and UUIDs. The NSID allocator's `flock` runs on the common target host, not
  on the initiators, so it serializes the cluster-wide ZFS/configfs mutation.
- A live namespace was driven through real target ANA transitions
  `optimized -> non-optimized -> inaccessible -> optimized` on path A while
  path B remained optimized. `fio` wrote 7.23 GB with zero errors or short I/O.
- Live migration succeeded in both directions under guest I/O. The reverse
  migration also succeeded with one destination path degraded.
- A real HA node-loss test used QDevice quorum and watchdog self-fencing. The
  surviving node waited for fencing, activated the namespace by its unchanged
  UUID, and restarted the guest with both paths live and no failed block
  operations. End-to-end recovery took 245 seconds with the lab's default HA
  timers. This is recovery evidence, not an accepted RTO: 245 seconds needs an
  explicit workload/SLA decision.
- A separate live split-brain test isolated Corosync and QDevice from one node
  while leaving both NVMe/TCP paths and both PVE nodes powered. The isolated
  node lost quorum and self-fenced. QEMU was sampled every 200 ms on both
  nodes; the survivor did not start the guest until 79.245 seconds after the
  last source QEMU observation, with the same namespace UUID and no overlap.
- Blocking only the SSH management path left both NVMe/TCP controllers live and
  caused a test allocation to fail without creating a residual zvol. Capacity
  status was intentionally reported inactive until management connectivity
  returned; existing guest I/O remained on the independent data paths.
- A single-path loss kept guest I/O progressing. A 15-second loss of both paths
  produced backpressure without block errors; I/O resumed and checksum
  verification passed after connectivity returned. With the default
  `ctrl_loss_tmo=600` and no fast-fail value, a permanent loss may queue I/O
  for up to ten minutes; this is a policy trade-off, not a universal virtue.
- The new optional `nvme-fast-io-fail-tmo` policy was then set to 5 seconds on
  both controllers. Under a permanent dual-path blackhole, `fio` received the
  expected `EIO` and exited 13.833 seconds after injection (keep-alive/failure
  detection plus fast-fail), rather than waiting for the 600-second controller
  loss timeout. Both paths recovered live and the scratch volume was removed.

## Performance sample

Each data interface was shaped to 100 Mbit/s for an apples-to-apples write
test:

| Paths | Throughput | IOPS |
| --- | ---: | ---: |
| Path A | 11.94 MB/s | 85.3 |
| Path B | 11.94 MB/s | 85.3 |
| A + B | 23.89 MB/s | 176.3 |
| A + B, unshaped | 131.96 MB/s | 1000.7 |

The shaped two-path result was 2.00 times one path. These values validate path
use and scaling in this lab; they are not hardware sizing numbers.

## Qualification still required per production platform

Nested-virtualization results do not replace hardware qualification. Before a
production rollout, repeat at least a 72-hour mixed-I/O soak on the intended
NICs, switches, firmware, kernel, ZFS version, and workload; test controller,
switch, cable, target reboot, initiator reboot, quorum loss, fencing, pool-full
behavior, backup restore, and rolling upgrades. Record latency percentiles and
recovery-time objectives, not only average bandwidth.
